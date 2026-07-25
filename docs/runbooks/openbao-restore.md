# Runbook: OpenBao restore (`controlplane`)

OpenBao's real backup data is **not** a Raft snapshot — see
[ADR-25](../adr/0025-openbao-platform-secret-store.md): the storage
backend is PostgreSQL (`openbao-db`, a CNPG cluster), and it's backed up
the same way every other CNPG-backed app on this cluster is: continuous
WAL archiving + nightly base backups via the `barman-cloud.cloudnative-pg.io`
plugin to Garage's `openbao-db-barman` bucket (30-day retention), mirrored
off-site to Cloudflare R2 by `applications/openbao-snapshots-sync/base`.

**Restoring `openbao-db`'s data does not unseal OpenBao.** This is a
two-phase recovery: phase 1 restores the Postgres data OpenBao's storage
backend reads from; phase 2 is the ordinary unseal ceremony
([docs/runbooks/openbao-unseal.md](openbao-unseal.md)) against that
restored data. A restore with no unseal afterward just leaves OpenBao
sealed and pointed at good data.

Before starting, check the live cluster isn't already self-healing a
transient failure — a restore is for when `openbao-db`'s data is actually
gone (all replicas + PVCs lost), not for an ordinary CNPG primary
failover (which CNPG handles on its own):

```sh
kubectl -n openbao get cluster openbao-db
kubectl -n openbao get cluster openbao-db -o jsonpath='{.status.conditions}' | jq
# Look for ContinuousArchiving: True and LastBackupSucceeded: True on a
# healthy cluster -- if these are already true and instances are Ready,
# you don't need this runbook.
```

## Phase 1 — restore `openbao-db`

1. **Confirm the backup source is healthy** before trusting it:

   ```sh
   kubectl -n openbao get backup --sort-by=.metadata.creationTimestamp
   # newest entry should be PHASE=completed, recent (nightly schedule:
   # 03:30 UTC, applications/openbao-db/controlplane/resources/scheduled-backup.yaml)
   ```

2. **Delete the broken cluster** (skip if it's already gone — e.g. all
   3 PVCs were lost to a storage failure and the `Cluster` object itself
   is stuck `NotReady`):

   ```sh
   kubectl -n openbao delete cluster openbao-db
   kubectl -n openbao delete pvc -l cnpg.io/cluster=openbao-db
   ```

3. **Recreate as a recovery cluster**, pointing at the same barman
   `ObjectStore` as an `externalCluster` source. This is the verified
   CNPG-I plugin recovery shape (confirmed live against this cluster's
   installed CRDs — `kubectl explain cluster.spec.externalClusters.plugin`
   / `cluster.spec.bootstrap.recovery`):

   ```yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: openbao-db
     namespace: openbao
   spec:
     instances: 3
     imageName: ghcr.io/cloudnative-pg/postgresql:18.3@sha256:5e30290fba3d990b08a9caea6ddb49c661ad8246cbb2688adad7e6cc78df6c3f
     storage:
       size: 10Gi
       storageClass: democratic-csi-nfs-pg
     postgresql:
       parameters:
         max_connections: "100"
     primaryUpdateStrategy: unsupervised
     monitoring:
       enablePodMonitor: true
     bootstrap:
       recovery:
         source: openbao-db-source
     externalClusters:
       - name: openbao-db-source
         plugin:
           name: barman-cloud.cloudnative-pg.io
           parameters:
             barmanObjectName: openbao-db-barman
   ```

   Apply this **imperatively** (`kubectl apply -f`), not via a PR —
   during an actual incident you want the cluster back before a CI cycle,
   and the standing `Cluster`/`ScheduledBackup`/`ObjectStore` manifests
   already in `applications/openbao-db/` are unchanged (they still
   describe the steady-state cluster once it comes back up; this is a
   one-time recovery bootstrap, same class of operation as
   [step-ca-db-restore.md](step-ca-db-restore.md)'s scratch-cluster
   pattern, except this one becomes the real `openbao-db` again).
   `plugins: [...isWALArchiver: true...]` isn't set here — it gets
   re-applied by Flux on the next reconcile once the cluster is healthy
   and the source repo's own patch (which adds it) is back in effect; if
   you want WAL archiving active immediately rather than waiting for the
   next reconcile, add the same `spec.plugins` block from
   `applications/openbao-db/controlplane/kustomization.yaml`'s patch.

4. **Watch it come up**:

   ```sh
   kubectl -n openbao get cluster openbao-db -w
   # wait for instances: 3/3, phase: Cluster in healthy state
   ```

5. **Sanity-check the restored data** before moving to phase 2 — OpenBao's
   own tables should exist and be non-empty:

   ```sh
   kubectl -n openbao exec openbao-db-1 -c postgres -- psql -d openbao \
     -c "SELECT count(*) FROM openbao_kv_store;"
   # (peer auth via the postgres OS user -- "psql -U openbao" fails with
   # "Peer authentication failed"; confirmed live)
   ```

## Phase 2 — unseal

Once `openbao-db` reports healthy, the OpenBao pods themselves (already
running, or restart them with `kubectl -n openbao delete pod -l
app.kubernetes.io/name=openbao` if they were crash-looping against the
broken database) will report `sealed=true` against the restored data.
Follow [docs/runbooks/openbao-unseal.md](openbao-unseal.md) in full —
same SOPS-encrypted key shares, same 3-of-5 threshold, run against each
of the 3 pods.

Verify:

```sh
kubectl -n openbao exec openbao-0 -c openbao -- \
  sh -c 'BAO_ADDR=https://openbao.openbao.svc:8200 BAO_CACERT=/openbao/tls/ca.crt bao status'
# sealed: false, ha_enabled: true
```

If a secret written before the incident is missing after restore, that's
expected RPO loss — anything written between the last successful barman
base backup / WAL segment and the incident is gone, same characteristic
noted in [step-ca-db-restore.md](step-ca-db-restore.md) for that CNPG
cluster's dump-based restore. Continuous WAL archiving keeps this window
small (seconds to low minutes under normal archiving cadence), not the
~24h gap a nightly-dump-only backup would have.

## Restore drill (non-destructive — prove backups are actually usable)

Don't run phase 1's `delete cluster` against production to test this.
Instead, repeat step 3 above with a **different cluster name**
(`openbao-db-restore-drill`) and its own `externalClusters` entry
pointing at the *same* `openbao-db-barman` `ObjectStore` (read-only —
nothing about a recovery bootstrap writes to the source). This needs the
same NetworkPolicy gotcha called out in
[step-ca-db-restore.md](step-ca-db-restore.md): the scratch cluster's
`cnpg.io/cluster` label won't match `openbao-db`'s namespace-default-deny
NetworkPolicies, so it needs its own copies of
`applications/openbao-db/base/resources/network-policy.yaml` and
`applications/openbao-db/controlplane/resources/barman-network-policy.yaml`
+`apiserver-egress-network-policy.yaml`, each renamed and re-scoped to
`cnpg.io/cluster: openbao-db-restore-drill`.

Verify with the same `psql` row-count check as step 5, then delete the
scratch `Cluster` (which takes its PVCs with it) and the three scratch
NetworkPolicies. A full drill additionally stands up a scratch OpenBao
`Helm` release pointed at the scratch database (`server.ha.config`'s
`storage "postgresql"` block, same shape as
`applications/openbao/base/values.yaml`, connection string swapped to the
scratch cluster's `-app` Secret) and runs the unseal ceremony against it
end-to-end — heavier to set up, but the only way to prove the *whole*
chain (not just the Postgres data) restores cleanly. The design's step 7
exit criterion (M3) called for exactly this once, at milestone close.
