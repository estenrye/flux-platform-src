---
name: m3-step-tracker
description: Live tracker of M3's 11 execution steps — steps 1-4 done and restore-drill verified; barman in-tree API deprecation open as a non-urgent follow-up
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

### Barman in-tree API deprecation (open, not urgent)

Production's CNPG `Cluster` backup config uses the in-tree
`barmanObjectStore` API, which CNPG deprecates and removes in 1.31.0.
Cluster is on 1.30.0 — about one minor version of runway. Researched the
migration to the Barman Cloud Plugin (`plugin-barman-cloud`,
`ObjectStore` CRD, `spec.plugins[].name: barman-cloud.cloudnative-pg.io`)
and found a real open question worth resolving carefully before touching
production: the official v0.13.0 release `manifest.yaml`
(`ghcr.io/cloudnative-pg/plugin-barman-cloud`) ships a Deployment whose
`SIDECAR_IMAGE` env var reads from a Secret (`plugin-barman-cloud-<hash>`)
that has **no `data` field in the downloaded artifact** — either a
packaging quirk in how that release asset was fetched/generated, or a
genuine gap that would leave the plugin unable to inject its sidecar into
CNPG pods. The `main` branch's raw `config/manager/manager.yaml` doesn't
reference `SIDECAR_IMAGE` at all, suggesting release-time templating I
haven't fully traced.

This also lands in the *shared* `cnpg-system` namespace — blast radius is
every CNPG cluster on `controlplane`, not just step-ca-db, and the
Cluster-side cutover triggers a rolling restart. Given it's not urgent,
treat as its own properly-scoped follow-up: confirm the SIDECAR_IMAGE
mechanism (check a fresh non-cached download, or ask upstream) before
vendoring the plugin, deploy the plugin as a standalone addition first
and confirm it's healthy, *then* do the Cluster/ScheduledBackup/
externalClusters cutover as a separate, reviewable change.

See [[m3-render-lint-ci-fix]] for a separate, now-resolved finding from
this same session: `render-and-lint` CI had been failing on every commit
since step 1 kickoff, masking these issues from automated review.
