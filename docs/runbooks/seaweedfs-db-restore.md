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

> **Status:** the drill below has not been run yet. The commands follow the
> patterns that were verified for `openbao-db`
> ([openbao-restore.md](openbao-restore.md)) and `step-ca-db`
> ([step-ca-db-restore.md](step-ca-db-restore.md)); the "Not yet verified"
> section lists what to confirm the first time. Run the drill before you need
> the real restore.

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
- **Volume data.** Nothing here restores the volume servers' data. See
  [ADR-29](../adr/0029-seaweedfs-object-store-on-core-infra.md).
