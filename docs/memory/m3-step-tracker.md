---
name: m3-step-tracker
description: Live tracker of M3's 11 execution steps — steps 1-4 done, restore-drill verified, and barman in-tree API migrated to the CNPG-I plugin
metadata:
  type: project
---

Tracks [[m3-design]]'s 11-step execution order. Update as steps complete —
this decays fast, keep it current rather than trusting it blindly.

## Status as of 2026-07-23

| # | Step | Status |
|---|---|---|
| 1 | democratic-csi shadow deploy + smoke test | Done (merged #78–#83) |
| 2 | Flip default SC, migrate step-ca-db, retire nfs-pg-owner CronJob | Done (#84) |
| 3 | Garage 3-node + buckets | Done (#85–#97); Garage was redeployed/reset several times during this step's iteration — see WAL gap note below |
| 4 | step-ca-db barman → Garage, retire pg_dump CronJob | Partially done — see detail below |
| 5–11 | OpenBao, ESO migration, snapshots, Keycloak, Pinniped, ADRs | Not started |

### Step 4 detail (2026-07-23) — RESOLVED

- WAL archiving wired and base backups now actually run: PR #98 wired
  `barmanObjectStore` but never added a `Backup`/`ScheduledBackup`, so no
  base backup had ever executed. Fixed in #99 (`ScheduledBackup`,
  daily 03:00 UTC + `immediate: true`).
- **Restore drill now passes.** Root-caused two stacked issues:
  1. Garage's buckets all showed creation date 2026-07-23 (today),
     consistent with Garage's PV data having been wiped by one of the
     several redeploys during step 3's iteration (health-probe fixes, v2
     API fixes — PRs #85–#97). Any WAL archived before that reset was
     gone.
  2. **Real bug, fixed in #102**: `target: prefer-standby` (both the
     Cluster default and the ScheduledBackup) anchors the backup's
     `beginWal` to the *standby's own* checkpoint/restart-point — which
     on this low-traffic cluster was stuck at an old WAL segment for
     hours with no sign of advancing, even though streaming replication
     itself was healthy and caught up. Every `prefer-standby` backup
     needed that stale WAL for consistency, and it was gone. Switched
     `target: primary` on both. Verified end-to-end: forced a fresh WAL
     segment (`pg_logical_emit_message` + `pg_switch_wal`, zero schema
     impact), confirmed it persisted in Garage, took a `target: primary`
     backup (`beginWal == endWal`, both fresh), restored it onto a
     scratch CNPG cluster via the barman `externalCluster` path, and
     confirmed all 24 tables + real row data (6 certs) present. Scratch
     cluster and NetworkPolicies fully torn down afterward.
  - Restore procedure note (NOT the old pg_dump-based
    [[m2-step11-restore-drill]] runbook): externalCluster recovery needs
    `serverName: step-ca-db` explicitly set on the `barmanObjectStore`
    block — it otherwise defaults to the externalCluster's own reference
    name and silently looks in the wrong S3 prefix, failing with "no
    target backup found".
  - Live production `Cluster.spec.backup.target` and
    `ScheduledBackup.spec.target` both confirmed `primary` post-deploy.

### Barman in-tree API deprecation — RESOLVED 2026-07-23

Migrated `step-ca-db` off the in-tree `spec.backup.barmanObjectStore` API
(removed in CNPG 1.31.0; cluster was on 1.30.0) to the CNPG-I Barman
Cloud Plugin, same day as discovery, at the user's explicit direction
(not deferred). PRs #104–#106.

**Correction on the earlier "SIDECAR_IMAGE Secret has no data" finding**:
that was my own investigation error, not a real gap. The Secret's `data:`
key sorts alphabetically *before* `kind`/`metadata` in the downloaded
manifest, and an early `grep -A6` only looked *after* the `name:` line —
missing it entirely. The value was present and decodes cleanly to
`ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.13.0`. Lesson: always
re-verify a "the artifact seems broken" conclusion with a full-file
`grep`/`sed` before trusting it, especially before deferring real work on
that basis.

**What shipped**:
- New `applications/cnpg-barman-plugin` app: vendors the upstream v0.13.0
  release manifest into `cnpg-system`. Controller image + the
  `SIDECAR_IMAGE` secret value both digest-pinned. NetworkPolicies added
  (cnpg-system runs default-deny; needed both an ingress rule on the
  plugin for the operator's gRPC calls, and a supplementary egress rule
  on the *operator's* existing podSelector, since NetworkPolicies are
  additive and the operator's own policy file lives in a different app).
- `step-ca-db`: added an `ObjectStore` CR (direct translation of the old
  config), switched `Cluster.spec.plugins` (`isWALArchiver: true`) and
  `ScheduledBackup.spec.method: plugin`. No `serverName` override needed
  — defaults to the Cluster's own name, preserving the existing
  `step-ca-db/...` prefix in Garage.
- **Two follow-up fixes needed post-deploy, both because this cluster runs
  `cert-manager-approver-policy`** (blocks any cert-manager
  `CertificateRequest` with zero content-based matching unless something
  explicitly grants it):
  1. The plugin's Certificates (`barman-cloud-client`/`-server`, via its
     own bundled `selfSigned` Issuer) had no matching
     `CertificateRequestPolicy` → stuck `WaitingForApproval` forever →
     `barman-cloud` pod stuck `ContainerCreating` (`FailedMount: secret
     not found`) → `step-ca-db` Cluster reconciliation stalled
     ("cannot proceed... unknown plugin being required"). **No outage** —
     existing pods kept running fine, just blocked from progressing.
     Fixed by adding a `CertificateRequestPolicy` scoped to the plugin's
     `selfsigned-issuer` (mirrors the existing
     `csi-driver-spiffe-ca-policy` pattern).
  2. A matching policy alone wasn't enough: approver-policy *also*
     requires an explicit RBAC `use` grant (a `ClusterRole` naming the
     specific policy in `resourceNames`, bound to the `cert-manager`
     ServiceAccount) — content-matching a Ready policy is necessary but
     not sufficient. Fixed by mirroring
     `csi-driver-spiffe-ca.clusterrole(binding).yaml` exactly. **If any
     future app adds its own cert-manager Issuer under approver-policy,
     budget for both pieces up front.**
- Verified end-to-end on production: plugin pod Running/Ready, all 3
  `step-ca-db` instances rolled cleanly (2/2 containers, sidecar
  injected, zero WAL-archiving gap across the restart — confirmed
  segments 4D–52 all present in Garage with no missing numbers), step-ca
  `/health` still 200 post-rollout, and a fresh `method: plugin` Backup
  completed with `beginWal == endWal` on current WAL.

See [[m3-render-lint-ci-fix]] for a separate, now-resolved finding from
this same session: `render-and-lint` CI had been failing on every commit
since step 1 kickoff, masking these issues from automated review.
