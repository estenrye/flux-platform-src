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

# Shared test fixtures
CLUSTER_PATH="${TEMP_DIR}/cluster"
mkdir -p "${CLUSTER_PATH}"
CLUSTER_NAME="test-cluster"
FAKE_KB="${TEMP_DIR}/kubeconfig.yaml"
touch "${FAKE_KB}"

STUB_BIN="${TEMP_DIR}/bin"
mkdir -p "${STUB_BIN}"

# kustomize stub: always emits a minimal YAML document (content irrelevant — kubectl is stubbed)
cat > "${STUB_BIN}/kustomize" <<'STUB'
#!/bin/bash
printf '# stub manifest\n'
STUB
chmod +x "${STUB_BIN}/kustomize"

export PATH="${STUB_BIN}:${PATH}"

# ── Test 1: exits 0 when kubectl produces no errors ───────────────────────────
cat > "${STUB_BIN}/kubectl" <<'STUB'
#!/bin/bash
echo "namespace/flux-system serverside-applied"
echo "helmrelease.helm.toolkit.fluxcd.io/test serverside-applied"
STUB
chmod +x "${STUB_BIN}/kubectl"

result=0
CLUSTER_PATH="${CLUSTER_PATH}" CLUSTER_NAME="${CLUSTER_NAME}" KUBECONFIG="${FAKE_KB}" \
  TIMEOUT=5 RETRY_INTERVAL=1 \
  "${SCRIPTS_DIR}/.bin/deploy-cluster.sh" >/dev/null 2>&1 || result=$?
check "exits 0 when no errors" "0" "${result}"

# ── Test 2: exits 0 when the only error is the SOPS schema error ──────────────
cat > "${STUB_BIN}/kubectl" <<'STUB'
#!/bin/bash
echo "namespace/flux-system serverside-applied"
echo "Error from server: failed to create typed patch object (external-secrets-operator/onepassword-sdk-token; /v1, Kind=Secret): .sops: field not declared in schema"
STUB
chmod +x "${STUB_BIN}/kubectl"

result=0
CLUSTER_PATH="${CLUSTER_PATH}" CLUSTER_NAME="${CLUSTER_NAME}" KUBECONFIG="${FAKE_KB}" \
  TIMEOUT=5 RETRY_INTERVAL=1 \
  "${SCRIPTS_DIR}/.bin/deploy-cluster.sh" >/dev/null 2>&1 || result=$?
check "exits 0 when only SOPS schema error remains" "0" "${result}"

# ── Test 3: retries on non-SOPS errors and exits 0 once they clear ────────────
COUNTER="${TEMP_DIR}/kubectl-calls"
echo "0" > "${COUNTER}"

cat > "${STUB_BIN}/kubectl" <<STUB
#!/bin/bash
COUNT=\$(cat "${COUNTER}")
COUNT=\$((COUNT + 1))
echo "\${COUNT}" > "${COUNTER}"
if [ "\${COUNT}" -eq 1 ]; then
  echo "error: no matches for kind \"HelmRelease\" in version \"helm.toolkit.fluxcd.io/v2\""
else
  echo "namespace/flux-system serverside-applied"
  echo "Error from server: failed to create typed patch object (external-secrets-operator/onepassword-sdk-token; /v1, Kind=Secret): .sops: field not declared in schema"
fi
STUB
chmod +x "${STUB_BIN}/kubectl"

result=0
CLUSTER_PATH="${CLUSTER_PATH}" CLUSTER_NAME="${CLUSTER_NAME}" KUBECONFIG="${FAKE_KB}" \
  TIMEOUT=30 RETRY_INTERVAL=1 \
  "${SCRIPTS_DIR}/.bin/deploy-cluster.sh" >/dev/null 2>&1 || result=$?
check "exits 0 after non-SOPS error clears on retry" "0" "${result}"
check "made exactly 2 kubectl calls on convergence" "2" "$(cat "${COUNTER}")"

# ── Test 4: exits 1 when timeout expires with unresolved errors ───────────────
cat > "${STUB_BIN}/kubectl" <<'STUB'
#!/bin/bash
echo "error: no matches for kind \"HelmRelease\" in version \"helm.toolkit.fluxcd.io/v2\""
STUB
chmod +x "${STUB_BIN}/kubectl"

