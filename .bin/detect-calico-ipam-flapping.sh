#!/usr/bin/env bash
# Detect Calico LoadBalancer IPAM problems that make a Service/Gateway address
# flap.
#
# Usage: CLUSTER=<cluster> detect-calico-ipam-flapping.sh [--watch SECONDS]
#
# 1. Static check (always): every IPAM allocation in the load-balancer pools is
#    compared with the address its Service actually holds. An allocation the
#    Service is not using (a duplicate for the same Service, or one whose
#    Service is gone) is a leak; the LoadBalancer controller can flip the
#    Service's status between the live and the leaked address. Fix a leak with
#    `make release-calico-ipam-allocation`.
# 2. Live check (--watch): watches LoadBalancer Services and Gateways for
#    SECONDS and reports every time an address changes, is cleared, or comes
#    back. Use ~330 to span a full five-minute controller cycle.
#
# Exits 1 if either check finds a problem, 0 otherwise.
#
# The cluster's kubeconfig comes from the rye.ninja/kubeconfig annotation in
# clusters/<name>/catalog.yaml. Allocations younger than IPAM_GRACE_SECONDS
# (default 60) are skipped: a Service's status lags its allocation briefly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test hooks: analyze fixtures instead of querying a cluster.
IPAM_BLOCKS_FILE="${IPAM_BLOCKS_FILE:-}"
SERVICES_FILE="${SERVICES_FILE:-}"

WATCH_SECONDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --watch)
      WATCH_SECONDS="${2:-}"
      [[ "${WATCH_SECONDS}" =~ ^[0-9]+$ ]] || { echo "[ERROR] --watch needs a number of seconds" >&2; exit 1; }
      shift 2
      ;;
    -h|--help)
      sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "[ERROR] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

source "${SCRIPT_DIR}/lib/prompt-color.sh"
if [ -z "${IPAM_BLOCKS_FILE}" ]; then
  source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
  source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"
fi

PROBLEMS=0
TMP_DIR=$(mktemp -d -t calico-ipam-flap.XXXXXXXXXX)
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "${TMP_DIR}"' EXIT

# ── 1. Static check: allocations vs. what Services actually hold ──────────────
if [ -n "${IPAM_BLOCKS_FILE}" ]; then
  BLOCKS_JSON="${IPAM_BLOCKS_FILE}"
  SERVICES_JSON="${SERVICES_FILE}"
else
  info "Reading IPAM blocks and Services on ${CLUSTER_NAME} ..."
  BLOCKS_JSON="${TMP_DIR}/blocks.json"
  SERVICES_JSON="${TMP_DIR}/services.json"
  # Calico 3.33 installs projectcalico.org/v3 as native CRDs and no longer
  # creates the crd.projectcalico.org group; clusters upgraded in place keep it.
  if kubectl get crd ipamblocks.crd.projectcalico.org >/dev/null 2>&1; then
    kubectl get ipamblocks.crd.projectcalico.org -o json > "${BLOCKS_JSON}"
  else
    kubectl get ipamblocks.projectcalico.org -o json > "${BLOCKS_JSON}"
  fi
  kubectl get svc -A -o json > "${SERVICES_JSON}"
fi

set +e
python3 - "${BLOCKS_JSON}" "${SERVICES_JSON}" "${IPAM_GRACE_SECONDS:-60}" <<'PY'
import datetime, ipaddress, json, sys

blocks = json.load(open(sys.argv[1]))["items"]
services = json.load(open(sys.argv[2]))["items"]
grace = int(sys.argv[3])
now = datetime.datetime.now(datetime.timezone.utc)

# What each Service holds right now: (namespace, name) -> set of addresses.
held = {}
for s in services:
    key = (s["metadata"]["namespace"], s["metadata"]["name"])
    ips = {ipaddress.ip_address(i["ip"])
           for i in (s.get("status", {}).get("loadBalancer", {}).get("ingress") or [])
           if i.get("ip")}
    held[key] = ips

