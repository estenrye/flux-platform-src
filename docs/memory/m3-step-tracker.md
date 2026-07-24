---
name: m3-step-tracker
description: Live tracker of M3's 11 execution steps — steps 1-5 done; OpenBao runs on a CNPG/Postgres backend, not Raft, with real-Certificate TLS after a SPIFFE-CSI false start
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
| 4 | step-ca-db barman → Garage, retire pg_dump CronJob | Done — see detail below |
| 5 | OpenBao HA on CNPG/Postgres backend | Done — see detail below; unseal ceremony `[H]` and openbao-db-barman credentials still open |
| 6–11 | ESO migration, snapshots, Keycloak, Pinniped, ADRs | Not started |

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

### Step 5 detail (2026-07-23) — OpenBao on CNPG/Postgres, RESOLVED

**Design decision, at the user's explicit direction**: the original M3
design called for OpenBao HA via integrated Raft storage. The user
challenged this directly — "CNPG is already a core dependency for Step
Certificates, so why not take advantage of CNPG and our already proven
backup/restore path?" — and then explicitly scoped the work to
OpenBao's PostgreSQL storage backend instead. This is a supported
upstream path (unlike HashiCorp Vault, where Postgres storage is
community/unsupported): OpenBao deliberately invested in it, reaching
production-ready status with HA in v2.5.0 (April 2026); this deploy
runs chart `openbao-helm` 0.28.6 / app v2.6.1. HA-over-Postgres
coordinates leader election via a dedicated `openbao_ha_locks` table —
no Raft peer discovery, every pod points at the same CNPG primary via
`storage "postgresql" { ha_enabled = "true" }` in the HCL config, with
`BAO_PG_CONNECTION_URL` injected from CNPG's auto-generated
`openbao-db-app` Secret (`extraSecretEnvironmentVars`) so no credential
ever lands in a rendered manifest.

**What shipped**:
- `applications/openbao-db`: new CNPG `Cluster` (3 instances), mirrors
  `step-ca-db` exactly — same pinned image digest, same
  `barman-cloud.cloudnative-pg.io` plugin wiring (shared cluster-wide
  plugin, no redeploy needed), `ScheduledBackup` with `target: primary`
  from day one (no repeat of the step-4 `prefer-standby` bug).
- `applications/openbao`: official `openbao-helm` chart vendored via
  kustomize `helmCharts:`, `server.dataStorage.enabled: false` (no local
  PVCs, Postgres is the store), `server.ha.raft.enabled: false`.
- Live status: `openbao-db` Cluster healthy, 3/3 instances. `openbao-0`
  Running/stable (1-of-3 up under `OrderedReady` StatefulSet gating —
  this session didn't force the other two up since the unseal ceremony
  is still pending anyway). `Initialized: false, Sealed: true` as
  expected — the `[H]` unseal ceremony is intentionally out of scope for
  this step, same as originally planned.

