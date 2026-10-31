# Runbook: seaweedfs-db restore (`core-infra`)

`seaweedfs-db` is the CloudNativePG cluster behind SeaweedFS's filer
(`postgres2` store, see [ADR-29](../adr/0029-seaweedfs-object-store-on-core-infra.md)).
It holds the **metadata**: object keys, version ids, delete markers, and the
Object Lock retention and legal-hold state. The volume servers hold the data.

Backups: continuous WAL archiving plus a daily base backup (03:45 UTC, 30-day
retention) through the `barman-cloud.cloudnative-pg.io` plugin to the
Cloudflare R2 bucket `seaweedfs-db-barman`. The `ObjectStore` is
`seaweedfs-db-barman`, the `ScheduledBackup` is `seaweedfs-db-backup`, and the
R2 credentials come from the 1Password item `cloudflare-r2-seaweedfs-db-barman`
through the `seaweedfs-db-barman-credentials` ExternalSecret.

> **Status:** the drills below have not been run yet. Parts A and B follow the
> patterns that were verified for `openbao-db`
> ([openbao-restore.md](openbao-restore.md)) and `step-ca-db`
> ([step-ca-db-restore.md](step-ca-db-restore.md)). Part C (volume snapshots of
> the audit data) rests on a mechanism proven only on a scratch volume. The "Not
> yet verified" section lists what to confirm the first time. Run the drills
> before you need a real restore.

## Read this first: metadata and data must agree

A database restore returns the metadata to a point in time; the volume servers
keep everything written since. After a restore:

- Objects written **after** the restore point have data on the volume servers
  but no metadata: they are unreachable (orphaned data, harmless but wasted).
- Objects deleted **after** the restore point have metadata again, but their
  data may already be gone (deletes free space, vacuuming compacts it). Reads
  of those objects fail.
- Retention and legal-hold state is whatever it was at the restore point. A
  COMPLIANCE lock set after that point is not in the restored metadata.

So restore to the **latest** point WAL archiving allows (the default) unless you
are deliberately rolling back, and treat anything written or deleted in the gap
as needing reconciliation by whoever owns that data.

Do not use this runbook for an ordinary failure. CNPG fails over to a replica on
its own, and one lost instance re-joins by itself:

```sh
kubectl -n seaweedfs get cluster seaweedfs-db
kubectl -n seaweedfs get cluster seaweedfs-db -o jsonpath='{.status.conditions}' | jq
# Healthy: instances 3/3, ContinuousArchiving True, LastBackupSucceeded True.
```

A restore is for when the data is actually gone (all instances and PVCs lost,
or the data is corrupted).

## Part A: restore drill (scratch cluster, safe)

Everything here is scratch: never commit it, and delete it at the end. The
scratch cluster is named `seaweedfs-db-restore-drill` in the same namespace so
it can reuse `seaweedfs-db-barman-credentials`. It deliberately has **no**
`spec.plugins` block, so it never archives WAL and cannot write into the
production archive.

1. **Confirm the backup is healthy and recent:**

   ```sh
   kubectl -n seaweedfs get backup --sort-by=.metadata.creationTimestamp
   # newest should be PHASE=completed; the schedule is daily at 03:45 UTC
   ```

2. **Create the scratch cluster** (same `imageName` digest as production, since
   a recovery needs a compatible PostgreSQL). `serverName` is set explicitly to
   the name the archive was written under. That is the cluster name: the R2
   bucket holds a single prefix, `seaweedfs-db/`, with `base/` and `wals/`
   (checked 2026-10-31 with `aws s3 ls` against the bucket):

   ```yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: seaweedfs-db-restore-drill
     namespace: seaweedfs
   spec:
     instances: 1
     imageName: ghcr.io/cloudnative-pg/postgresql:18.3@sha256:5e30290fba3d990b08a9caea6ddb49c661ad8246cbb2688adad7e6cc78df6c3f
     storage: { size: 10Gi, storageClass: csi-cinder-sc-delete }
     bootstrap:
       recovery:
         source: seaweedfs-db-source
     externalClusters:
       - name: seaweedfs-db-source
         plugin:
           name: barman-cloud.cloudnative-pg.io
           parameters:
             barmanObjectName: seaweedfs-db-barman
             serverName: seaweedfs-db
   ```

   The scratch storage uses the `delete` class on purpose, so tearing it down
   frees the volume.