def parse_ts(v):
    # "2026-10-22 00:38:41.432905953 +0000 UTC" -> aware datetime (seconds precision is plenty)
    try:
        return datetime.datetime.strptime(v.split(".")[0], "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    except Exception:
        return None

allocs = {}  # (ns, svc) -> list of (ip, handle, timestamp)
for b in blocks:
    spec = b["spec"]
    if spec.get("affinity") != "virtual:load-balancer":
        continue
    base = ipaddress.ip_network(spec["cidr"]).network_address
    attrs = spec.get("attributes", [])
    for ordinal, idx in enumerate(spec.get("allocations", [])):
        if idx is None:
            continue
        a = attrs[idx]
        sec = a.get("secondary") or {}
        if sec.get("type") != "LoadBalancer" or "service" not in sec:
            continue
        key = (sec.get("namespace"), sec.get("service"))
        allocs.setdefault(key, []).append((base + ordinal, a.get("handle_id"), sec.get("timestamp")))

problems = 0
for key, items in sorted(allocs.items()):
    ns, svc = key
    in_use = held.get(key)
    for ip, handle, ts in sorted(items):
        if in_use is not None and ip in in_use:
            continue
        t = parse_ts(ts or "")
        if t is not None and (now - t).total_seconds() < grace:
            continue  # newly allocated, status not caught up yet
        problems += 1
        if in_use is None:
            why = "its Service no longer exists"
        else:
            why = "the Service holds %s instead" % (", ".join(sorted(map(str, in_use))) or "no address")
        print("LEAKED  %s  (%s/%s; %s)" % (ip, ns, svc, why))
        print("        handle %s, allocated %s" % (handle, ts))
        print("        fix: CLUSTER=<cluster> IP=%s make release-calico-ipam-allocation" % ip)

sys.exit(1 if problems else 0)
PY
STATIC_RC=$?
set -e

if [ "${STATIC_RC}" -eq 0 ]; then
  success "Every load-balancer IPAM allocation is in use by its Service"
else
  error "Leaked load-balancer IPAM allocations found (see above)"
  PROBLEMS=1
fi

# ── 2. Live check: watch for address changes ──────────────────────────────────
if [ -n "${WATCH_SECONDS}" ]; then
  info "Watching LoadBalancer Services and Gateways for ${WATCH_SECONDS}s ..."
  stamp() { while IFS= read -r line; do printf '%s %s\n' "$(date +%s)" "${line}"; done; }

  kubectl get svc -A -w --request-timeout="${WATCH_SECONDS}s" \
    -o jsonpath='svc/{.metadata.namespace}/{.metadata.name} {.spec.type} {.status.loadBalancer.ingress[*].ip}{"\n"}' \
    2>/dev/null | stamp > "${TMP_DIR}/svc.watch" &
  kubectl get gateways.gateway.networking.k8s.io -A -w --request-timeout="${WATCH_SECONDS}s" \
    -o jsonpath='gateway/{.metadata.namespace}/{.metadata.name} - {.status.addresses[*].value}{"\n"}' \
    2>/dev/null | stamp > "${TMP_DIR}/gw.watch" &
  wait

  set +e
  cat "${TMP_DIR}/svc.watch" "${TMP_DIR}/gw.watch" | sort -n | python3 -c '
import sys, time
last = {}      # object -> frozenset of addresses
changes = []   # (time, object, kind, old, new)
for line in sys.stdin:
    parts = line.split()
    if len(parts) < 3:
        continue
    ts, obj, typ = parts[0], parts[1], parts[2]
    addrs = frozenset(parts[3:])
    if obj.startswith("svc/") and typ != "LoadBalancer":
        continue
    if obj in last and last[obj] != addrs:
        old = last[obj]
        if not addrs:
            kind = "CLEARED"
        elif not old:
            kind = "RESTORED"
        else:
            kind = "CHANGED"
        changes.append((int(ts), obj, kind, sorted(old), sorted(addrs)))
    last[obj] = addrs
for ts, obj, kind, old, new in changes:
    print("%s  %-9s %s  %s -> %s" % (time.strftime("%H:%M:%SZ", time.gmtime(ts)), kind, obj, ",".join(old) or "(none)", ",".join(new) or "(none)"))
sys.exit(1 if changes else 0)
'
  WATCH_RC=$?
  set -e
  if [ "${WATCH_RC}" -eq 0 ]; then
    success "No address changes seen in ${WATCH_SECONDS}s"
  else
    error "Addresses changed during the watch (see above)"
    PROBLEMS=1
  fi
fi

exit "${PROBLEMS}"
