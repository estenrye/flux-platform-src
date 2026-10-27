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

workload() { # kind name trust-domain-args...
  local kind="$1" name="$2"; shift 2
  printf -- '---\napiVersion: apps/v1\nkind: %s\nmetadata:\n  name: %s\nspec:\n  template:\n    spec:\n      containers:\n      - name: driver\n        args:\n        - --log-level=1\n' "${kind}" "${name}"
  for a in "$@"; do printf '        - %s\n' "${a}"; done
}

run() { "${SCRIPTS_DIR}/.bin/lint-spiffe-trust-domain.sh" "${TEMP_DIR}/$1" 2>&1; }

# ── Test 1: single non-default trust domain passes ────────────────────────────
workload Deployment approver --trust-domain=a.example > "${FIXTURES}/good.yaml"
workload DaemonSet driver --trust-domain=a.example >> "${FIXTURES}/good.yaml"
run good >/dev/null; check "single custom trust domain passes" "0" "$?"

# ── Test 2: no trust-domain args at all passes (driver not deployed) ──────────
workload Deployment unrelated > "${FIXTURES}/none.yaml"
run none >/dev/null; check "no trust-domain args passes" "0" "$?"

# ── Test 3: cluster.local fails ───────────────────────────────────────────────
workload DaemonSet driver --trust-domain=cluster.local > "${FIXTURES}/local.yaml"
OUT=$(run local); check "cluster.local fails" "1" "$?"
echo "${OUT}" | grep -q "prohibited trust domain cluster.local"
check "cluster.local failure is reported" "0" "$?"

# ── Test 4: unpatched base alongside a patched one still fails ────────────────
workload Deployment approver --trust-domain=a.example > "${FIXTURES}/mixed.yaml"
workload DaemonSet driver --trust-domain=cluster.local >> "${FIXTURES}/mixed.yaml"
run mixed >/dev/null; check "one unpatched workload fails" "1" "$?"

# ── Test 5: duplicate trust-domain args fail, even when both are custom ───────
workload DaemonSet driver --trust-domain=a.example --trust-domain=b.example > "${FIXTURES}/dup.yaml"
OUT=$(run dup); check "duplicate trust-domain args fail" "1" "$?"
echo "${OUT}" | grep -q "has 2 --trust-domain args"
check "duplicate failure is reported" "0" "$?"

# ── Test 6: duplicate where one is cluster.local reports both problems ────────
workload DaemonSet driver --trust-domain=a.example --trust-domain=cluster.local > "${FIXTURES}/dup-local.yaml"
OUT=$(run dup-local); check "duplicate + cluster.local fails" "1" "$?"
check "both failures reported" "2" "$(echo "${OUT}" | grep -c '^FAIL')"

# ── Test 7: space-separated form is counted too ───────────────────────────────
workload DaemonSet driver --trust-domain=a.example "--trust-domain" > "${FIXTURES}/space.yaml"
run space >/dev/null; check "bare --trust-domain counted as duplicate" "1" "$?"

# ── Test 8: the real core-infra render is clean ───────────────────────────────
rm "${STUB_BIN}/kustomize"
PATH="$(echo "${PATH}" | sed "s|${STUB_BIN}:||")" "${SCRIPTS_DIR}/.bin/lint-spiffe-trust-domain.sh" "${SCRIPTS_DIR}/clusters/core-infra" >/dev/null 2>&1
check "clusters/core-infra render passes" "0" "$?"

[ "${FAIL}" -eq 0 ]
