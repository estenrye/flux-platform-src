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

objectstore() { # endpointURL [name] [namespace]
  printf -- '---\napiVersion: barmancloud.cnpg.io/v1\nkind: ObjectStore\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  configuration:\n    endpointURL: %s\n' "${2:-seaweedfs-db-barman}" "${3:-seaweedfs}" "$1"
}

GOOD=https://aba858f1baa1d8ce6c21ce3db90733d4.r2.cloudflarestorage.com

run() { "${SCRIPTS_DIR}/.bin/lint-seaweedfs-db-barman-endpoint.sh" "${TEMP_DIR}/$1" 2>&1; }

# ── Test 1: ObjectStore absent passes ─────────────────────────────────────────
printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: unrelated\n  namespace: default\n' > "${FIXTURES}/absent.yaml"
run absent >/dev/null; check "seaweedfs-db-barman absent passes" "0" "$?"

# ── Test 2: patched endpoint passes ───────────────────────────────────────────
objectstore "${GOOD}" > "${FIXTURES}/good.yaml"
run good >/dev/null; check "patched endpoint passes" "0" "$?"

# ── Test 3: base placeholder left in place fails ──────────────────────────────
objectstore https://CF_ACCOUNT_ID.r2.cloudflarestorage.com > "${FIXTURES}/placeholder.yaml"
OUT=$(run placeholder); check "placeholder endpoint fails" "1" "$?"
echo "${OUT}" | grep -q "CF_ACCOUNT_ID.*is not an R2 account endpoint"
check "placeholder failure is reported" "0" "$?"

# ── Test 4: malformed account id fails ────────────────────────────────────────
objectstore https://abc123.r2.cloudflarestorage.com > "${FIXTURES}/short.yaml"
run short >/dev/null; check "short account id fails" "1" "$?"

# ── Test 5: wrong host fails ──────────────────────────────────────────────────
objectstore http://garage.garage.svc.cluster.local:3900 > "${FIXTURES}/garage.yaml"
run garage >/dev/null; check "non-R2 endpoint fails" "1" "$?"

# ── Test 6: an unrelated ObjectStore with a placeholder is ignored ────────────
objectstore https://CF_ACCOUNT_ID.r2.cloudflarestorage.com other-barman other > "${FIXTURES}/other.yaml"
run other >/dev/null; check "unrelated ObjectStore ignored" "0" "$?"

# ── Test 7: the real core-infra render is clean ───────────────────────────────
rm "${STUB_BIN}/kustomize"
PATH="$(echo "${PATH}" | sed "s|${STUB_BIN}:||")" "${SCRIPTS_DIR}/.bin/lint-seaweedfs-db-barman-endpoint.sh" "${SCRIPTS_DIR}/clusters/core-infra" >/dev/null 2>&1
check "clusters/core-infra render passes" "0" "$?"

[ "${FAIL}" -eq 0 ]
