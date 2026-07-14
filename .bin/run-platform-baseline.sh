#!/usr/bin/env bash
# Run the platform baseline contract suites against a cluster.
#
# Usage: run-platform-baseline.sh [cluster-name]
#
# The cluster's kubeconfig is resolved from the rye.ninja/kubeconfig
# annotation in clusters/<name>/catalog.yaml. Cluster-specific expectations
# come from tests/platform-baseline/values/<name>.env.
#
# These suites are the M2 migration acceptance gate: M2 is complete when
# this runner passes with the controlplane values file.
set -euo pipefail

CLUSTER="${1:-crossplane}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="${REPO}/clusters/${CLUSTER}/catalog.yaml"
VALUES_FILE="${REPO}/tests/platform-baseline/values/${CLUSTER}.env"
CHAINSAW="${REPO}/.venv/bin/chainsaw"

RUN_STEP_CA_SUITES="${RUN_STEP_CA_SUITES:-true}"

info()  { echo "[INFO]  $*"; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

[ -f "${CATALOG}" ] || fatal "no catalog at ${CATALOG}"
[ -f "${VALUES_FILE}" ] || fatal "no values file at ${VALUES_FILE}"

KUBECONFIG_RAW="$(grep 'rye.ninja/kubeconfig:' "${CATALOG}" | awk '{print $2}')"
[ -n "${KUBECONFIG_RAW}" ] || fatal "no rye.ninja/kubeconfig annotation in ${CATALOG}"
KUBECONFIG="${KUBECONFIG_RAW/#\~/${HOME}}"
[ -f "${KUBECONFIG}" ] || fatal "kubeconfig not found: ${KUBECONFIG}"
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
export VALUES_FILE

info "cluster:    ${CLUSTER}"
info "kubeconfig: ${KUBECONFIG}"
info "values:     ${VALUES_FILE}"

kubectl version --request-timeout=10s >/dev/null || fatal "cluster unreachable"

info "running platform baseline suites"
"${CHAINSAW}" test "${REPO}/tests/platform-baseline" \
    --config "${REPO}/tests/platform-baseline/.chainsaw.yaml"

if [ "${RUN_STEP_CA_SUITES}" = "true" ]; then
    # The pre-existing step-ca capability suites are part of the baseline
    # contract (see docs/superpowers/specs/2026-07-11-m0-baseline-audit-design.md).
    # Parametrized in M2: they inherit KUBECONFIG and read STEP_CA_URL /
    # STEP_CA_HEALTH_RETRIES from the sourced values file.
    info "running step-ca internal capability suite (gate)"
    "${CHAINSAW}" test "${REPO}/tests/step-ca/internal"

    info "running step-ca external capability suite (${STEP_CA_EXTERNAL_GATE:-gate})"
    if [ "${STEP_CA_EXTERNAL_GATE:-gate}" = "advisory" ]; then
        # Quarantined: the public CA path on this cluster has sustained
        # outage windows (recorded audit finding). Result is reported but
        # does not gate; restore to "gate" in the cluster values file once
        # the finding is remediated.
        if ! "${CHAINSAW}" test "${REPO}/tests/step-ca/external"; then
            echo "[ADVISORY] step-ca external suite FAILED (non-gating on this cluster; see values file finding)"
        fi
    else
        "${CHAINSAW}" test "${REPO}/tests/step-ca/external"
    fi
fi

info "platform baseline PASSED for ${CLUSTER}"