3. **NetworkPolicy for the scratch cluster.** Production's policy selects
   `cnpg.io/cluster: seaweedfs-db` only, so a differently named cluster gets no
   traffic. It needs ingress 8000 from the CNPG operator (without it the cluster
   reports a misleading `Instance Status Extraction Error`) and egress to the
   apiserver (6443, post-DNAT target port on Talos, see
   [[calico-networkpolicy-dnat]]), DNS, and R2 over HTTPS:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: seaweedfs-db-restore-drill
     namespace: seaweedfs
   spec:
     podSelector:
       matchLabels: { cnpg.io/cluster: seaweedfs-db-restore-drill }
     policyTypes: [Ingress, Egress]
     ingress:
       - from:
           - namespaceSelector:
               matchLabels: { kubernetes.io/metadata.name: cnpg-system }
             podSelector:
               matchLabels: { app.kubernetes.io/name: cloudnative-pg }
         ports: [{ protocol: TCP, port: 8000 }]
     egress:
       - ports: [{ protocol: TCP, port: 6443 }, { protocol: TCP, port: 443 }]
       - ports: [{ protocol: TCP, port: 53 }, { protocol: UDP, port: 53 }]
   ```

4. **Watch it recover:**

   ```sh
   kubectl -n seaweedfs get cluster seaweedfs-db-restore-drill -w
   # wait for: Cluster in healthy state, 1/1
   ```

5. **Sanity-check the data** against production. The tables are `filemeta`, one
   per bucket, and `.system`; counts in the scratch copy should be at or below
   production's by roughly the activity since the last archived WAL:

   ```sh
   for c in seaweedfs-db-restore-drill-1 seaweedfs-db-1; do
     echo "== $c"
     kubectl -n seaweedfs exec $c -c postgres -- psql -U postgres -d seaweedfs -At \
       -c "select 'filemeta', count(*) from filemeta union all select 'locked', count(*) from \"locked\" union all select 'versioned', count(*) from \"versioned\""
   done
   ```

6. **Tear it all down**, then confirm nothing was written to production's archive:

   ```sh
   kubectl -n seaweedfs delete cluster seaweedfs-db-restore-drill
   kubectl -n seaweedfs delete pvc -l cnpg.io/cluster=seaweedfs-db-restore-drill
   kubectl -n seaweedfs delete networkpolicy seaweedfs-db-restore-drill
   kubectl -n seaweedfs get cluster,pvc,pods | grep restore-drill   # expect nothing
   ```

## Part B: real restore (data lost)

Not drilled; do Part A first. Run it imperatively (`kubectl apply`), not through
a PR: during an incident you want the database back before a CI cycle.

1. **Stop the filers** so nothing writes to a half-restored database, and
   **pause Flux** so it does not scale them back or fight the recovery
   bootstrap. Remember to resume it in step 7:

   ```sh
   flux suspend kustomization flux-platform
   kubectl -n seaweedfs scale statefulset seaweedfs-filer --replicas=0
   ```

2. **Confirm the backup source** as in Part A step 1.

3. **Delete the broken cluster.** The PVCs use `csi-cinder-sc-retain`, so the
   PersistentVolumes (and their Cinder volumes) survive as `Released`. Decide
   deliberately whether they hold data worth keeping before removing them:

   ```sh
   kubectl -n seaweedfs delete cluster seaweedfs-db
   kubectl -n seaweedfs delete pvc -l cnpg.io/cluster=seaweedfs-db
   kubectl get pv | grep seaweedfs-db      # Released PVs: inspect, then delete the PV and its Cinder volume
   ```

4. **Recreate the cluster as a recovery cluster** under the same name, with the
   production settings (3 instances, `csi-cinder-sc-retain`, the pinned image,
   `bootstrap.recovery` and `externalClusters` as in Part A step 2, and
   `bootstrap.initdb` omitted). Copy the rest from
   `applications/seaweedfs-db/base/resources/seaweedfs-db.cluster.yaml`.

5. **Watch it come up** and check the data as in Part A steps 4 and 5.

6. **Re-enable archiving.** Production's `spec.plugins` block
   (`isWALArchiver: true`, `barmanObjectName: seaweedfs-db-barman`) must be
   active again for backups to resume. See "Not yet verified" about archiving
   into a path that already holds an archive.

7. **Resume and bring SeaweedFS back:**

   ```sh
   flux resume kustomization flux-platform
   kubectl -n seaweedfs scale statefulset seaweedfs-filer --replicas=2
   kubectl -n seaweedfs get pods -w
   ```

8. **Verify the application**, not just the database: list the buckets, read an
   object from each, and read `get-object-lock-configuration` on `locked`. Then
   take an immediate backup:

   ```sh
   kubectl -n seaweedfs apply -f - <<'EOF'
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata: { name: seaweedfs-db-post-restore, namespace: seaweedfs }
   spec: { cluster: { name: seaweedfs-db }, method: plugin, pluginConfiguration: { name: barman-cloud.cloudnative-pg.io } }
   EOF
   ```

## Part C: volume data - snapshots of the audit data

Parts A and B restore the **metadata**. The objects themselves (including every
Object Lock'd version) live on the three volume servers' PVCs, and the masters'
PVCs hold the cluster identity and volume layout. The cluster has the CSI
external snapshotter (snapshot CRDs, `snapshot-controller`, and a `csi-snapshotter`
sidecar in the Cinder controller), so those six PVCs can be snapshotted.

**What was verified (2026-10-31, on a scratch 1Gi volume, not on SeaweedFS):**

- The default classes `csi-cinder-snapclass-delete` and `-retain` have no
  parameters, and Cinder refuses to snapshot an attached volume with them:
  `Volume ... status must be available, but current status is: in-use`. Every
  volume a running pod mounts is in use, so those classes cannot snapshot
  SeaweedFS at all.
- A class with `force-create: "true"` snapshots an attached volume. A new
  volume restored from that snapshot returned the file written before it.
- `type: backup` (a Cinder backup instead of a snapshot) went to `error` on this
  OpenStack; the cause was not investigated. Do not rely on it.

Prerequisite: the classes `csi-cinder-snapclass-retain-inuse` (audit snapshots;
the snapshot survives deleting the `VolumeSnapshot`) and
`csi-cinder-snapclass-delete-inuse` (drills) come from `pcd-ce-deploy`
(`variables.tf`, `cinder_volume_snapshot_classes`) and exist only after that is
applied. Check first:

```sh
kubectl get volumesnapshotclass csi-cinder-snapclass-retain-inuse csi-cinder-snapclass-delete-inuse \
  -o custom-columns=NAME:.metadata.name,POLICY:.deletionPolicy,PARAMS:.parameters
