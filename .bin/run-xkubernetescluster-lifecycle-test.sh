#!/usr/bin/env bash
# Run the XKubernetesCluster real end-to-end lifecycle chainsaw suite (M4
# step 6, Tier B) against controlplane. MANUAL ONLY -- see
# tests/xkubernetescluster-lifecycle/README.md before running: this
# provisions a real VM (Terraform + Talos bootstrap) and a real AWS Route53
# zone + Cloudflare NS records, takes ~10-20 minutes, and needs a one-time
# platform-kvm-network fixture entry added first.
#
# Usage: run-xkubernetescluster-lifecycle-test.sh
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

if ! grep -q "xkc-lifecycle-test:" "${REPO}/clusters/controlplane/crossplane-resources/crossplane.environment-config.kvm-network.yaml"; then
    fatal "no xkc-lifecycle-test entry in platform-kvm-network -- add the fixture from tests/xkubernetescluster-lifecycle/README.md first"
fi

if [ ! -x "${CHAINSAW}" ]; then
    info "chainsaw not found; installing"
    "${REPO}/.bin/install-chainsaw.sh"
fi

info "kubeconfig: ${KUBECONFIG}"
kubectl version --request-timeout=10s >/dev/null || fatal "cluster unreachable"

info "running xkubernetescluster-lifecycle suite (real VM/DNS provisioning, ~10-20 min)"
"${CHAINSAW}" test "${REPO}/tests/xkubernetescluster-lifecycle" \
    --config "${REPO}/tests/xkubernetescluster-lifecycle/.chainsaw.yaml"

info "xkubernetescluster-lifecycle PASSED"
