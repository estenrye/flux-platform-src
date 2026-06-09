#!/bin/bash
SCRIPTS_DIR=$(cd "$(dirname "$0")/../.." && pwd)
TEMP_DIR=$(mktemp -d)
TILDE_KB_PATH=""
cleanup() {
  [ -n "${TILDE_KB_PATH}" ] && rm -f "${TILDE_KB_PATH}"
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

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

# Real kubeconfig file the lib checks for existence
FAKE_KB="${TEMP_DIR}/kubeconfig.yaml"
touch "${FAKE_KB}"

# ── Test 1: annotation takes precedence over KUBECONFIG env var ──────────────
CATALOG_1="${TEMP_DIR}/catalog-with-annotation.yaml"
cat > "${CATALOG_1}" <<EOF
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: test-cluster
  annotations:
    rye.ninja/kubeconfig: ${FAKE_KB}
spec:
  owner: group:platform-engineering
  domain: platform
EOF

result=$(
  error() { echo "[ERROR] $*" >&2; }
  CATALOG="${CATALOG_1}"
  KUBECONFIG="/some/env/var/path"
  source "${SCRIPTS_DIR}/.bin/lib/prompt-kubeconfig.sh"
  echo "${KUBECONFIG}"
)
check "annotation takes precedence over env var" "${FAKE_KB}" "${result}"

# ── Test 2: env var used when annotation is absent ───────────────────────────
CATALOG_2="${TEMP_DIR}/catalog-no-annotation.yaml"
cat > "${CATALOG_2}" <<EOF
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: test-cluster
spec:
  owner: group:platform-engineering
  domain: platform
EOF

result=$(
  error() { echo "[ERROR] $*" >&2; }
  CATALOG="${CATALOG_2}"
  KUBECONFIG="${FAKE_KB}"
  source "${SCRIPTS_DIR}/.bin/lib/prompt-kubeconfig.sh"
  echo "${KUBECONFIG}"
)
check "env var fallback when annotation absent" "${FAKE_KB}" "${result}"

# ── Test 3: tilde in annotation path is expanded to $HOME ────────────────────
TILDE_KB_FILE=".test-kb-$$.yaml"
TILDE_KB_PATH="${HOME}/${TILDE_KB_FILE}"
touch "${TILDE_KB_PATH}"

CATALOG_3="${TEMP_DIR}/catalog-tilde.yaml"
printf 'apiVersion: backstage.io/v1alpha1\nkind: System\nmetadata:\n  name: test-cluster\n  annotations:\n    rye.ninja/kubeconfig: ~/%s\nspec:\n  owner: group:platform-engineering\n  domain: platform\n' \
  "${TILDE_KB_FILE}" > "${CATALOG_3}"

result=$(
  error() { echo "[ERROR] $*" >&2; }
  CATALOG="${CATALOG_3}"
  unset KUBECONFIG
  source "${SCRIPTS_DIR}/.bin/lib/prompt-kubeconfig.sh"
  echo "${KUBECONFIG}"
)
check "tilde in annotation is expanded" "${TILDE_KB_PATH}" "${result}"

echo ""
[ "${FAIL}" -eq 0 ] && echo "All tests passed." || { echo "${FAIL} test(s) failed."; exit 1; }