```

### Take a coordinated snapshot set

Order matters: **metadata first, then data.** The filer writes metadata only
after the volume server has stored the data, so a database backup taken at T1
references only data written before T1, and volume snapshots taken after T1
contain all of it. Taking the data first would let metadata reference data the
snapshots lack.

```sh
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

# 1. metadata: an immediate base backup, and wait for it
kubectl -n seaweedfs apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: seaweedfs-db-set-$STAMP, namespace: seaweedfs }
spec: { cluster: { name: seaweedfs-db }, method: plugin, pluginConfiguration: { name: barman-cloud.cloudnative-pg.io } }
EOF
kubectl -n seaweedfs wait --for=jsonpath='{.status.phase}'=completed backup/seaweedfs-db-set-$STAMP --timeout=15m

# 2. data: the three volume servers and the three masters
for pvc in data-seaweedfs-volume-0 data-seaweedfs-volume-1 data-seaweedfs-volume-2 \
           data-seaweedfs-seaweedfs-master-0 data-seaweedfs-seaweedfs-master-1 data-seaweedfs-seaweedfs-master-2; do
kubectl -n seaweedfs apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: audit-$STAMP-${pvc#data-}
  namespace: seaweedfs
  labels: { rye.ninja/snapshot-set: "$STAMP", rye.ninja/purpose: seaweedfs-audit }
spec:
  volumeSnapshotClassName: csi-cinder-snapclass-retain-inuse
  source: { persistentVolumeClaimName: $pvc }
EOF
done
kubectl -n seaweedfs wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot -l rye.ninja/snapshot-set=$STAMP --timeout=15m
```

What a set does and does not guarantee:

- The snapshots are **crash-consistent per volume**, not quiesced, and not taken
  at one instant across the three servers. With replication `001` the two
  copies of a volume can differ slightly; see the replica step below.
- For the **`locked` bucket** no reference can dangle: retention forbids
  deleting a locked version (a GOVERNANCE bypass is the exception), so data that
  the metadata points at is still in the later snapshot. For buckets without
  Object Lock, a delete between the backup and the snapshots can leave an entry
  whose data is gone.
- Cinder snapshots live on the **same storage backend as the volumes**. They
  protect against deletion and corruption, not against losing the backend. They
  are not an off-site copy.

### Drill: restore one volume server's snapshot and compare

This proves a snapshot of a SeaweedFS volume restores to readable volume files.
It does not start SeaweedFS on them (see "Not yet verified").

```sh
SET=<the STAMP above>
kubectl -n seaweedfs apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: drill-volume-0, namespace: seaweedfs }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: csi-cinder-sc-delete
  resources: { requests: { storage: 100Gi } }
  dataSource: { name: audit-$SET-seaweedfs-volume-0, kind: VolumeSnapshot, apiGroup: snapshot.storage.k8s.io }
