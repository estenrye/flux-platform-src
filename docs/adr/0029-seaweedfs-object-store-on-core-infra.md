# 29. SeaweedFS Object Store on core-infra (S3 versioning and Object Lock)

Date: 2026-10-31

## Status

Accepted

## Context

core-infra needed an in-cluster S3-compatible object store with two
properties: bucket **versioning** and **Object Lock** retention (COMPLIANCE and
GOVERNANCE modes, legal holds, and a bucket default-retention rule). The filer
metadata was to live in a CloudNativePG cluster named `seaweedfs-db`, matching
how every other stateful platform service here keeps its database.

What was already available:

- **Garage** is the fleet's object store (chosen over MinIO and Ceph RGW in
  [fable-5-arch-spec.md](../superpowers/specs/fable-5-arch-spec.md)) but runs
  only on `controlplane`, with no cross-cluster exposure, for CNPG barman
  backups. Its [S3 compatibility page](https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/)
  lists PutBucketVersioning, ListObjectVersions, PutObjectLockConfiguration,
  PutObjectRetention and PutObjectLegalHold as "Missing". That page's own
  history ends in 2022, so it may lag Garage 2.x (2.3.0 is deployed here); the
  claim was not re-tested against the running Garage.
- core-infra storage is OpenStack Cinder only (`csi-cinder-sc-delete` and
  `csi-cinder-sc-retain`, both RWO). There is no Longhorn, Ceph or RWX class.
- core-infra had no CNPG `Cluster`, no barman plugin and no off-cluster backup
  target.

## Decision

Deploy SeaweedFS (chart 4.51.0, image pinned by tag and digest) into the
`seaweedfs` namespace on core-infra:

- **Topology:** 3 masters (raft, 5Gi PVC each), 3 volume servers (100Gi PVC
  each, replication `001`: every needle on two servers), 2 filers with the S3
  gateway embedded. Every PVC uses `csi-cinder-sc-retain`, because filer
  metadata and retention state are meaningless without the volume data they
  point at, and pruning the app from Git must not delete either.
- **Filer metadata:** the `postgres2` store on CNPG `seaweedfs-db` (3
  instances, 10Gi, `csi-cinder-sc-retain`). The filers exit at startup if
  Postgres is unreachable, so they restart until the database is up.
- **S3:** in-cluster only (ClusterIP `:8333`), authentication on. The admin
  identity is generated once by External Secrets (`Password` generators) into
  `seaweedfs-s3-config`, not by the chart, whose generated credentials use
  Helm `lookup` and are not stable across `helm template` renders. No Gateway,
  DNS or certificate yet.
- **Buckets:** `versioned` (versioning) and `locked` (Object Lock, which forces
  versioning) are created by the chart's hook Job. Object Lock can only be set
  when a bucket is created and cannot be undone.
- **Database backups:** `seaweedfs-db` archives WAL continuously and takes a
  daily base backup (03:45 UTC, 30-day retention) through the
  `barman-cloud.cloudnative-pg.io` plugin to a Cloudflare R2 bucket
  (`seaweedfs-db-barman`). Credentials come from 1Password through an
  ExternalSecret; they are provisioned and rotated with
  `.bin/provision-cloudflare-r2-bucket.sh` and `.bin/rotate-cloudflare-r2-token.sh`
  using `SOPS_ENCRYPT=false`, so nothing is committed.
- **Hardening:** non-root (UID 10001), read-only root filesystem, dropped
  capabilities, `RuntimeDefault` seccomp, NetworkPolicies on every pod, and
  sender-based ingress rules on the database (5432) and S3 (8333).

Garage stays where it is. This ADR does not move CNPG barman backups off it.

## Consequences

**Verified on the running cluster (2026-10-31):**

- Versioning: distinct version ids for repeated puts, old versions readable by
  id, delete markers hide a key while keeping its versions.
- Object Lock: COMPLIANCE retention cannot be deleted, bypassed or shortened
  and is deletable after it expires; GOVERNANCE is deletable only with
  `--bypass-governance-retention`; legal hold blocks deletes while on; a
  bucket default-retention rule is inherited by new objects.
- Filer metadata is in Postgres (the `filemeta` table, a table per bucket,
  and `.system`), `seaweedfs-db` runs at 3 of 3 instances, and scheduled backups to R2
  complete.

**Things to live with:**

- Replication `001` keeps two copies in one site. It is not a backup of the
  object data, and Object Lock protects against deletion, not against losing
  volumes. Object data has no off-cluster copy. CSI volume snapshots of the
  PVCs are possible (runbook Part C) but live on the same Cinder backend, and
  need a snapshot class with `force-create` because every SeaweedFS volume is
  attached.
- The metadata and the volume data must stay consistent. A database restore to
  an earlier point leaves newer objects as orphaned data and brings back
  deleted entries whose data may already be vacuumed. See the
  [restore runbook](../runbooks/seaweedfs-db-restore.md).
- COMPLIANCE retention is irreversible. A mistaken date cannot be undone.
- The fleet now has two object stores with different capabilities: Garage
  (no versioning or Object Lock, per its docs) and SeaweedFS.
- S3 is reachable only from inside the cluster, with a single generated admin
  identity. External exposure and per-consumer identities are deferred.
- The rollout exposed a latent platform fault: kube-proxy's `clusterCIDR` was
  not the Calico pod pool, so it masqueraded pod-to-Service traffic and broke
  sender-based NetworkPolicies across nodes. Fixed in `pcd-ce-deploy` (see
  [kube-proxy-clustercidr-masquerade.md](../memory/kube-proxy-clustercidr-masquerade.md)).

**Not yet done:** a `seaweedfs-db` restore drill, a filer/master failover test,
a drilled recovery path for the volume data (snapshots are documented but only
proven on a scratch volume), and any off-cluster copy of the object data.

## Alternatives considered

- **Garage:** already in the fleet, but lacks versioning and Object Lock per its
  documentation (see Context).
- **MinIO:** rejected fleet-wide earlier over its licensing and feature
  direction.
- **Ceph RGW:** rejected earlier on operational weight, and core-infra has no
  Ceph or RWX storage to build it on.
- **SeaweedFS with its local `leveldb2` filer store:** would avoid the database
  dependency, but ties metadata to a single filer's disk and does not meet the
  requirement to keep it in CNPG.
