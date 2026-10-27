#!/bin/bash
# Fixture tests for the static check in detect-calico-ipam-flapping.sh.
SCRIPTS_DIR=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="${SCRIPTS_DIR}/.bin/detect-calico-ipam-flapping.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

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

# block <ordinal:service:timestamp>... -> IPAMBlock list for the LB pool at fd97:45c2:b3a1:f00::1:9280/122
make_blocks() {
  python3 - "$@" <<'PY'
import json, sys
attrs, allocs = [], [None] * 64
for i, spec in enumerate(sys.argv[1:]):
    ordinal, svc, ts = spec.split("|")
    attrs.append({"handle_id": "lb-handle-%d" % i,
                  "secondary": {"namespace": "tigera-gateway", "service": svc,
                                "timestamp": ts, "type": "LoadBalancer"}})
    allocs[int(ordinal)] = i
print(json.dumps({"items": [{"spec": {"cidr": "fd97:45c2:b3a1:f00::1:9280/122",
                                      "affinity": "virtual:load-balancer",
                                      "allocations": allocs, "attributes": attrs}}]}))
PY
}

# services <name:ip>... -> Service list (ip empty = no address)
make_services() {
  python3 - "$@" <<'PY'
import json, sys
items = []
for spec in sys.argv[1:]:
    name, ip = spec.split("=")
    ing = [{"ip": ip}] if ip else []
    items.append({"metadata": {"namespace": "tigera-gateway", "name": name},
                  "status": {"loadBalancer": {"ingress": ing}}})
print(json.dumps({"items": items}))
PY
}

run() {
  IPAM_BLOCKS_FILE="$1" SERVICES_FILE="$2" "${SCRIPT}" 2>&1
}

OLD="2020-01-01 00:00:00.000000000 +0000 UTC"
NEW=$(date -u +"%Y-%m-%d %H:%M:%S.000000000 +0000 UTC")

# ── Test 1: healthy — one allocation, held by its Service ────────────────────
make_blocks "5|envoy-a|${OLD}" > "${TEMP_DIR}/b1.json"
make_services "envoy-a=fd97:45c2:b3a1:f00::1:9285" > "${TEMP_DIR}/s1.json"
run "${TEMP_DIR}/b1.json" "${TEMP_DIR}/s1.json" >/dev/null; check "healthy exits 0" "0" "$?"

# ── Test 2: the real incident — two allocations, Service holds one ───────────
make_blocks "4|envoy-a|${OLD}" "5|envoy-a|${OLD}" > "${TEMP_DIR}/b2.json"
make_services "envoy-a=fd97:45c2:b3a1:f00::1:9285" > "${TEMP_DIR}/s2.json"
out=$(run "${TEMP_DIR}/b2.json" "${TEMP_DIR}/s2.json"); rc=$?
check "duplicate allocation exits 1" "1" "${rc}"
check "reports the leaked IP" "1" "$(grep -c 'LEAKED  fd97:45c2:b3a1:f00::1:9284' <<<"${out}")"
check "does not flag the live IP" "0" "$(grep -c 'LEAKED  fd97:45c2:b3a1:f00::1:9285' <<<"${out}")"

# ── Test 3: orphan — the Service is gone ─────────────────────────────────────
make_blocks "7|gone|${OLD}" > "${TEMP_DIR}/b3.json"
make_services "envoy-a=fd97:45c2:b3a1:f00::1:9285" > "${TEMP_DIR}/s3.json"
out=$(run "${TEMP_DIR}/b3.json" "${TEMP_DIR}/s3.json"); rc=$?
check "orphan allocation exits 1" "1" "${rc}"
check "orphan says Service no longer exists" "1" "$(grep -c 'its Service no longer exists' <<<"${out}")"

# ── Test 4: brand-new allocation within the grace period is ignored ──────────
make_blocks "6|envoy-b|${NEW}" > "${TEMP_DIR}/b4.json"
make_services "envoy-b=" > "${TEMP_DIR}/s4.json"
run "${TEMP_DIR}/b4.json" "${TEMP_DIR}/s4.json" >/dev/null; check "new allocation inside grace exits 0" "0" "$?"

# ── Test 5: non load-balancer blocks are ignored ─────────────────────────────
python3 - <<'PY' > "${TEMP_DIR}/b5.json"
import json
print(json.dumps({"items": [{"spec": {"cidr": "fd00:db8:0:1100::/122", "affinity": "host:node-1",
        "allocations": [0], "attributes": [{"handle_id": "pod", "secondary": {"type": "pod"}}]}}]}))
PY
make_services "envoy-a=fd97:45c2:b3a1:f00::1:9285" > "${TEMP_DIR}/s5.json"
run "${TEMP_DIR}/b5.json" "${TEMP_DIR}/s5.json" >/dev/null; check "pod blocks are ignored" "0" "$?"

if [ "${FAIL}" -gt 0 ]; then
  echo "${FAIL} test(s) failed"
  exit 1
fi
echo "All tests passed"
