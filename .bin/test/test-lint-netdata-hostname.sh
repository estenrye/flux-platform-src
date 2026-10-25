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

# kustomize stub: emits the fixture named by the build directory's basename.
STUB_BIN="${TEMP_DIR}/bin"
FIXTURES="${TEMP_DIR}/fixtures"
mkdir -p "${STUB_BIN}" "${FIXTURES}"
cat > "${STUB_BIN}/kustomize" <<STUB
#!/bin/bash
cat "${FIXTURES}/\$(basename "\${!#}").yaml"
STUB
chmod +x "${STUB_BIN}/kustomize"
export PATH="${STUB_BIN}:${PATH}"

gateway() { # hostname
  printf -- '---\napiVersion: gateway.networking.k8s.io/v1\nkind: Gateway\nmetadata:\n  name: netdata-gateway\n  namespace: netdata\nspec:\n  listeners:\n  - name: https\n    hostname: %s\n' "$1"
}
httproute() { # hostname
  printf -- '---\napiVersion: gateway.networking.k8s.io/v1\nkind: HTTPRoute\nmetadata:\n  name: netdata\n  namespace: netdata\nspec:\n  hostnames:\n  - %s\n' "$1"
}

run() { "${SCRIPTS_DIR}/.bin/lint-netdata-hostname.sh" "${TEMP_DIR}/$1" 2>&1; }

# ── Test 1: netdata absent passes ─────────────────────────────────────────────
printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: unrelated\n  namespace: default\n' > "${FIXTURES}/absent.yaml"
run absent >/dev/null; check "netdata absent passes" "0" "$?"

# ── Test 2: both hostnames patched passes ─────────────────────────────────────
{ gateway c.netdata.example; httproute c.netdata.example; } > "${FIXTURES}/good.yaml"
run good >/dev/null; check "patched gateway and route pass" "0" "$?"

# ── Test 3: HTTPRoute hostname left at placeholder fails ──────────────────────
{ gateway c.netdata.example; httproute netdata.k8s.local; } > "${FIXTURES}/route.yaml"
OUT=$(run route); check "placeholder HTTPRoute hostname fails" "1" "$?"
echo "${OUT}" | grep -q "HTTPRoute/netdata still uses placeholder"
check "HTTPRoute failure is reported" "0" "$?"

# ── Test 4: Gateway hostname left at placeholder fails ────────────────────────
{ gateway netdata.k8s.local; httproute c.netdata.example; } > "${FIXTURES}/gw.yaml"
OUT=$(run gw); check "placeholder Gateway hostname fails" "1" "$?"
echo "${OUT}" | grep -q "Gateway/netdata-gateway still uses placeholder"
check "Gateway failure is reported" "0" "$?"

# ── Test 5: both at placeholder reports both ──────────────────────────────────
{ gateway netdata.k8s.local; httproute netdata.k8s.local; } > "${FIXTURES}/both.yaml"
OUT=$(run both); check "both placeholders fail" "1" "$?"
check "both failures reported" "2" "$(echo "${OUT}" | grep -c '^FAIL')"

# ── Test 6: an unrelated route using the placeholder is ignored ───────────────
printf -- '---\napiVersion: gateway.networking.k8s.io/v1\nkind: HTTPRoute\nmetadata:\n  name: other\n  namespace: other\nspec:\n  hostnames:\n  - netdata.k8s.local\n' > "${FIXTURES}/other.yaml"
run other >/dev/null; check "unrelated resource ignored" "0" "$?"

# ── Test 7: the real core-infra render is clean ───────────────────────────────
rm "${STUB_BIN}/kustomize"
PATH="$(echo "${PATH}" | sed "s|${STUB_BIN}:||")" "${SCRIPTS_DIR}/.bin/lint-netdata-hostname.sh" "${SCRIPTS_DIR}/clusters/core-infra" >/dev/null 2>&1
check "clusters/core-infra render passes" "0" "$?"

[ "${FAIL}" -eq 0 ]
