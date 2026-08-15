#!/usr/bin/env bash
# Run the XKubernetesCluster validation-path chainsaw suite (M4 step 6, Tier
# A) against controlplane, where XKubernetesCluster claims live.
#
# Usage: run-xkubernetescluster-validation-test.sh
#
# NOTE: this suite creates a real, short-lived AWS Route53 zone + Cloudflare
# NS records (create-dns-delegation is unconditional -- see
# tests/xkubernetescluster-validation/chainsaw-test.yaml). Cheap and
# near-instant, unlike tests/xkubernetescluster-lifecycle's real VM/Talos
# provision -- see that suite's README before running it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="${REPO}/clusters/controlplane/catalog.yaml"
CHAINSAW="${REPO}/.venv/bin/chainsaw"

info()  { echo "[INFO]  $*"; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

[ -f "${CATALOG}" ] || fatal "no catalog at ${CATALOG}"

KUBECONFIG_RAW="$(grep 'rye.ninja/kubeconfig:' "${CATALOG}" | awk '{print $2}')"
[ -n "${KUBECONFIG_RAW}" ] || fatal "no rye.ninja/kubeconfig annotation in ${CATALOG}"
KUBECONFIG="${KUBECONFIG_RAW/#\~/${HOME}}"
[ -f "${KUBECONFIG}" ] || fatal "kubeconfig not found: ${KUBECONFIG}"
export KUBECONFIG

if [ ! -x "${CHAINSAW}" ]; then
    info "chainsaw not found; installing"
    "${REPO}/.bin/install-chainsaw.sh"
fi

info "kubeconfig: ${KUBECONFIG}"
kubectl version --request-timeout=10s >/dev/null || fatal "cluster unreachable"

info "running xkubernetescluster-validation suite"
"${CHAINSAW}" test "${REPO}/tests/xkubernetescluster-validation" \
    --config "${REPO}/tests/xkubernetescluster-validation/.chainsaw.yaml"

info "xkubernetescluster-validation PASSED"
