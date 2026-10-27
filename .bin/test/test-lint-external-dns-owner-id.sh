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

external_dns() { # deployment-name arg...
  local name="$1"; shift
  printf -- '---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: %s\n  namespace: external-dns\nspec:\n  template:\n    spec:\n      containers:\n      - name: external-dns\n        args:\n        - --provider=cloudflare\n' "${name}"
  for a in "$@"; do printf '        - %s\n' "${a}"; done
}

run() { "${SCRIPTS_DIR}/.bin/lint-external-dns-owner-id.sh" "${TEMP_DIR}/$1" 2>&1; }

# ── Test 1: external-dns absent passes ────────────────────────────────────────
printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: unrelated\n  namespace: default\n' > "${FIXTURES}/absent.yaml"
run absent >/dev/null; check "external-dns absent passes" "0" "$?"

# ── Test 2: owner id set passes ───────────────────────────────────────────────
external_dns external-dns --registry=txt --txt-owner-id=c > "${FIXTURES}/good.yaml"
run good >/dev/null; check "txt registry with owner id passes" "0" "$?"

# ── Test 3: no owner id fails ─────────────────────────────────────────────────
external_dns external-dns --registry=txt > "${FIXTURES}/missing.yaml"
OUT=$(run missing); check "missing owner id fails" "1" "$?"
echo "${OUT}" | grep -q "Deployment/external-dns/external-dns uses the TXT registry without --txt-owner-id"
check "missing owner id is reported" "0" "$?"

# ── Test 4: registry defaults to txt, so no --registry arg still fails ────────
external_dns external-dns > "${FIXTURES}/default.yaml"
run default >/dev/null; check "default registry without owner id fails" "1" "$?"

# ── Test 5: empty owner id fails ──────────────────────────────────────────────
external_dns external-dns --registry=txt --txt-owner-id= > "${FIXTURES}/empty.yaml"
run empty >/dev/null; check "empty owner id fails" "1" "$?"

# ── Test 6: noop registry is exempt ───────────────────────────────────────────
external_dns external-dns --registry=noop > "${FIXTURES}/noop.yaml"
run noop >/dev/null; check "noop registry without owner id passes" "0" "$?"

# ── Test 7: one unpatched instance among several fails ────────────────────────
{ external_dns external-dns --registry=txt --txt-owner-id=c; external_dns external-dns-cloudflare --registry=txt; } > "${FIXTURES}/two.yaml"
OUT=$(run two); check "one instance without owner id fails" "1" "$?"
echo "${OUT}" | grep -q "external-dns-cloudflare uses the TXT registry"
check "offending instance is named" "0" "$?"

# ── Test 8: a non-external-dns container is ignored ───────────────────────────
printf -- '---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: other\n  namespace: other\nspec:\n  template:\n    spec:\n      containers:\n      - name: webhook\n        args:\n        - --registry=txt\n' > "${FIXTURES}/other.yaml"
run other >/dev/null; check "unrelated container ignored" "0" "$?"

# ── Test 9: the real core-infra render is clean ───────────────────────────────
rm "${STUB_BIN}/kustomize"
PATH="$(echo "${PATH}" | sed "s|${STUB_BIN}:||")" "${SCRIPTS_DIR}/.bin/lint-external-dns-owner-id.sh" "${SCRIPTS_DIR}/clusters/core-infra" >/dev/null 2>&1
check "clusters/core-infra render passes" "0" "$?"

[ "${FAIL}" -eq 0 ]