---
apiVersion: v1
kind: Pod
metadata: { name: drill-volume-0, namespace: seaweedfs }
spec:
  securityContext: { runAsNonRoot: true, runAsUser: 10001, fsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: r
      image: busybox:1.37
      command: [sleep, "3600"]
      volumeMounts: [{ name: d, mountPath: /data, readOnly: true }]
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
  volumes: [{ name: d, persistentVolumeClaim: { claimName: drill-volume-0 } }]
EOF
kubectl -n seaweedfs wait --for=condition=Ready pod/drill-volume-0 --timeout=10m
diff <(kubectl -n seaweedfs exec drill-volume-0 -- sh -c 'ls -l /data | awk "{print \$5, \$9}"') \
     <(kubectl -n seaweedfs exec seaweedfs-volume-0 -- sh -c 'ls -l /data | awk "{print \$5, \$9}"')
```

The same `.dat`/`.idx` files should be present. Sizes in the restored copy are
equal to or smaller than live (later writes are not in it); a file that is
**missing** or **larger** than live is a problem. This PVC is 100Gi: the drill
needs that much Cinder capacity, and the quota was not checked.

Tear the drill down (the `delete` storage class frees the volume):

```sh
kubectl -n seaweedfs delete pod drill-volume-0
kubectl -n seaweedfs delete pvc drill-volume-0
```

### Retiring a snapshot set

The `retain` class keeps the Cinder snapshot after the `VolumeSnapshot` is
deleted, so a set must be retired deliberately and its capacity is not freed
by Kubernetes. Record each snapshot's Cinder id **before** deleting anything:

```sh
kubectl get volumesnapshotcontent -o json | jq -r --arg s "audit-$SET" \
  '.items[] | select(.spec.volumeSnapshotRef.name | startswith($s)) | "\(.metadata.name) \(.status.snapshotHandle)"'
kubectl -n seaweedfs delete volumesnapshot -l rye.ninja/snapshot-set=$SET
kubectl delete volumesnapshotcontent <names from above>
# then delete those Cinder snapshot ids in OpenStack (needs OpenStack credentials)
```

### Real restore of volume data (not drilled)

Standard Kubernetes snapshot restore; run it only after the Part A drill and the
drill above. Take the filers down first, then the volume servers:

1. `flux suspend kustomization flux-platform`, then scale the filer and volume
   StatefulSets to 0.
2. Delete the damaged `data-seaweedfs-volume-N` PVCs (their PVs stay `Released`
   under the retain class; decide deliberately what to do with them).
3. Create PVCs with the **same names** from the snapshots (`dataSource` as in
   the drill, `storageClassName: csi-cinder-sc-retain`, 100Gi). The StatefulSet
   adopts a PVC that already exists under its claim name.
4. Scale the volume servers back up, wait for them to register with the masters,
   then the filers. `flux resume kustomization flux-platform`.
5. Restore the masters' PVCs the same way only if they are lost, and then **all
   three from the same set**; do not mix a restored master with live ones.
6. Reconcile replica differences with `weed shell` (`volume.check.disk`,
   `volume.fix.replication`) and verify reads, including the retention state of
   objects in `locked`.

## Not yet verified (confirm in the first drill)

- **Archiving after a same-name restore.** The recovered cluster would archive
  to the same server path that already holds the old timeline. If CNPG refuses
  with an "expected empty archive" style error, give the recovered cluster a
  fresh path with the plugin's `serverName` parameter in `spec.plugins` (for
  example `seaweedfs-db-2`). The plugin documents the parameter but not this
  case.
- **Flux versus a recovery cluster.** Flux applies the cluster with
  `bootstrap.initdb`; a cluster recreated with `bootstrap.recovery` may conflict
  with it when Flux resumes. `openbao-restore.md` does not address this either.
  Check what Flux reports after `flux resume` and fix the source manifest if it
  objects.
- **Part C on SeaweedFS itself.** The snapshot and restore mechanism was proven
  on a scratch volume only. Not yet confirmed: that the two `*-inuse` classes
  exist and work once `pcd-ce-deploy` is applied; that a set can be taken on the
  live volume servers without side effects; Cinder snapshot and volume quotas;
  that SeaweedFS starts cleanly on restored volume files (a scratch stack over
  restored PVCs and a restored database, reading an object and its retention from
  `locked`, is the real proof); and the master and replica-reconcile steps.
- **Off-site copy.** Everything in Part C stays on the Cinder backend, so
  object data still has no off-cluster copy. Cinder backups (`type: backup`)
  errored here, and SeaweedFS's own replication to object storage was not
  evaluated.
