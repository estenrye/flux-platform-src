#!/usr/bin/env bash
# Run the controlplane baseline contract suites (M1 design §9).
#
# Usage: run-controlplane-baseline.sh [suite ...]
#   suite: network storage lb flux (default: all)
#
# Kubeconfig comes from the rye.ninja/kubeconfig annotation in
# clusters/controlplane/catalog.yaml; suite expectations from
# tests/controlplane-baseline/values/controlplane.env.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="${REPO}/clusters/controlplane/catalog.yaml"
VALUES_FILE="${REPO}/tests/controlplane-baseline/values/controlplane.env"
CHAINSAW="${REPO}/.venv/bin/chainsaw"

info()  { echo "[INFO]  $*"; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

[ -f "${CATALOG}" ] || fatal "no catalog at ${CATALOG}"
[ -f "${VALUES_FILE}" ] || fatal "no values file at ${VALUES_FILE}"

KUBECONFIG_RAW="$(grep 'rye.ninja/kubeconfig:' "${CATALOG}" | awk '{print $2}')"
[ -n "${KUBECONFIG_RAW}" ] || fatal "no rye.ninja/kubeconfig annotation in ${CATALOG}"
KUBECONFIG="${KUBECONFIG_RAW/#\~/${HOME}}"
[ -f "${KUBECONFIG}" ] || fatal "kubeconfig not found: ${KUBECONFIG} — run create-controlplane-cluster.sh first"
export KUBECONFIG

if [ ! -x "${CHAINSAW}" ]; then
    info "chainsaw not found; installing"
    "${REPO}/.bin/install-chainsaw.sh"
fi

# Export every value for suite scripts.
set -a
# shellcheck disable=SC1090
source "${VALUES_FILE}"
set +a

SUITES=("$@")
[ ${#SUITES[@]} -gt 0 ] || SUITES=(network storage lb flux)

cd "${REPO}/tests/controlplane-baseline"
for suite in "${SUITES[@]}"; do
    [ -d "${suite}" ] || fatal "unknown suite: ${suite}"
    info "Running suite: ${suite}"
    "${CHAINSAW}" test --config .chainsaw.yaml "${suite}"
done
info "All suites passed."
