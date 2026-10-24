#!/usr/bin/env bash
# Reproduce the Calico LoadBalancer stale-handle bug on a throwaway Service and
# report whether it is present in the Calico version the cluster is running.
#
# Usage: CLUSTER=<cluster> reproduce-calico-lb-stale-handle.sh
#
# Background: docs/research/calico-bgp-iam-flap-ipv6.md. When a Service is
# deleted and recreated under the same name while kube-controllers is down, the
# old allocation (keyed to the old UID) is never released, and the controller
# then applies that stale key to the live Service:
#   phase 1  the Service status flips between its two addresses
#   phase 2  after the stale address is released by hand, the controller clears
#            the status (empty ingress) on every IPAM sync
#   phase 3  after restarting kube-controllers the clears stop (workaround)
#
# Everything happens on one Service (calico-lb-repro/repro-lb) in the
# lb-internal-routed pool. It briefly force-kills calico-kube-controllers
# (the Deployment recreates it within seconds) and removes the namespace at the
# end, releasing any IPs the test leaked. It does not touch other Services.
#
# Verdict line: "BUG PRESENT" when phases 1 and 2 reproduce, "NOT REPRODUCED"
# when they do not. The exit code is 0 whenever the run completes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"

NS="calico-lb-repro"
SVC="repro-lb"
POOL="${REPRO_POOL:-lb-internal-routed}"
PHASE1_SECONDS="${PHASE1_SECONDS:-90}"
PHASE2_SECONDS="${PHASE2_SECONDS:-90}"
PHASE3_SECONDS="${PHASE3_SECONDS:-60}"
CALICOCTL="${REPO_ROOT}/.venv/bin/calicoctl"

TMP_DIR=$(mktemp -d -t calico-lb-repro.XXXXXXXXXX)
WATCH_FILE="${TMP_DIR}/watch"
MARKS="${TMP_DIR}/marks"
WATCH_PID=""

cleanup() {
  local code=$?
  set +e
  trap - EXIT
  stop_watch
  info "Cleaning up ${NS} ..."
  kubectl delete namespace "${NS}" --wait=true --timeout=120s >/dev/null 2>&1
  release_leaks_in_ns
  rm -rf "${TMP_DIR}"
  exit ${code}
}
trap cleanup EXIT INT TERM

stop_watch() {
  pkill -f "get svc -n ${NS} -w" 2>/dev/null || true
  [ -n "${WATCH_PID}" ] && kill "${WATCH_PID}" 2>/dev/null || true
  WATCH_PID=""
}

mark() { echo "$(date +%s) $1" >> "${MARKS}"; }

# Leaked allocations for the test Service, one IP per line (empty = none).
leaked_ips() {
  IPAM_GRACE_SECONDS=0 "${SCRIPT_DIR}/detect-calico-ipam-flapping.sh" 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | awk -v n="(${NS}/${SVC};" '$1 == "LEAKED" && index($0, n) {print $2}' || true
}   # the detector exits 1 when it finds a leak, which is what we are looking for

release_leaks_in_ns() {
  local ip
  for ip in $(leaked_ips); do
    warn "Releasing leaked ${ip}"
    CLUSTER="${CLUSTER}" "${SCRIPT_DIR}/release-calico-ipam-allocation.sh" "${ip}" >/dev/null 2>&1 || true
  done
}

service_ips() {
  kubectl get svc -n "${NS}" "${SVC}" -o jsonpath='{.status.loadBalancer.ingress[*].ip}' 2>/dev/null || true
}

apply_service() {
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: ${NS}
  annotations:
    projectcalico.org/ipv6pools: '["${POOL}"]'
spec:
  type: LoadBalancer
  loadBalancerClass: calico
  ipFamilyPolicy: SingleStack
  ipFamilies: ["IPv6"]
  ports:
    - port: 80
      protocol: TCP
EOF
}

wait_for_ip() {
  local i
  for i in $(seq 1 60); do
    [ -n "$(service_ips)" ] && return 0
    sleep 1
  done
  return 1
}

wait_for_controller() {
  kubectl rollout status -n calico-system deploy/calico-kube-controllers --timeout=180s >/dev/null
  # The old pod can still be Terminating; wait until exactly one ready pod remains.
  local i
  for i in $(seq 1 60); do
    [ "$(kubectl get pods -n calico-system -l k8s-app=calico-kube-controllers --no-headers 2>/dev/null | grep -c ' 1/1 .*Running')" = 1 ] && return 0
    sleep 2
  done
  return 1
}

# ── Preconditions ─────────────────────────────────────────────────────────────
"${SCRIPT_DIR}/install-calicoctl.sh" >/dev/null
VERSION=$(kubectl get deploy -n calico-system calico-kube-controllers -o jsonpath='{.spec.template.spec.containers[0].image}')
info "Cluster ${CLUSTER_NAME}, kube-controllers image: ${VERSION}"

if kubectl get namespace "${NS}" >/dev/null 2>&1; then
  error "Namespace ${NS} already exists (leftover from a previous run?). Delete it first."
  trap - EXIT
  rm -rf "${TMP_DIR}"
  exit 1
fi
if ! IPAM_GRACE_SECONDS=60 "${SCRIPT_DIR}/detect-calico-ipam-flapping.sh" >/dev/null 2>&1; then
  error "The IPAM leak check already fails on ${CLUSTER_NAME}; fix that first (make detect-calico-ipam-flapping)"
  trap - EXIT
  rm -rf "${TMP_DIR}"
  exit 1
