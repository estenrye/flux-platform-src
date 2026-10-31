#!/bin/bash
# Step 1 of the SeaweedFS restore drill: write known audit objects to PRODUCTION and record where their data lives.
#   - versioned/drill/audit-versions.txt: two versions (unlocked; removed again by teardown.sh)
#   - locked/drill/audit-record.bin: 200000 random bytes under COMPLIANCE retention for 24 hours
# SIDE EFFECT: the locked object cannot be deleted until its retention ends (24 h); it is tiny and expires on its own.
source "$(dirname "$0")/common.sh"
cd "${WORK}" || exit 1
[ "$(prod_not_ready)" = "0" ] || { log "ABORT: SeaweedFS is not fully healthy"; exit 1; }
# find the raft leader (lookups on a follower are redirected)
LEADER=""; for p in 0 1 2; do
  [ "$(kubectl -n "${NS}" exec "seaweedfs-master-$p" -- sh -c 'wget -qO- http://localhost:9333/cluster/status' 2>/dev/null | jq -r '.IsLeader // false')" = "true" ] && { LEADER="seaweedfs-master-$p"; break; }
done
[ -n "${LEADER}" ] || { log "ABORT: no master leader found"; exit 1; }
kubectl -n "${NS}" port-forward svc/seaweedfs-s3 18333:8333 --address 127.0.0.1 >/dev/null 2>&1 & P1=$!
kubectl -n "${NS}" port-forward pod/seaweedfs-filer-0 18888:8888 --address 127.0.0.1 >/dev/null 2>&1 & P2=$!
kubectl -n "${NS}" port-forward "pod/${LEADER}" 19333:9333 --address 127.0.0.1 >/dev/null 2>&1 & P3=$!
trap 'kill ${P1} ${P2} ${P3} 2>/dev/null' EXIT
wait_http http://127.0.0.1:18333/ && wait_http http://127.0.0.1:18888/ && wait_http http://127.0.0.1:19333/cluster/status || { log "ABORT: port-forwards not ready"; exit 1; }
s3_creds
a() { aws --endpoint-url http://127.0.0.1:18333 "$@"; }
TS=$(date -u +%Y%m%dT%H%M%SZ); UNTIL=$(date -u -v+24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ)
printf 'audit-v1 %s\n' "${TS}" > v1.txt; printf 'audit-v2 %s\n' "${TS}" > v2.txt; head -c 200000 /dev/urandom > locked.bin
V1=$(a s3api put-object --bucket versioned --key drill/audit-versions.txt --body v1.txt --query VersionId --output text)
V2=$(a s3api put-object --bucket versioned --key drill/audit-versions.txt --body v2.txt --query VersionId --output text)
LVID=$(a s3api put-object --bucket locked --key drill/audit-record.bin --body locked.bin --object-lock-mode COMPLIANCE --object-lock-retain-until-date "${UNTIL}" --query VersionId --output text)
# Record what was written FIRST, so teardown.sh can still clean up if a later step fails.
cat > state.env <<ENVEND
TS=${TS}
UNTIL=${UNTIL}
V1=${V1}
V2=${V2}
LVID=${LVID}
V1_SHA=$(shasum -a 256 v1.txt | cut -d' ' -f1)
V2_SHA=$(shasum -a 256 v2.txt | cut -d' ' -f1)
LOCKED_SHA=$(shasum -a 256 locked.bin | cut -d' ' -f1)
ENVEND
rm -f v1.txt v2.txt locked.bin; unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
# Where does the locked object's data live? Versioned buckets keep each version under <key>.versions/v_<versionId>;
# in the entry's metadata, .chunks[0].fid is an object and its .volume_id is the volume.
VOLID=$(curl -s --max-time 10 "http://127.0.0.1:18888/buckets/locked/drill/audit-record.bin.versions/v_${LVID}?metadata=true" | jq -r '.chunks[0].fid.volume_id // empty')
[ -n "${VOLID}" ] || { log "ABORT: could not find the object's chunk (stored inline?); state saved, run teardown.sh"; exit 1; }
URL=$(curl -s --max-time 10 "http://127.0.0.1:19333/dir/lookup?volumeId=${VOLID}&collection=locked" | jq -r '.locations[0].url // empty')
N=$(echo "${URL}" | sed -E 's/^seaweedfs-volume-([0-9]+)\..*/\1/')
echo "${N}" | grep -qE '^[0-9]+$' || { log "ABORT: cannot map volume ${VOLID} (lookup returned '${URL}') to a volume server; state saved, run teardown.sh"; exit 1; }
printf 'VOLID=%s\nSRC_PVC=data-seaweedfs-volume-%s\n' "${VOLID}" "${N}" >> state.env
log "seeded: versions ${V1}, ${V2}; locked version ${LVID} (COMPLIANCE until ${UNTIL}); chunk in volume ${VOLID} on volume server ${N} -> will snapshot data-seaweedfs-volume-${N}"
