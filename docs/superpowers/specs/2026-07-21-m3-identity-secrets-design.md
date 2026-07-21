# M3 Design: Identity and Secrets Core

Date: 2026-07-21
Status: Draft — pending human review and approval of [H]-marked decisions
Companion: [fable-5-arch-plan.md](fable-5-arch-plan.md) §M3,
           [fable-5-arch-spec.md](fable-5-arch-spec.md) §6, §8, §13

## 1. Goal

OpenBao, Keycloak, Pinniped Supervisor, and Garage running HA on `controlplane`.
ESO consuming OpenBao as its primary secret backend. A human can `kubectl get pods`
on `controlplane` authenticated through Keycloak + Pinniped.

Secondary: unblock iSCSI on the IPv6-only cluster by swapping to democratic-csi
at kickoff; retire the `nfs-pg-owner` CronJob bridge; migrate step-ca-db
backups from the dump CronJob to real barman targeting Garage.

## 2. Approved amendments to prior decisions

### A1 — Swap truenas-csi → democratic-csi (amends ADR-21)

The M3 plan called for a democratic-csi swap decision at kickoff. The pre-M3
research (2026-07-21) settles it:

**truenas-csi iSCSI is still blocked.** kubernetes-csi/csi-lib-iscsi#94 (IPv6
portal mis-parse) is open and unfixed on master. truenas-csi pins a pre-fix
version with no workaround path that doesn't require upstream action.

**democratic-csi `datasetPermissions*` is broken on our TrueNAS version.**
Issue democratic-csi#564 (filed 2026-07-09, open): on TrueNAS SCALE 25.10.x
a global `perm_change` job lock + `lock_queue_size` dedup causes setperm calls
to be silently coalesced under concurrent PVC creation — some datasets end up
`root:root 0755` while the API reports success. This is the same failure mode
the CronJob bridge fixes, but worse because it's silent and racey. Do NOT use
`datasetPermissions*`.

**The correct workaround for NFS** (confirmed by issue #564 author, same
environment): `csiDriver.fsGroupPolicy: File` + no `datasetPermissions*`.
Kubelet applies fsGroup per-pod at mount time. CNPG sets `fsGroup: 26`
natively in its pod spec, so Postgres volumes work without driver-side chown.

**democratic-csi iSCSI is a different code path** (native Node.js, not
csi-lib-iscsi) and is the only viable route to iSCSI on this IPv6-only
cluster. Issue #564's author runs `freenas-api-iscsi` on TrueNAS SCALE
25.10.4 with iSCSI working alongside NFS. This is unverified on our cluster
but is the primary motivation for the swap.

**Chart version**: `democratic-csi-0.15.1` (released 2026-01-07, latest stable,
digest-pinnable). Driver image: use a digest-pinned `next` tag as the author
of #564 did — no versioned image tag exists for the driver itself.

**Swap scope**:
- `truenas-nfs-pg` StorageClass → `democratic-csi-nfs-pg` (mapall uid 26,
  `fsGroupPolicy: File`, no `datasetPermissions*`)
- `truenas-nfs` default StorageClass → `democratic-csi-nfs` (same NFS params,
  `fsGroupPolicy: File`)
- Add `democratic-csi-iscsi` StorageClass (default block, RWO) — contingent on
  smoke test passing; see risk R1
- Retire `nfs-pg-owner` CronJob and `k8s-postgres` NAS user only after smoke
  test confirms existing CNPG PVCs work without it (fsGroup covers the
  ownership gap)
- **ADR**: amendment to ADR-21; recorded after smoke test confirms iSCSI