result=0
CLUSTER_PATH="${CLUSTER_PATH}" CLUSTER_NAME="${CLUSTER_NAME}" KUBECONFIG="${FAKE_KB}" \
  TIMEOUT=2 RETRY_INTERVAL=1 \
  "${SCRIPTS_DIR}/.bin/deploy-cluster.sh" >/dev/null 2>&1 || result=$?
check "exits 1 on timeout with unresolved errors" "1" "${result}"

# ── Test 5: retries on Error from server (InternalError) ─────────────────────
COUNTER2="${TEMP_DIR}/kubectl-calls-2"
echo "0" > "${COUNTER2}"

cat > "${STUB_BIN}/kubectl" <<STUB
#!/bin/bash
COUNT=\$(cat "${COUNTER2}")
COUNT=\$((COUNT + 1))
echo "\${COUNT}" > "${COUNTER2}"
if [ "\${COUNT}" -eq 1 ]; then
  echo "Error from server (InternalError): Internal error occurred: failed calling webhook"
else
  echo "namespace/flux-system serverside-applied"
fi
STUB
chmod +x "${STUB_BIN}/kubectl"

result=0
CLUSTER_PATH="${CLUSTER_PATH}" CLUSTER_NAME="${CLUSTER_NAME}" KUBECONFIG="${FAKE_KB}" \
  TIMEOUT=30 RETRY_INTERVAL=1 \
  "${SCRIPTS_DIR}/.bin/deploy-cluster.sh" >/dev/null 2>&1 || result=$?
check "retries on Error from server (InternalError)" "0" "${result}"

# ── Test 6: retries on ensure CRDs are installed first ───────────────────────
COUNTER3="${TEMP_DIR}/kubectl-calls-3"
echo "0" > "${COUNTER3}"

cat > "${STUB_BIN}/kubectl" <<STUB
#!/bin/bash
COUNT=\$(cat "${COUNTER3}")
COUNT=\$((COUNT + 1))
echo "\${COUNT}" > "${COUNTER3}"
if [ "\${COUNT}" -eq 1 ]; then
  echo "error: resource mapping not found for name \"flux-platform\" namespace \"flux-system\" from \"STDIN\": no matches for kind \"Kustomization\" in version \"kustomize.toolkit.fluxcd.io/v1\"; ensure CRDs are installed first"
else
  echo "namespace/flux-system serverside-applied"
fi
STUB
chmod +x "${STUB_BIN}/kubectl"

result=0
CLUSTER_PATH="${CLUSTER_PATH}" CLUSTER_NAME="${CLUSTER_NAME}" KUBECONFIG="${FAKE_KB}" \
  TIMEOUT=30 RETRY_INTERVAL=1 \
  "${SCRIPTS_DIR}/.bin/deploy-cluster.sh" >/dev/null 2>&1 || result=$?
check "retries on ensure CRDs are installed first" "0" "${result}"

# ── Test 7: retries when ensure CRDs line appears without error: prefix ───────
COUNTER4="${TEMP_DIR}/kubectl-calls-4"
echo "0" > "${COUNTER4}"

cat > "${STUB_BIN}/kubectl" <<STUB
#!/bin/bash
COUNT=\$(cat "${COUNTER4}")
COUNT=\$((COUNT + 1))
echo "\${COUNT}" > "${COUNTER4}"
if [ "\${COUNT}" -eq 1 ]; then
  echo "unable to recognize \"STDIN\": no matches for kind \"GitRepository\" in version \"source.toolkit.fluxcd.io/v1\"; ensure CRDs are installed first"
else
  echo "namespace/flux-system serverside-applied"
fi
STUB
chmod +x "${STUB_BIN}/kubectl"

result=0
CLUSTER_PATH="${CLUSTER_PATH}" CLUSTER_NAME="${CLUSTER_NAME}" KUBECONFIG="${FAKE_KB}" \
  TIMEOUT=30 RETRY_INTERVAL=1 \
  "${SCRIPTS_DIR}/.bin/deploy-cluster.sh" >/dev/null 2>&1 || result=$?
check "retries on ensure CRDs without error: prefix" "0" "${result}"

echo ""
[ "${FAIL}" -eq 0 ] && echo "All tests passed." || { echo "${FAIL} test(s) failed."; exit 1; }
