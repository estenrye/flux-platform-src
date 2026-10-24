#!/usr/bin/env bash
# Release a leaked Calico IPAM allocation for a LoadBalancer IP.
#
# Usage: CLUSTER=<cluster> release-calico-ipam-allocation.sh <ip-address> [--dry-run]
#
# Calico's LoadBalancer controller allocates a Service's address from an IP
# pool. If a Service is deleted and recreated under the same name, the old
# allocation can survive (it is keyed to the same namespace/service), leaving
# two IPs for one Service; the controller then flips the Service's status
# between them. This releases the stale one.
#
# It refuses to release anything a live Service still uses (status ingress,
# externalIPs, clusterIP) and anything not owned by a LoadBalancer Service, so
# it cannot free an address that is actually in service. Use --dry-run to see
# what would be released without changing anything.
#
# The cluster's kubeconfig comes from the rye.ninja/kubeconfig annotation in
# clusters/<name>/catalog.yaml. calicoctl is installed on demand and pinned to
# the cluster's Calico version (see install-calicoctl.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"

DRY_RUN=false
IP=""
for arg in "$@"; do
  case "${arg}" in
    --dry-run|-n) DRY_RUN=true ;;
    -h|--help)
      sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) error "Unknown option: ${arg}"; exit 1 ;;
    *)
      [ -z "${IP}" ] || { error "Only one IP address may be given"; exit 1; }
      IP="${arg}"
      ;;
  esac
done

[ -n "${IP}" ] || { error "Usage: CLUSTER=<cluster> $(basename "$0") <ip-address> [--dry-run]"; exit 1; }
python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "${IP}" 2>/dev/null \
  || { error "Not a valid IP address: ${IP}"; exit 1; }

CALICOCTL="${REPO_ROOT}/.venv/bin/calicoctl"
"${SCRIPT_DIR}/install-calicoctl.sh" >/dev/null
[ -x "${CALICOCTL}" ] || { error "calicoctl not found at ${CALICOCTL}"; exit 1; }

export DATASTORE_TYPE=kubernetes

# ── Step 1: Look up the allocation ────────────────────────────────────────────
info "Looking up IPAM allocation for ${IP} on ${CLUSTER_NAME} ..."
SHOW=$("${CALICOCTL}" ipam show --ip="${IP}" 2>&1) || { error "calicoctl ipam show failed:"; echo "${SHOW}" >&2; exit 1; }

if grep -q "is not assigned" <<<"${SHOW}"; then
  success "${IP} is not allocated, nothing to release"
  exit 0
fi

attr() { awk -v k="$1" '$1 == k":" {print $2}' <<<"${SHOW}"; }
OWNER_TYPE=$(attr type)
OWNER_NS=$(attr namespace)
OWNER_SVC=$(attr service)
HANDLE=$(awk '/^Handle ID:/ {print $3}' <<<"${SHOW}")

echo "${SHOW}"

if [ "${OWNER_TYPE}" != "LoadBalancer" ] || [ -z "${OWNER_NS}" ] || [ -z "${OWNER_SVC}" ]; then
  error "${IP} is not owned by a LoadBalancer Service (type='${OWNER_TYPE:-unknown}'); refusing to release it"
  exit 1
fi

# ── Step 2: Make sure nothing live is using it ────────────────────────────────
info "Checking that no Service is using ${IP} ..."
IN_USE=$(kubectl get svc -A -o json | python3 -c '
import ipaddress, json, sys
target = ipaddress.ip_address(sys.argv[1])
def same(v):
    try:
        return ipaddress.ip_address(v) == target
    except ValueError:
        return False
for s in json.load(sys.stdin)["items"]:
    name = "%s/%s" % (s["metadata"]["namespace"], s["metadata"]["name"])
    spec, st = s.get("spec", {}), s.get("status", {})
    for i in (st.get("loadBalancer", {}).get("ingress") or []):
        if same(i.get("ip", "")):
            print("%s (status.loadBalancer.ingress)" % name)
    for v in (spec.get("externalIPs") or []):
        if same(v):
            print("%s (spec.externalIPs)" % name)
    for v in (spec.get("clusterIPs") or []):
        if same(v):
            print("%s (spec.clusterIPs)" % name)
' "${IP}")

if [ -n "${IN_USE}" ]; then
  error "${IP} is in use by a live Service; refusing to release it:"
  echo "${IN_USE}" >&2
  exit 1
fi
success "No Service is using ${IP}"

CURRENT=$(kubectl get svc -n "${OWNER_NS}" "${OWNER_SVC}" -o jsonpath='{.status.loadBalancer.ingress[*].ip}' 2>/dev/null || true)
if [ -n "${CURRENT}" ]; then
  info "Service ${OWNER_NS}/${OWNER_SVC} currently holds: ${CURRENT}"
else
  warn "Service ${OWNER_NS}/${OWNER_SVC} has no LoadBalancer IP (or no longer exists); ${IP} is a leaked allocation"
fi

if [ "${DRY_RUN}" = true ]; then
  info "Dry run: would release ${IP} (handle ${HANDLE})"
  exit 0
fi

# ── Step 3: Release and verify ────────────────────────────────────────────────
info "Releasing ${IP} (handle ${HANDLE}) ..."
"${CALICOCTL}" ipam release --ip="${IP}"

AFTER=$("${CALICOCTL}" ipam show --ip="${IP}" 2>&1 || true)
if grep -q "is not assigned" <<<"${AFTER}"; then
  success "Released ${IP}; it is no longer allocated"
else
  error "${IP} still shows as allocated after release:"
  echo "${AFTER}" >&2
  exit 1
fi
