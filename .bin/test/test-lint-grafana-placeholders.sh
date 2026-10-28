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
  printf -- '---\napiVersion: gateway.networking.k8s.io/v1\nkind: Gateway\nmetadata:\n  name: grafana-gateway\n  namespace: grafana\nspec:\n  listeners:\n  - name: https\n    hostname: %s\n' "$1"
}
httproute() { # hostname
  printf -- '---\napiVersion: gateway.networking.k8s.io/v1\nkind: HTTPRoute\nmetadata:\n  name: grafana\n  namespace: grafana\nspec:\n  hostnames:\n  - %s\n' "$1"
}
site() { # root_url client_id
  printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: grafana-site\n  namespace: grafana\ndata:\n  GF_SERVER_ROOT_URL: %s\n  GF_AUTH_GENERIC_OAUTH_CLIENT_ID: %s\n' "$1" "$2"
}

run() { "${SCRIPTS_DIR}/.bin/lint-grafana-placeholders.sh" "${TEMP_DIR}/$1" 2>&1; }

# ── Test 1: grafana absent passes ─────────────────────────────────────────────
printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: unrelated\n  namespace: default\n' > "${FIXTURES}/absent.yaml"
run absent >/dev/null; check "grafana absent passes" "0" "$?"

# ── Test 2: everything patched passes ─────────────────────────────────────────
{ gateway c.grafana.example; httproute c.grafana.example; site https://c.grafana.example abc-123; } > "${FIXTURES}/good.yaml"
run good >/dev/null; check "patched gateway, route and site pass" "0" "$?"

# ── Test 3: HTTPRoute hostname left at placeholder fails ──────────────────────
{ gateway c.grafana.example; httproute grafana.k8s.local; site https://c.grafana.example abc-123; } > "${FIXTURES}/route.yaml"
OUT=$(run route); check "placeholder HTTPRoute hostname fails" "1" "$?"
echo "${OUT}" | grep -q "HTTPRoute/grafana still uses placeholder"
check "HTTPRoute failure is reported" "0" "$?"

# ── Test 4: Gateway hostname left at placeholder fails ────────────────────────
{ gateway grafana.k8s.local; httproute c.grafana.example; site https://c.grafana.example abc-123; } > "${FIXTURES}/gw.yaml"
OUT=$(run gw); check "placeholder Gateway hostname fails" "1" "$?"
echo "${OUT}" | grep -q "Gateway/grafana-gateway still uses placeholder"
check "Gateway failure is reported" "0" "$?"

# ── Test 5: root_url left at placeholder fails ────────────────────────────────
{ gateway c.grafana.example; httproute c.grafana.example; site https://grafana.k8s.local abc-123; } > "${FIXTURES}/root.yaml"
OUT=$(run root); check "placeholder root_url fails" "1" "$?"
echo "${OUT}" | grep -q "GF_SERVER_ROOT_URL"
check "root_url failure is reported" "0" "$?"

# ── Test 6: client_id left at placeholder fails ───────────────────────────────
{ gateway c.grafana.example; httproute c.grafana.example; site https://c.grafana.example JUMPCLOUD_OIDC_PKCE_CLIENT_ID; } > "${FIXTURES}/client.yaml"
OUT=$(run client); check "placeholder client_id fails" "1" "$?"
echo "${OUT}" | grep -q "GF_AUTH_GENERIC_OAUTH_CLIENT_ID"
check "client_id failure is reported" "0" "$?"

# ── Test 7: all placeholders reports all four ─────────────────────────────────
{ gateway grafana.k8s.local; httproute grafana.k8s.local; site https://grafana.k8s.local JUMPCLOUD_OIDC_PKCE_CLIENT_ID; } > "${FIXTURES}/all.yaml"
OUT=$(run all); check "all placeholders fail" "1" "$?"
check "all failures reported" "4" "$(echo "${OUT}" | grep -c '^FAIL')"

# ── Test 8: the real core-infra render is clean ───────────────────────────────
rm "${STUB_BIN}/kustomize"
PATH="$(echo "${PATH}" | sed "s|${STUB_BIN}:||")" "${SCRIPTS_DIR}/.bin/lint-grafana-placeholders.sh" "${SCRIPTS_DIR}/clusters/core-infra" >/dev/null 2>&1
check "clusters/core-infra render passes" "0" "$?"

[ "${FAIL}" -eq 0 ]
