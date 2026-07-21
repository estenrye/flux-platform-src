# Runbook: step-ca-db restore drill (`controlplane`)

Interim backup story until barman-to-Garage lands in M3 (R3): nightly
`pg_dump --format=custom` via CronJob `step-ca-db-dump` (`step-ca`
namespace, 02:10 UTC, 14-day retention) to the `step-ca-db-dumps`
truenas-nfs PVC, riding the NAS's own ZFS snapshot schedule off-host.
This drill — restore onto a scratch cluster, confirm step-ca starts
against it — is M2 execution step 11 and should be re-run periodically
(plan M11 quarterly drills) as the interim story evolves.

RPO characteristic worth knowing: a restore reflects only what existed
at the last dump. Anything issued/consumed between the dump and the
incident (up to ~24h on the nightly schedule) is gone. This showed up in
the 2026-07-21 drill as a real row-count gap on `x509_certs` /
`x509_certs_data` / `used_ott` between production and the restored
snapshot — expected, not a restore defect.

## Procedure

All resources below are scratch/imperative — never commit them to git,
and delete everything at the end. Namespace: `step-ca` (same as
production, so the drill can reuse the `step-ca-db-dumps` PVC and the
`csi-driver-spiffe-ca` secret read-only without cross-namespace volume
gymnastics). Suffix everything `-restore-drill` for easy identification
and teardown (`kubectl -n step-ca delete <kind> -l
rye.ninja/purpose=m2-step11-restore-drill` catches everything except the
Pod, which needs its own delete since it predates giving the label to
every resource type — apply the label to the Pod too if scripting this).

1. **Scratch CNPG cluster** — same `imageName` digest as production
   (pg_restore refuses newer servers) and the same `truenas-nfs-pg`
   storage class (NFS ownership workaround,
   [[truenas-nfs-ownership-workaround]]):

   ```yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: step-ca-db-restore-drill
     namespace: step-ca
   spec:
     instances: 1
     imageName: ghcr.io/cloudnative-pg/postgresql:18.3@sha256:5e30290fba3d990b08a9caea6ddb49c661ad8246cbb2688adad7e6cc78df6c3f
     bootstrap:
       initdb: { database: stepcas, owner: stepcas }
     storage: { size: 2Gi, storageClass: truenas-nfs-pg }
   ```

2. **NetworkPolicies — the part that bites.** The namespace default-deny
   posture means a brand-new `cnpg.io/cluster` label gets *zero* traffic
   by default. Production's policies are scoped by exact cluster name
   (`step-ca-db`), so they don't cover a differently-named scratch
   cluster. Two policies are needed, both directions:
   - **Egress** for the scratch cluster's own pods: apiserver 6443 (CNPG
     instance manager needs it — post-DNAT targetPort, Talos serves 6443,
     see [[calico-networkpolicy-dnat]]) + DNS.
   - **Ingress** for the scratch cluster's pods: 5432 from the drill
     workload pods, and 8000 from `cnpg-system`'s operator pods (its
     health/status polling). Missing this ingress rule is exactly what
     produces `Instance Status Extraction Error: HTTP communication
     issue` on the `Cluster` status even though `READY` shows 1/1 and
     direct `psql` connections work fine — don't trust the stale-looking
     status message over a direct connectivity test.
   - A third, matching **egress** rule on the drill workload pods (the
     restore Job and the step-ca Pod) to reach the scratch cluster's
     pods on 5432, plus DNS.

3. **Restore** — a one-shot Job, `securityContext` matching the
   production dump CronJob (`runAsUser/Group: 26`, matches the
   `postgresql` image's `postgres` OS user), mounting `step-ca-db-dumps`
   read-only and restoring the newest dump by mtime:

   ```sh
   LATEST=$(ls -t /backups/stepcas-*.dump | head -1)
   pg_restore --no-owner --role="${PGUSER}" --dbname="${PGDATABASE}" --verbose "${LATEST}"
   ```

   Connect via `PGHOST=step-ca-db-restore-drill-rw.step-ca.svc.cluster.local`,
   credentials from the CNPG-generated `step-ca-db-restore-drill-app`
   Secret (`username`/`password` keys — CNPG creates this automatically
   for every Cluster, named `<cluster>-app`).

4. **Verify step-ca starts against it** — the actual step 11 pass
   criterion. Reuse production's `step-certificates-certs` ConfigMap and
   `step-certificates-secrets` Secret as-is (both empty/vestigial — the
   real cert material comes from `csi-driver-spiffe-ca`, mounted
   read-only, unmodified). Build one new ConfigMap: production's
   `step-certificates-config` `ca.json`/`defaults.json` with only
   `db.dataSource`'s host swapped to the scratch service. Run a plain
   Pod (not the full Helm-templated Deployment — the chart's init
   container pattern for patching `ROOTS_PLACEHOLDER` is short enough to
   inline) with the same image
   (`cr.smallstep.com/smallstep/step-ca:0.30.2@sha256:...`) and
   `PGPASSWORD` sourced from the scratch cluster's `-app` Secret.
   Confirm:

   ```sh
   kubectl -n step-ca exec <drill-pod> -- curl -sk https://127.0.0.1:9000/health
   # {"status":"ok"}
   ```

   step-ca performs its DB connectivity check during startup — if the
   restored schema were broken, this fails loudly before `Serving HTTPS`
   ever logs, so a 200 here is real proof, not a formality.

5. **Teardown** — delete the Pod, the restore Job, the ConfigMap, all
   three NetworkPolicies, and the scratch `Cluster` (which takes its PVC
   with it). Confirm `kubectl -n step-ca get all,pvc -l
   rye.ninja/purpose=m2-step11-restore-drill` is empty and that
   production's `step-ca-db` Cluster and `step-certificates` Deployment
   are untouched throughout — none of the above ever references or
   mutates a production-named resource.

## Drill log

| Date | Dump restored | Result |
|---|---|---|
| 2026-07-21 | `stepcas-20260721T021007Z.dump` (24410 bytes) | Pass — schema + all 24 tables restored, step-ca `/health` 200, root fingerprint `6cdc50de...` matched. Row-count gap on 3 tables vs. production, explained by ~3h of post-dump cert issuance (expected RPO, not a defect). |
