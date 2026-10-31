#!/bin/bash
# Step 3: verify the audit data through the SCRATCH S3 (restored database + restored volume) against what production recorded.
# Needs state.env from seed.sh and a running scratch stack from restore.sh.
source "$(dirname "$0")/common.sh"
cd "${WORK}" || exit 1
source state.env
PASS=0; FAILN=0
ok() { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1 -- $2"; FAILN=$((FAILN+1)); }
kubectl -n $NS port-forward svc/drill-filer 28333:8333 --address 127.0.0.1 >/dev/null 2>&1 & PF=$!
wait_http http://127.0.0.1:28333/ || { echo "ABORT: scratch S3 not reachable"; exit 1; }
s3_creds
a() { aws --endpoint-url http://127.0.0.1:28333 "$@"; }
sha() { shasum -a 256 | cut -d' ' -f1; }
# fetch <bucket> <key> <version-id> <outfile>: reads go through kubectl port-forward, which can drop a connection, so
# retry a few times and show the real S3 error if every attempt fails (instead of reporting a bare checksum mismatch).
fetch() { local err; for _ in 1 2 3; do err=$(a s3api get-object --bucket "$1" --key "$2" --version-id "$3" "$4" 2>&1 >/dev/null) && return 0; sleep 2; done; echo "  fetch failed after 3 tries: $(echo "${err}" | tail -1 | cut -c1-220)"; return 1; }

echo "== buckets and configuration restored from the database"
a s3api list-buckets --query 'Buckets[].Name' --output text | tr '\t' '\n' | sort | tr '\n' ' ' | grep -q "locked.*versioned" && ok "buckets locked and versioned exist" || bad "buckets" "missing"
[ "$(a s3api get-bucket-versioning --bucket locked --query Status --output text)" = "Enabled" ] && ok "locked: versioning Enabled" || bad "locked versioning" "not Enabled"
[ "$(a s3api get-object-lock-configuration --bucket locked --query ObjectLockConfiguration.ObjectLockEnabled --output text)" = "Enabled" ] && ok "locked: Object Lock Enabled" || bad "locked object lock" "not Enabled"

echo "== version history ('versioned' bucket, metadata only)"
N=$(a s3api list-object-versions --bucket versioned --prefix drill/audit-versions.txt --query 'length(Versions)' --output text)
[ "$N" = "2" ] && ok "two versions present" || bad "version count" "got $N"
a s3api list-object-versions --bucket versioned --prefix drill/audit-versions.txt --query 'Versions[].VersionId' --output text | tr '\t' '\n' | grep -qx "$V1" && a s3api list-object-versions --bucket versioned --prefix drill/audit-versions.txt --query 'Versions[].VersionId' --output text | tr '\t' '\n' | grep -qx "$V2" && ok "version ids identical to production ($V1, $V2)" || bad "version ids" "differ from production"

echo "== data read from the restored volume"
rm -f ${WORK}/out.*
fetch locked drill/audit-record.bin "$LVID" "${WORK}/out.locked"; [ "$(sha < "${WORK}/out.locked" 2>/dev/null)" = "$LOCKED_SHA" ] && ok "locked object: 200000 bytes read back, SHA-256 matches production" || bad "locked object content" "checksum differs or read failed"
fetch versioned drill/audit-versions.txt "$V1" "${WORK}/out.v1"; [ "$(sha < "${WORK}/out.v1" 2>/dev/null)" = "$V1_SHA" ] && ok "versioned v1 content matches" || bad "v1 content" "differs"
fetch versioned drill/audit-versions.txt "$V2" "${WORK}/out.v2"; [ "$(sha < "${WORK}/out.v2" 2>/dev/null)" = "$V2_SHA" ] && ok "versioned v2 content matches" || bad "v2 content" "differs"

echo "== retention state restored with the object"
R=$(a s3api get-object-retention --bucket locked --key drill/audit-record.bin --version-id "$LVID" --output json 2>&1)
[ "$(echo "$R" | jq -r '.Retention.Mode' 2>/dev/null)" = "COMPLIANCE" ] && ok "retention mode is COMPLIANCE" || bad "retention mode" "$R"
[ "$(echo "$R" | jq -r '.Retention.RetainUntilDate' 2>/dev/null | cut -c1-19)" = "${UNTIL%Z}" ] && ok "retain-until date matches production ($UNTIL)" || bad "retain-until" "$(echo "$R" | jq -c .Retention 2>/dev/null) vs $UNTIL"

echo "== the lock is still ENFORCED on the restored copy"
OUT=$(a s3api delete-object --bucket locked --key drill/audit-record.bin --version-id "$LVID" 2>&1); [ $? -ne 0 ] && ok "delete of the locked version is refused ($(echo "$OUT" | grep -o 'AccessDenied' | head -1))" || bad "lock enforcement" "delete unexpectedly succeeded"
OUT=$(a s3api delete-object --bucket locked --key drill/audit-record.bin --version-id "$LVID" --bypass-governance-retention 2>&1); [ $? -ne 0 ] && ok "bypass-governance cannot delete a COMPLIANCE version either" || bad "compliance bypass" "unexpectedly succeeded"
fetch locked drill/audit-record.bin "$LVID" "${WORK}/out.again" && [ "$(sha < "${WORK}/out.again")" = "$LOCKED_SHA" ] && ok "object still intact after the refused deletes" || bad "intact" "object unreadable or changed"

kill $PF 2>/dev/null; unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; rm -f ${WORK}/out.*
echo "== RESULT: $PASS passed, $FAILN failed"; [ "$FAILN" -eq 0 ]
