#!/bin/bash
# Step 4: remove everything the drill created, by label, so it works even if restore.sh stopped halfway; delete the
# unlocked test versions from production; then verify nothing is left. The COMPLIANCE object in `locked` stays until
# its retention ends (24 h after seed.sh) because it cannot be deleted earlier.
source "$(dirname "$0")/common.sh"
cd "${WORK}" || exit 1
# state.env may be missing if seed.sh failed before writing it; the scratch objects are removed by label regardless.
[ -f state.env ] && source state.env
UNTIL="${UNTIL:-unknown}"; LVID="${LVID:-}"
L='rye.ninja/purpose=seaweedfs-restore-drill'
# remember the Cinder snapshot id(s) before deleting, to confirm they are really gone
HANDLES=$(for c in $(kubectl get volumesnapshotcontent -o json | jq -r '.items[] | select(.spec.volumeSnapshotRef.name | startswith("rd-")) | .metadata.name'); do kubectl get volumesnapshotcontent "$c" -o jsonpath='{.status.snapshotHandle}{"\n"}'; done)
log "scratch stack"
kubectl -n "${NS}" delete deployment,service -l "${L}" --wait=true --timeout=180s >/dev/null 2>&1
log "recovery cluster, restored volume, snapshot, backup record"
kubectl -n "${NS}" delete cluster.postgresql.cnpg.io -l "${L}" --wait=true --timeout=300s >/dev/null 2>&1
kubectl -n "${NS}" delete pvc -l "${L}" --wait=true --timeout=600s >/dev/null 2>&1
kubectl -n "${NS}" delete volumesnapshot -l "${L}" --wait=false >/dev/null 2>&1
for h in ${HANDLES}; do
  for _ in $(seq 1 30); do
    st=$(OS "openstack volume snapshot show ${h} -f value -c status")
    echo "${st}" | grep -qi "no snapshot" && { log "cinder snapshot ${h} deleted"; break; }
    echo "${st}" | grep -qi "error_deleting" && { log "CINDER SNAPSHOT ${h} IN error_deleting"; break; }
    echo "${st}" | grep -qi "ssh\|permission\|connection" && { log "cannot reach OpenStack to confirm (${OPENSTACK_SSH}); check it manually"; break; }
    sleep 10
  done
done
log "production test objects: deleting the unlocked 'versioned' versions"
kubectl -n "${NS}" port-forward svc/seaweedfs-s3 18333:8333 --address 127.0.0.1 >/dev/null 2>&1 & PF=$!
trap 'kill ${PF} 2>/dev/null' EXIT
wait_http http://127.0.0.1:18333/ || log "WARNING: production S3 not reachable; delete versioned/drill/ by hand"
s3_creds
a() { aws --endpoint-url http://127.0.0.1:18333 "$@"; }
a s3api list-object-versions --bucket versioned --prefix drill/ --output json | jq -r '(.Versions[]?, .DeleteMarkers[]?) | "\(.Key)\t\(.VersionId)"' | while IFS=$'\t' read -r k v; do a s3api delete-object --bucket versioned --key "$k" --version-id "$v" >/dev/null 2>&1; done
log "versioned/drill/ entries left: $(a s3api list-object-versions --bucket versioned --prefix drill/ --output json | jq '[(.Versions//[])[], (.DeleteMarkers//[])[]] | length')"
if [ -n "${LVID}" ]; then log "locked/drill/audit-record.bin (${LVID}) remains until ${UNTIL}: $(a s3api get-object-retention --bucket locked --key drill/audit-record.bin --version-id "${LVID}" --query Retention.Mode --output text 2>&1)"; else log "no state.env: any locked/drill/audit-record.bin versions from a failed seed stay until their 24 h retention ends"; fi
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
log "leftovers: drill pods=$(kubectl -n "${NS}" get pods --no-headers | grep -c '^drill') pvcs=$(kubectl -n "${NS}" get pvc --no-headers | grep -c drill) clusters=$(kubectl -n "${NS}" get cluster.postgresql.cnpg.io --no-headers | grep -c drill) snapshots=$(kubectl -n "${NS}" get volumesnapshot --no-headers 2>/dev/null | wc -l | tr -d ' ') contents=$(kubectl get volumesnapshotcontent --no-headers 2>/dev/null | wc -l | tr -d ' ') PVs-not-bound=$(kubectl get pv --no-headers | awk '$5!="Bound" && $5!="Available"' | wc -l | tr -d ' ')"
log "production: $(health)"
log "TEARDOWN DONE"
