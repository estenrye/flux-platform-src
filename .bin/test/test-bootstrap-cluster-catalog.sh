#!/bin/bash

SCRIPTS_DIR=$(cd "$(dirname "$0")/../.." && pwd)
TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "${actual}" = "${expected}" ]; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name} — expected '${expected}', got '${actual}'"
    FAIL=$((FAIL + 1))
  fi
}

CLUSTER="oci.us-phoenix-1.test-project.oke-test"
KUBECONFIG_PATH="~/.kube/oci/test_project/oke-test.yaml"
CATALOG="${TEMP_DIR}/clusters/${CLUSTER}/catalog.yaml"

# ── Test 1: catalog.yaml is created with correct content ──────────────────────
BASE_DIR="${TEMP_DIR}" CLUSTER="${CLUSTER}" KUBECONFIG="${KUBECONFIG_PATH}" \
  "${SCRIPTS_DIR}/.bin/bootstrap-cluster-catalog.sh"

[ -f "${CATALOG}" ] || { echo "FAIL: catalog.yaml was not created"; FAIL=$((FAIL + 1)); }

check "metadata.name" \
  "${CLUSTER}" \
  "$(yq e '.metadata.name' "${CATALOG}")"

check "github.com/project-slug" \
  "estenrye/flux-platform-rendered-${CLUSTER}" \
  "$(yq e '.metadata.annotations["github.com/project-slug"]' "${CATALOG}")"

check "rye.ninja/flux-source-repo" \
  "estenrye/flux-platform-src" \
  "$(yq e '.metadata.annotations["rye.ninja/flux-source-repo"]' "${CATALOG}")"

check "rye.ninja/kubeconfig" \
  "${KUBECONFIG_PATH}" \
  "$(yq e '.metadata.annotations["rye.ninja/kubeconfig"]' "${CATALOG}")"

check "spec.owner" \
  "group:platform-engineering" \
  "$(yq e '.spec.owner' "${CATALOG}")"

check "spec.domain" \
  "platform" \
  "$(yq e '.spec.domain' "${CATALOG}")"

# ── Test 2: re-running skips without overwriting ──────────────────────────────
ORIGINAL=$(cat "${CATALOG}")
BASE_DIR="${TEMP_DIR}" CLUSTER="${CLUSTER}" KUBECONFIG="completely-different-path" \
  "${SCRIPTS_DIR}/.bin/bootstrap-cluster-catalog.sh"
AFTER=$(cat "${CATALOG}")
check "idempotent — skip on re-run" "${ORIGINAL}" "${AFTER}"

# ── Test 3: cluster directory is created if missing ───────────────────────────
NEW_CLUSTER="oci.us-phoenix-1.other-project.oke-other"
BASE_DIR="${TEMP_DIR}" CLUSTER="${NEW_CLUSTER}" KUBECONFIG="~/.kube/oci/other.yaml" \
  "${SCRIPTS_DIR}/.bin/bootstrap-cluster-catalog.sh"
if [ -d "${TEMP_DIR}/clusters/${NEW_CLUSTER}" ]; then
  echo "PASS: cluster directory created"
else
  echo "FAIL: cluster directory was not created"
  FAIL=$((FAIL + 1))
fi

echo ""
[ "${FAIL}" -eq 0 ] && echo "All tests passed." || { echo "${FAIL} test(s) failed."; exit 1; }
