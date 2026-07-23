---
name: m3-step-tracker
description: Live tracker of M3's 11 execution steps — current status, what's actually verified vs. assumed
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

### Step 4 detail (2026-07-23)

- WAL archiving wired and base backups now actually run: PR #98 wired
  `barmanObjectStore` but never added a `Backup`/`ScheduledBackup`, so no
  base backup had ever executed. Fixed in #99 (`ScheduledBackup`,
  daily 03:00 UTC + `immediate: true`). Confirmed live: `Backup
  step-ca-db-backup-20260723063144` completed, `firstRecoverabilityPoint`
  set, 4.3MB `data.tar.gz` + `backup.info` in the `step-ca-db-barman`
  Garage bucket.
- **Restore drill NOT yet passing.** `pg_stat_archiver` on production
  reports 11 successful WAL archives (last: `...048` at 04:24 UTC), but
  the Garage bucket has **zero WAL objects** — only the base backup.
  A scratch-cluster restore attempt fails with `WAL not found` for the
  segment the backup needs to reach consistency. Root cause (probable,
  not confirmed): Garage's buckets all show creation date 2026-07-23
  (today), consistent with Garage's PV data having been wiped by one of
  the several redeploys during step 3's iteration (health-probe fixes,
  v2 API fixes, etc. — PRs #85–#97). WAL archived before that reset is
  gone; the base backup (taken after, at 06:31) is on stable storage and
  persisted fine — but it's currently **not restorable** because its
  required starting WAL isn't durably stored anywhere.
  - step-ca-db is low-write (CA issuance is infrequent), so a WAL
    segment may not roll for a long time under normal operation.
  - **Next action to actually close step 4**: force a fresh WAL segment
    (a throwaway write + `pg_switch_wal()`, or wait for real cert
    issuance), confirm it lands and persists in Garage, take a new base
    backup against that state, then retry the restore drill (procedure:
    externalCluster recovery, NOT the old pg_dump-based
    [[m2-step11-restore-drill]] runbook — need `serverName: step-ca-db`
    explicitly set on the externalCluster's `barmanObjectStore`, since it
    otherwise defaults to the externalCluster's own reference name and
    silently looks in the wrong S3 prefix).
- **Also discovered**: production's CNPG `Cluster` backup config uses the
  in-tree `barmanObjectStore` API, which CNPG deprecates and removes in
  1.31.0. Cluster is on 1.30.0 now — about one minor version of runway
  before this needs migrating to the Barman Cloud Plugin. Not urgent, not
  blocking M3, but should be a tracked fast-follow (new plugin deployment
  + `ObjectStore` CRD + `plugin:` config on the Cluster, replacing
  `barmanObjectStore:` directly).

See [[m3-render-lint-ci-fix]] for a separate, now-resolved finding from
this same session: `render-and-lint` CI had been failing on every commit
since step 1 kickoff, masking these issues from automated review.