fi

# ── Setup ─────────────────────────────────────────────────────────────────────
info "Creating ${NS}/${SVC} ..."
kubectl create namespace "${NS}" >/dev/null
apply_service
wait_for_ip || { error "Service never got an address"; exit 1; }
IP_A=$(service_ips)
success "Service has ${IP_A}"

kubectl get svc -n "${NS}" -w -o jsonpath='{.metadata.uid} {.status.loadBalancer.ingress[*].ip}{"\n"}' 2>/dev/null \
  | while IFS= read -r line; do printf '%s %s\n' "$(date +%s)" "${line}"; done > "${WATCH_FILE}" &
WATCH_PID=$!

# ── Phase 1: recreate the Service while the controller is down ────────────────
info "Phase 1: force-killing kube-controllers and recreating the Service while it is down ..."
mark "phase1-start"
kubectl delete pod -n calico-system -l k8s-app=calico-kube-controllers --force --grace-period=0 --wait=false >/dev/null 2>&1
kubectl delete svc -n "${NS}" "${SVC}" --wait=true >/dev/null
apply_service
wait_for_controller || { error "kube-controllers did not come back"; exit 1; }
info "Controller is back; observing for ${PHASE1_SECONDS}s ..."
sleep "${PHASE1_SECONDS}"

STALE=$(leaked_ips | head -n 1 || true)
if [ -z "${STALE}" ]; then
  warn "No leaked allocation exists, so the recreate did not leak (controller handled the delete)"
else
  success "Leaked allocation present: ${STALE} (Service now holds: $(service_ips))"
fi

# ── Phase 2: release the stale address ────────────────────────────────────────
mark "phase2-start"
if [ -n "${STALE}" ]; then
  info "Phase 2: releasing ${STALE} ..."
  released=false
  for i in $(seq 1 15); do
    if CLUSTER="${CLUSTER}" "${SCRIPT_DIR}/release-calico-ipam-allocation.sh" "${STALE}" >/dev/null 2>&1; then
      released=true
      break
    fi
    sleep 3   # the script refuses while the live Service momentarily holds the stale address
  done
  [ "${released}" = true ] && success "Released ${STALE}" || warn "Could not release ${STALE}"
fi
info "Observing for ${PHASE2_SECONDS}s ..."
sleep "${PHASE2_SECONDS}"

# ── Phase 3: restart kube-controllers, expect quiet ───────────────────────────
mark "phase3-start"
info "Phase 3: restarting kube-controllers (workaround) ..."
kubectl delete pod -n calico-system -l k8s-app=calico-kube-controllers --wait=false >/dev/null 2>&1
sleep 5
wait_for_controller || warn "kube-controllers slow to return"
mark "phase3-ready"
info "Observing for ${PHASE3_SECONDS}s ..."
sleep "${PHASE3_SECONDS}"
mark "end"

stop_watch

# ── Report ────────────────────────────────────────────────────────────────────
python3 - "${WATCH_FILE}" "${MARKS}" "${STALE:-}" <<'PY'
import collections, sys, time

watch, marks, stale = sys.argv[1], sys.argv[2], sys.argv[3]
bounds = {}
for l in open(marks):
    t, n = l.split()
    bounds[n] = int(t)

# Transitions per Service UID (a new UID starts a fresh baseline).
last = {}
events = []  # (time, kind, old, new)
for l in open(watch):
    parts = l.split()
    if len(parts) < 2:
        continue
    t, uid, ips = int(parts[0]), parts[1], frozenset(parts[2:])
    if uid in last and last[uid] != ips:
        old = last[uid]
        kind = "CLEARED" if not ips else ("RESTORED" if not old else "CHANGED")
        events.append((t, kind, sorted(old), sorted(ips)))
    last[uid] = ips

def phase(t):
    if t >= bounds.get("phase3-ready", 1 << 62): return 3
    if t >= bounds.get("phase3-start", 1 << 62): return 0   # controller restarting
    if t >= bounds.get("phase2-start", 1 << 62): return 2
    return 1

counts = collections.Counter((phase(t), k) for t, k, _, _ in events)
for t, k, old, new in events:
    p = phase(t)
    label = {1: "phase 1", 2: "phase 2", 3: "phase 3", 0: "restart "}[p]
    print("  %s  %s  %-8s %s -> %s" % (label, time.strftime("%H:%M:%SZ", time.gmtime(t)), k, ",".join(old) or "(none)", ",".join(new) or "(none)"))

p1_flip = counts[(1, "CHANGED")] > 0
p2_clear = counts[(2, "CLEARED")] > 0
p3_quiet = sum(v for (p, k), v in counts.items() if p == 3) == 0
print()
print("phase 1  address flips (CHANGED)      : %d  %s" % (counts[(1, "CHANGED")], "reproduced" if p1_flip else "not seen"))
print("phase 2  status clears after release  : %d  %s" % (counts[(2, "CLEARED")], "reproduced" if p2_clear else "not seen"))
print("phase 3  events after restart         : %d  %s" % (sum(v for (p, k), v in counts.items() if p == 3), "quiet" if p3_quiet else "NOT quiet"))
print()
print("VERDICT: " + ("BUG PRESENT" if (p1_flip and p2_clear) else "NOT REPRODUCED"))
PY
