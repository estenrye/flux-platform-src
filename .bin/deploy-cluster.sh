#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMEOUT=${TIMEOUT:-600}
RETRY_INTERVAL=${RETRY_INTERVAL:-15}

# Allow tests to inject CLUSTER_PATH, CLUSTER_NAME, KUBECONFIG directly,
# bypassing the lib helpers (same pattern as rotate-cluster-sops-key.sh).
if [ -z "${CLUSTER_PATH:-}" ] || [ -z "${CLUSTER_NAME:-}" ] || [ -z "${KUBECONFIG:-}" ]; then
  source "${SCRIPT_DIR}/lib/prompt-color.sh"
  source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
  source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"
else
  source "${SCRIPT_DIR}/lib/prompt-color.sh"
fi

DEADLINE=$(( $(date +%s) + TIMEOUT ))
ATTEMPT=0

info "Deploying cluster ${CLUSTER_NAME} (timeout: ${TIMEOUT}s, retry interval: ${RETRY_INTERVAL}s) ..."

while true; do
  ATTEMPT=$(( ATTEMPT + 1 ))
  info "Attempt ${ATTEMPT} ..."

  OUTPUT=$( { kustomize build --enable-helm "${CLUSTER_PATH}" \
    | kubectl apply --server-side -f - --kubeconfig="${KUBECONFIG}"; } 2>&1) || true
  echo "${OUTPUT}"

  REMAINING=$(echo "${OUTPUT}" \
    | grep -E "^(Error from server|error:)|ensure CRDs are installed first" \
    | grep -v "\.sops: field not declared in schema" \
    || true)

  if [ -z "${REMAINING}" ]; then
    success "Cluster ${CLUSTER_NAME} deployed successfully."
    echo ""
    info "Next step: once ESO is running and has created flux-ssh-key-secret, run:"
    info "     make bootstrap-cluster-deploy-key CLUSTER=${CLUSTER_NAME}"
    exit 0
  fi

  if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
    error "Timed out after ${TIMEOUT}s. Unresolved errors:"
    echo "${REMAINING}" >&2
    exit 1
  fi

  warn "Unresolved errors — will retry in ${RETRY_INTERVAL}s:"
  echo "${REMAINING}"
  sleep "${RETRY_INTERVAL}"
done