**THE MAJOR LESSON — SPIFFE CSI certs carry no DNS SANs, only a SPIFFE
URI SAN**: the first implementation used the `spiffe.csi.cert-manager.io`
CSI ephemeral-volume driver for TLS (cleaner on paper — it has its own
dedicated auto-approver and needs zero `CertificateRequestPolicy`/RBAC).
The user preemptively flagged the risk before implementation even
started: "the spiffe csi tls cert does not allow for additional SANs. I
think TLS termination and reencryption with a public cert may be
required." That prediction was confirmed live: decoding the actual
issued cert (`openssl x509 -noout -text`) showed
`X509v3 Subject Alternative Name: critical / URI:spiffe://controlplane.rye.ninja/ns/openbao/sa/openbao`
and **nothing else** — the documented `csi.cert-manager.io/dns-names`
pod annotation is simply not honored by this driver. It's built for
SPIFFE-aware peer identity verification, not standard hostname-based TLS
(what the `bao` CLI / Go's `crypto/tls` / any normal HTTP client does).
**Fix**: switched to a real `cert-manager.io/v1 Certificate` (mirrors
the already-working `cnpg-barman-plugin` pattern: `Certificate` +
`CertificateRequestPolicy` + RBAC `use` grant), issued by the same
`csi-driver-spiffe-ca` ClusterIssuer — so still zero new CA to
distribute, since it's already trusted platform-wide via the
trust-manager Bundle. Also had to include both FQDN and short-form
hostnames (`openbao.openbao.svc.cluster.local` *and*
`openbao.openbao.svc`, etc.) — the chart's own `VAULT_ADDR`/cluster-addr
env vars use the short form, which an FQDN-only SAN list missed.
**Lesson for future TLS decisions on this platform**: default to a real
`Certificate` for anything doing standard hostname TLS verification;
reach for SPIFFE CSI only when the consumer is genuinely SPIFFE-aware.

**Recurring gotcha, hit twice more this step**: Kubernetes immutable
Pod fields (`serviceAccountName`, `volumes`) block Flux's atomic
dry-run for the *entire* cluster kustomization when an existing Pod's
spec changes underneath it — not just Jobs (see step-4/CI-fix history).
Hit on `openbao-server-test` (the chart's Helm-test-hook bare Pod) twice:
once when RBAC/serviceAccountName was added, again when the TLS volume
switched from the SPIFFE CSI volume to the Secret-backed one. Same fix
each time: `kubectl delete pod openbao-server-test`. Also hit on
`openbao-0` itself after the liveness-probe revert and again after the
TLS pivot, since `updateStrategyType: OnDelete` (deliberate, upstream's
own recommendation for this chart) never auto-recreates existing pods on
template change.

**Liveness probe crash-loop (self-inflicted, reverted)**: the initial
implementation set `server.livenessProbe.enabled: true`, reasoning the
httpGet handler works fine over TLS. It crash-looped `openbao-0`:
`/v1/sys/health` returns 501 uninitialized / 503 sealed, both read as
failure by kubelet, and sealed is a normal long-lived pre-unseal state.
Reverted to the chart's own deliberate default (`false`).

**kustomize helm kubeVersion gate**: `kustomize build --enable-helm`
defaults to a pre-1.30 `Capabilities.KubeVersion` unless told otherwise,
which broke on `openbao-helm`'s `kubeVersion: >=1.30.0-0` chart gate.
Fixed once, platform-wide, in the shared render script
(`.bin/render/render-kustomize-base-and-patches.sh`): added
`--helm-kube-version 1.36.2` (controlplane's real server version) to the
`kustomize build` invocation. Any future chart with its own
`kubeVersion` gate is already covered.

**Still open / follow-up needed**:
- `openbao-db-barman-credentials` Secret does not exist on-cluster yet
  — unlike `step-ca-db-barman-credentials`, the Garage access key was
  never created for it (`garage key create` + `garage bucket allow` +
  SOPS-encrypt into `clusters/controlplane/secrets/`). Until this is
  done, `openbao-db`'s WAL archiving/backup path is non-functional, and
  the plan's own verification criterion (a `target: primary` backup
  landing in `openbao-db-barman`) is unmet.
  - Next step: `kubectl exec -n garage garage-0 -- /garage key create
    barman-openbao-db`; `... /garage bucket allow --read --write --owner
    openbao-db-barman --key <key-id>`; SOPS-encrypt into
    `clusters/controlplane/secrets/openbao-db-barman-credentials.sops.yaml`
    (mirror `step-ca-db-barman-credentials.sops.yaml`); PR, merge,
    reconcile; then confirm a base backup lands in Garage.
- `openbao-server-test` Pod's own TLS verification against the *new*
  cert failed with `certificate signed by unknown authority` (the test
  hook only sets `VAULT_ADDR`, no `VAULT_CACERT`/`BAO_CACERT`) — not
  root-caused, deemed non-blocking since it's tooling outside the plan's
  own verification criteria. Correctness was instead proven directly:
  `kubectl exec -n openbao openbao-0 -c openbao -- sh -c 'BAO_ADDR=https://openbao.openbao.svc:8200
  BAO_CACERT=/openbao/tls/ca.crt bao status'` (and the pod-internal DNS
  name) both succeeded with full CA verification, no skip-verify. The
  `openbao-server-test` Pod is currently left in `Error` status on the
  cluster — low-priority cleanup (`kubectl delete pod
  openbao-server-test`, Flux/Helm will recreate it clean on the next
  relevant change).
- The comment above `applications/openbao-db/controlplane` /
  `applications/openbao/base` in
  `clusters/controlplane/kustomization.yaml` still says "openbao's own
  SPIFFE-CSI TLS volume needs cert-manager-spiffe-csi-driver" — stale
  after the pivot to a real Certificate; the driver is no longer a
  dependency of this app. Needs a follow-up wording fix (harmless, not
  functionally wrong — `cert-manager-spiffe-csi-driver` still needs to
  come first for unrelated apps).
