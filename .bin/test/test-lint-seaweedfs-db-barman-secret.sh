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

objectstore() {
  printf -- '---\napiVersion: barmancloud.cnpg.io/v1\nkind: ObjectStore\nmetadata:\n  name: seaweedfs-db-barman\n  namespace: seaweedfs\nspec:\n  configuration:\n    destinationPath: s3://x/\n'
}
secret() { # accessKey secretKey [name] [namespace]
  printf -- '---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\nstringData:\n' "${3:-cloudflare-r2-seaweedfs-db-barman}" "${4:-seaweedfs}"
  [ -z "$1" ] || printf '  access-key-id: %s\n' "$1"
  [ -z "$2" ] || printf '  secret-access-key: %s\n' "$2"
}

ENC='ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]'

run() { "${SCRIPTS_DIR}/.bin/lint-seaweedfs-db-barman-secret.sh" "${TEMP_DIR}/$1" 2>&1; }

# ── Test 1: ObjectStore absent passes (even without the Secret) ───────────────
printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: unrelated\n  namespace: default\n' > "${FIXTURES}/absent.yaml"
run absent >/dev/null; check "seaweedfs-db-barman absent passes" "0" "$?"

# ── Test 2: encrypted Secret present passes ───────────────────────────────────
{ objectstore; secret "${ENC}" "${ENC}"; } > "${FIXTURES}/good.yaml"
run good >/dev/null; check "encrypted secret present passes" "0" "$?"

# ── Test 3: Secret missing fails ──────────────────────────────────────────────
objectstore > "${FIXTURES}/missing.yaml"
OUT=$(run missing); check "missing secret fails" "1" "$?"
echo "${OUT}" | grep -q "Secret/cloudflare-r2-seaweedfs-db-barman.*is not rendered"
check "missing secret is reported" "0" "$?"

# ── Test 4: plaintext credentials fail ────────────────────────────────────────
{ objectstore; secret "${ENC}" plaintextvalue; } > "${FIXTURES}/plain.yaml"
OUT=$(run plain); check "plaintext secret fails" "1" "$?"
echo "${OUT}" | grep -q "'secret-access-key' is not SOPS-encrypted"
check "plaintext failure is reported" "0" "$?"

# ── Test 5: missing key fails ─────────────────────────────────────────────────
{ objectstore; secret "${ENC}" ""; } > "${FIXTURES}/nokey.yaml"
OUT=$(run nokey); check "missing key fails" "1" "$?"
echo "${OUT}" | grep -q "has no 'secret-access-key'"
check "missing key is reported" "0" "$?"

# ── Test 6: same-named Secret in another namespace does not count ─────────────
{ objectstore; secret "${ENC}" "${ENC}" cloudflare-r2-seaweedfs-db-barman other; } > "${FIXTURES}/wrongns.yaml"
run wrongns >/dev/null; check "secret in wrong namespace fails" "1" "$?"

# ── Test 7: the real core-infra render is clean ───────────────────────────────
rm "${STUB_BIN}/kustomize"
PATH="$(echo "${PATH}" | sed "s|${STUB_BIN}:||")" "${SCRIPTS_DIR}/.bin/lint-seaweedfs-db-barman-secret.sh" "${SCRIPTS_DIR}/clusters/core-infra" >/dev/null 2>&1
check "clusters/core-infra render passes" "0" "$?"

[ "${FAIL}" -eq 0 ]