**TrueNAS 25.10 NFS API compatibility (issue #532 watch)**: #532 documents API
breakage for `freenas-api-nfs` on TrueNAS CE 25.04 (not SCALE). We are on
SCALE 25.10.4. Quick probe during step 1: create one NFS PVC via
`freenas-api-nfs`; if it fails with API validation errors, fall back to
`freenas-nfs` (SSH-based) driver while tracking #532's resolution.

### A2 — Garage before OpenBao raft snapshots (ordering)

Garage is step 1 after the CSI swap. OpenBao raft snapshots target Garage, so
Garage must be healthy before the OpenBao snapshot CronJob is wired up.
OpenBao itself does NOT need Garage to boot: unseal keys are SOPS-encrypted
at bootstrap; Garage is only the snapshot destination. This avoids the
chicken-and-egg of "OpenBao needs Garage for snapshots, Garage admin token
needs OpenBao."

**Garage admin token bootstrap**: SOPS-encrypted at `clusters/controlplane/
secrets/garage-admin.sops.yaml`; rotated into OpenBao once both are up. The
SOPS entry is the break-glass path, identical to how `aws-account-creds` was
handled in M2.

### A3 — OpenBao unseal strategy

Static unseal keys SOPS-encrypted. Auto-unseal (AWS KMS / Cloudflare KV) is
deferred past M3 — the home lab has no network dependency on cloud for storage
decisions this milestone. Each restart requires a manual unseal or a runbook
invocation. Document this explicitly; auto-unseal is an M11 hardening item.

### A4 — Secret migration scope for M3

M3 migrates only:

1. `aws-account-creds` (static AWS bootstrap key from M2) → OpenBao break-glass
   vault path; ESO `ExternalSecret` fetches it on demand. This closes the M2
   design's explicit deferred item.
2. Proof-of-concept migration of one existing SOPS secret to ESO+OpenBao (to
   validate the pattern before M4 uses it everywhere).

Talos machine secrets and other bootstrap-critical SOPS values stay in SOPS
for now — those are only needed during cluster cold start, before OpenBao is
reachable. Full SOPS→OpenBao migration of non-bootstrap items is an M11
hardening step.

### A5 — Public exposure path for id.rye.ninja and sso.rye.ninja: same as ca.rye.ninja

Replicate the `ca.rye.ninja` pattern exactly:

- Envoy Gateway (`merged-eg`) listener with hostname patched at the cluster
  level (same `clusters/controlplane/patches/` pattern)
- external-dns reads the Gateway/Route source and creates a public AAAA
  pointing at the Envoy Gateway GUA VIP — no UniFi port-forward rules, no
  Cloudflare Tunnel
- The GUA VIP is already publicly routable on IPv6 (same as `ca.rye.ninja`)

The only implementation difference from step-ca: Keycloak and Pinniped
Supervisor terminate TLS themselves via cert-manager-issued certs, so these
use `mode: Terminate` HTTPS listeners + HTTPRoutes rather than TLS Passthrough
+ TLSRoutes. The Gateway class, external-dns mechanism, and DNS record type
are identical.

No new infrastructure required. **This decision is closed; no [H] gate needed.**

### A6 — Off-site backup destination for OpenBao raft snapshots: Cloudflare R2

Cloudflare R2: static API token in SOPS (same bootstrap-credential pattern
as other pre-OpenBao secrets; avoids the circular dependency of storing the
off-site backup credential inside the thing being backed up), free egress,
S3-compatible API, well within R2's free tier at home-lab snapshot volumes
(snapshot size is a few MB; 30-day retention stays under 300 MB indefinitely).

AWS S3 was the alternative. Cost is negligible for both (~$0/mo). S3 was
rejected because the cleanest auth path (Roles Anywhere + SPIFFE) adds a
SPIFFE volume mount to the snapshot CronJob, and a Crossplane-provisioned
bucket adds a Crossplane-healthy dependency to a DR artifact. A static IAM
key in SOPS would work but adds another static credential to manage.

**[H] Before step 7**: create the Cloudflare R2 bucket (`openbao-snapshots`)
and a scoped API token (Object Read & Write on that bucket only); SOPS-encrypt
the token under `clusters/controlplane/`. The R2 bucket for step-ca-db barman
(PR #64, draft, never merged) was never created — this is a fresh bucket.

## 3. Execution sequence

Human steps marked **[H]**. Each step's verify criterion must pass before
proceeding.

| # | Step | [H]? | Verify |
|---|---|---|---|
| 1 | democratic-csi: deploy chart 0.15.1 alongside truenas-csi; create shadow StorageClasses (`democratic-csi-nfs`, `democratic-csi-nfs-pg`, `democratic-csi-iscsi`); smoke test each (NFS PVC bind, CNPG cluster on `-nfs-pg` fsGroup check, iSCSI PVC bind) | H: verify CNPG pod can write as uid 26 without CronJob | NFS+iSCSI PVCs bind; `ls -la` inside CNPG pod shows uid 26 owns the data dir; no EACCES in logs |
| 2 | Flip default StorageClass to democratic-csi; migrate step-ca-db to democratic-csi-nfs-pg (new PVC + CNPG switchover); retire `nfs-pg-owner` CronJob; step-ca-db back healthy | | step-ca health 200 on `ca.rye.ninja`; fingerprint unchanged; chainsaw suite green |
| 3 | Garage: deploy 3-node cluster on `controlplane`, volumes on `democratic-csi-iscsi`; create buckets: `step-ca-db-barman`, `openbao-snapshots`, `lgtm` (reserved), `jwks` (reserved) | | S3 round-trip smoke test (put/get/delete) on each bucket |
| 4 | Migrate step-ca-db backups from dump CronJob → barman to Garage (`step-ca-db-barman` bucket); remove dump CronJob and its PVC | | Barman base backup completes; WAL archiving active; one restore verified from barman to a scratch CNPG cluster |
| 5 | OpenBao: deploy HA raft (3 replicas) on `controlplane`; TLS from cert-manager; SOPS-encrypted unseal keys; initialize and unseal; audit log to stdout | H: unseal ceremony (SOPS key access) | `vault status` sealed=false; chainsaw: seal/unseal round-trip; audit log entries visible |
| 6 | Wire ESO ClusterSecretStore → OpenBao (Kubernetes auth); migrate `aws-account-creds` to OpenBao break-glass path; create proof-of-concept ExternalSecret | | ESO ClusterSecretStore Healthy; ExternalSecret syncs; `aws sts get-caller-identity` from the synced creds succeeds |
| 7 | OpenBao raft snapshot CronJob → Garage `openbao-snapshots` bucket (+ off-site copy per A6) | | Snapshot appears in Garage; restore drill: unseal a scratch OpenBao from the snapshot |
| 8 | `keycloak-db` CNPG cluster on `democratic-csi-nfs-pg`; barman to Garage `keycloak-db-barman` bucket | H: confirm realm/group names | keycloak-db CNPG Cluster Ready; barman backup active |
| 9 | Keycloak: deploy on `controlplane`, wire to keycloak-db; realm `ryezone-labs` + groups (`platform-admin`, `viewer`) bootstrapped declaratively; expose at `id.rye.ninja` via Envoy Gateway HTTPS terminate + external-dns AAAA (same pattern as ca.rye.ninja, A5) | | Keycloak admin UI reachable at `https://id.rye.ninja`; realm exists; declarative config re-applies cleanly |
| 10 | Pinniped Supervisor + Concierge on `controlplane`; OIDC backend: Keycloak `ryezone-labs`; issuer `https://sso.rye.ninja` | H: run `pinniped get kubeconfig` + `kubectl get pods` | Authenticated `kubectl get pods -n kube-system` succeeds via Pinniped+Keycloak login |
| 11 | ADRs: ADR-21 amendment (democratic-csi swap, iSCSI unblocked), ADR-25 (OpenBao), ADR-26 (Keycloak+Pinniped); runbooks: OpenBao unseal, OpenBao restore, Keycloak realm restore, Garage node replacement | | ADRs merged; runbooks in `docs/runbooks/` |

## 4. Exit criteria

- democratic-csi iSCSI PVC binds and a pod writes to it on the IPv6 cluster
  (proves the blocker from M1/M2 is cleared)
- `nfs-pg-owner` CronJob removed; step-ca-db healthy; `ca.rye.ninja` health
  check passes; fingerprint unchanged
- Garage S3 round-trip green on each provisioned bucket
- step-ca-db barman writes to Garage; one restore to a scratch CNPG cluster
  verified
- OpenBao chainsaw suite: seal/unseal status, ESO round-trip (ExternalSecret
  syncs a secret from OpenBao); `aws-account-creds` reachable via ESO
- OpenBao raft snapshot in Garage bucket, restore drill verified once
- Keycloak reachable at `https://id.rye.ninja`; realm declarative config
  re-applies cleanly
- Pinniped chainsaw suite: OIDC login → RBAC-scoped `kubectl get pods` succeeds
- Human completes an authenticated `kubectl get pods` via Pinniped+Keycloak
- ADRs 25+26 merged; ADR-21 amended

## 5. New ADRs

| ADR | Title | Covers |
|---|---|---|
| ADR-21 amendment | democratic-csi replaces truenas-csi | iSCSI IPv6 unblock; NFS fsGroupPolicy:File ownership pattern; CronJob bridge retired |
| ADR-25 | OpenBao as platform secret store | HA raft, SOPS bootstrap unseal, ESO ClusterSecretStore pattern, Garage snapshot target, migration scope (A4) |
| ADR-26 | Keycloak + Pinniped fleet identity | Realm ryezone-labs, group model, Pinniped Supervisor/Concierge, OIDC client list, public exposure |

## 6. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| R1: democratic-csi `freenas-api-iscsi` fails on IPv6 (unverified) | Medium | Smoke test is step 1 before any dependency is wired to iSCSI. If it fails: Garage uses NFS (`democratic-csi-nfs`) instead; iSCSI remains blocked pending upstream fix; record in ADR-21 amendment. The rest of M3 proceeds on NFS. |
| R2: democratic-csi NFS + `fsGroupPolicy:File` doesn't cover CNPG ownership without `datasetPermissions*` | Low | CNPG explicitly sets `fsGroup: 26`; kubelet applies it at mount. Keep `nfs-pg-owner` CronJob running until step 2's smoke test confirms CNPG pod sees uid 26 ownership — only retire after confirmed. |
| R3: TrueNAS 25.10 NFS API incompatible with `freenas-api-nfs` (issue #532 is 25.04 CE, but 25.10 SCALE may have same API changes) | Low-Medium | `freenas-api-nfs` smoke test in step 1. If it fails, fall back to `freenas-nfs` (SSH) driver variant for NFS; file a new issue; no M3 blocking since NFS shape is otherwise unchanged. |
| R4: OpenBao unseal requires human during every restart | Known/accepted | Documented explicitly in ADR-25 and the unseal runbook. Auto-unseal deferred to M11 hardening. |
| R5: Garage admin token bootstrap before OpenBao exists | Known/accepted | SOPS-encrypted at bootstrap (A2), rotated into OpenBao post-M3. Same pattern as `aws-account-creds` in M2. |

## 7. Human prerequisites (before M3 starts)

- ~~**[H] A5**~~: Closed — replicate the `ca.rye.ninja` Envoy Gateway + external-dns
  AAAA pattern. No new infrastructure needed.
- **[H] A6** (before step 7): Create Cloudflare R2 bucket `openbao-snapshots`
  + scoped API token (Object Read & Write on that bucket only); SOPS-encrypt
  under `clusters/controlplane/`. Decision closed on R2; bucket doesn't exist yet.
- **[H] Realm/group names**: Confirm or amend the group model from the spec
  (`platform-admin`, `viewer`, tenant groups) before step 8. Names are baked
  into declarative config and hard to rename after Pinniped RBAC bindings
  reference them.
- **[H] UPS**: Identity and secrets core lives on the home lab from M3 onward.
  Confirm UPS covers TrueNAS + KVM host for graceful shutdown. (Non-blocking
  for M3 itself but worth scheduling before M3 completes.)
