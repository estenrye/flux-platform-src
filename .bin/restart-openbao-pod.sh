#!/usr/bin/env bash
# Restart one OpenBao pod and unseal it. OpenBao's StatefulSet uses
# updateStrategyType: OnDelete (applications/openbao/base/kustomization.yaml)
# -- a pod only ever picks up a spec change (new volumes, new listener
# config, an image bump) when it's deleted and recreated, and it ALWAYS
# comes back sealed regardless of storage backend (seal state is
# per-pod-process, not shared via the postgresql storage backend -- see
# docs/runbooks/openbao-unseal.md). This script does both steps: delete +
# wait for the replacement to come up Running, then unseal it with the
# threshold-many key shares from the SOPS-encrypted unseal secret.
#
# Usage:
#   .bin/restart-openbao-pod.sh <pod-name>
#   .bin/restart-openbao-pod.sh openbao-0
#
# Env (smart defaults, override any of them):
#   KUBECONFIG_PATH     default: ${HOME}/.kube/homelab/controlplane.yaml
#   NAMESPACE           default: openbao
#   CONTAINER           default: openbao
#   SOPS_AGE_KEY_FILE   default: clusters/controlplane/.sops.age-key
#   UNSEAL_SECRET_PATH  default: clusters/controlplane/secrets/openbao-unseal.sops.yaml
#   UNSEAL_THRESHOLD    default: 3 (must match the value used at
#                        `bao operator init -key-threshold=N` time --
#                        see docs/runbooks/openbao-unseal.md step 1)
#
# Only ever restarts the ONE pod named -- run this once per replica,
# waiting for each to finish unsealing before moving to the next (same
# one-at-a-time discipline the runbook and every other OpenBao change in
# this repo already follows, to avoid simultaneous churn on the shared HA
# lock table).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/prompt-color.sh"

fatal() { error "$*"; exit 1; }

POD_NAME="${1:-}"
[ -n "${POD_NAME}" ] || fatal "usage: $0 <pod-name>  (e.g. openbao-0)"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/homelab/controlplane.yaml}"
export KUBECONFIG="${KUBECONFIG_PATH}"
NAMESPACE="${NAMESPACE:-openbao}"
CONTAINER="${CONTAINER:-openbao}"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${REPO}/clusters/controlplane/.sops.age-key}"
export SOPS_AGE_KEY_FILE
UNSEAL_SECRET_PATH="${UNSEAL_SECRET_PATH:-${REPO}/clusters/controlplane/secrets/openbao-unseal.sops.yaml}"
UNSEAL_THRESHOLD="${UNSEAL_THRESHOLD:-3}"

for cmd in kubectl sops yq; do
  command -v "${cmd}" >/dev/null || fatal "required command not found: ${cmd}"
done
[ -f "${SOPS_AGE_KEY_FILE}" ] || fatal "SOPS age key not found at ${SOPS_AGE_KEY_FILE}"
[ -f "${UNSEAL_SECRET_PATH}" ] || fatal "unseal secret not found at ${UNSEAL_SECRET_PATH}"

bao_status() {
  kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -c "${CONTAINER}" -- \
    bao status -tls-skip-verify -format=json 2>/dev/null || true
}

info "Deleting pod ${POD_NAME} (namespace ${NAMESPACE})..."
kubectl delete pod -n "${NAMESPACE}" "${POD_NAME}"

info "Waiting for ${POD_NAME} to come back Running (not necessarily Ready --"
info "readiness fails while sealed, that's expected)..."
for _ in $(seq 1 60); do
  PHASE="$(kubectl get pod -n "${NAMESPACE}" "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "${PHASE}" = "Running" ] && break
  sleep 5
done
[ "${PHASE}" = "Running" ] || fatal "${POD_NAME} did not reach Running within 5m (last phase: '${PHASE}')"
success "${POD_NAME} is Running."

# Give the bao process a moment to actually start serving before the
# first status check.
sleep 5

SEALED="$(bao_status | (yq -r '.sealed' 2>/dev/null || echo unknown))"
if [ "${SEALED}" = "false" ]; then
  success "${POD_NAME} came back already unsealed -- nothing to do."
  exit 0
fi
[ "${SEALED}" = "true" ] || fatal "could not read seal status from ${POD_NAME} (got: '${SEALED}') -- check it manually before proceeding"

info "${POD_NAME} is sealed, as expected after a restart. Unsealing with"
info "${UNSEAL_THRESHOLD} key share(s) from ${UNSEAL_SECRET_PATH}..."

TMP="$(mktemp)"
chmod 600 "${TMP}"
cleanup() {
  dd if=/dev/urandom of="${TMP}" bs=1k count=4 conv=notrunc 2>/dev/null || true
  rm -f "${TMP}"
}
trap cleanup EXIT

sops -d "${UNSEAL_SECRET_PATH}" > "${TMP}" \
  || fatal "failed to decrypt ${UNSEAL_SECRET_PATH} -- check SOPS_AGE_KEY_FILE (${SOPS_AGE_KEY_FILE})"

# UNVERIFIED: this session never decrypted the real file (no standing
# access to unseal-key material, correctly), so `.unseal_keys_b64` is
# inferred from `bao operator init -format=json`'s own documented field
# name (docs/runbooks/openbao-unseal.md step 2 reads that same field from
# the init output) rather than confirmed against this file's actual
# structure. If this fails with a null/empty read, `yq -r 'keys' "${TMP}"`
# once (then shred it) to check the real top-level field names.
SHARE_COUNT="$(yq -r '.unseal_keys_b64 | length' "${TMP}")"
[ "${SHARE_COUNT}" -ge "${UNSEAL_THRESHOLD}" ] \
  || fatal "unseal secret only has ${SHARE_COUNT} share(s), need ${UNSEAL_THRESHOLD}"

i=0
while [ "${i}" -lt "${UNSEAL_THRESHOLD}" ]; do
  SHARE="$(yq -r ".unseal_keys_b64[${i}]" "${TMP}")"
  kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -c "${CONTAINER}" -- \
    bao operator unseal -tls-skip-verify "${SHARE}" >/dev/null
  i=$((i + 1))
  info "applied share ${i}/${UNSEAL_THRESHOLD}"
done

SEALED="$(bao_status | (yq -r '.sealed' 2>/dev/null || echo unknown))"
if [ "${SEALED}" = "false" ]; then
  success "${POD_NAME} unsealed."
else
  fatal "${POD_NAME} still reports sealed after applying ${UNSEAL_THRESHOLD} shares -- check UNSEAL_THRESHOLD matches the real key-threshold, or inspect manually."
fi
