# M2 Design: Control Plane Service Migration off Rackspace Spot

Date: 2026-07-13
Status: Approved 2026-07-13 (plan amendments A1-A4 in section 2 approved by Esten; dispositions updated same day for the SOPS key-exposure incident, PR #66/#68)
Parent: [fable-5-arch-plan.md](fable-5-arch-plan.md) milestone M2, [fable-5-arch-spec.md](fable-5-arch-spec.md)
Related: [M0 design](2026-07-11-m0-baseline-audit-design.md) (inventory + acceptance suites), [M1 design](2026-07-11-m1-controlplane-cluster-design.md) (the target cluster)
Inputs: [m2-spot-migration-inventory.md](../migration/m2-spot-migration-inventory.md) (2026-07-11 snapshot), `tests/platform-baseline/README.md` audit findings
Executor: Sonnet 4.6 under human review

## 1. Goal

step-ca, the cert-manager/SPIFFE stack, Crossplane (providers, functions,
compositions, managed-resource state), ESO, and public external-dns run on
`controlplane`; the Rackspace Spot cluster is deleted and its spend is zero.
Parallel-run throughout: Spot stays authoritative for each service until that
service's cutover is verified, and Spot is deleted only after a one-week soak
with the M0 contract suites green against `controlplane`.

Acceptance gate (fixed in M0): `.bin/run-platform-baseline.sh controlplane`
passes twice consecutively with `values/controlplane.env`.

## 2. Plan amendments (approved 2026-07-13)

The M0 audit invalidated three assumptions in the plan's M2 section. The
following decisions amend the plan and are recorded in the migration ADR:

| # | Plan said | Audit found | Decision |
|---|---|---|---|
| A1 | "root identity must not change — fleet trust depends on it" | Live trust domain is `cluster.local` (ADR-16 drift), so every Roles Anywhere trust anchor and ABAC condition re-enrolls regardless; the "root" already auto-rotates every 90 days by design (ADR-15 — the ~28d-ago rotation was cert-manager renewal working as intended, next due ~2026-09) | **Mint a fresh root on `controlplane`.** The trust surface today is only Spot (being deleted) and workstation bootstraps. This is the cheapest re-anchoring the fleet will ever have; it removes the riskiest move-state item. Shape of the new root: see A5 |
| A5 | Spec §7.1 target: "step-ca on the control plane is the root; each cluster's cert-manager issuer chains to it" | Deployed reality (per accepted ADR-15/ADR-5): there is **no step-ca-owned root**. The fleet trust anchor is `csi-driver-spiffe-ca`, a cert-manager self-signed Certificate auto-rotating every 90 days; ESO copies it to the step-ca namespace and step-ca merely mounts and serves it. A 90-day-rotating fleet root would churn Roles Anywhere anchors quarterly and force every M4+ workload cluster to re-chain its intermediate | **Stable offline root (10y, SOPS bootstrap set) + 1-year controlplane intermediate** (pathlen 1, so step-ca's x5c provisioner can still issue workload-cluster intermediates from M4 on). step-ca's issuing pair and cert-manager's ClusterIssuer both consume the intermediate; the root private key never enters the cluster. **Amends ADR-15** (recorded in the migration ADR); rotation becomes deliberate — the plan's M11 quarterly intermediate-rotation drills apply to the intermediate, not the root |
| A2 | "restore step-ca-db from barman backup" | `step-ca-db` has **no backup configured** (`Backup config: NONE`) and is degraded (1/3 instances) | **Fresh CNPG cluster + step-ca re-bootstrap.** With a fresh root there is nothing worth preserving (DB holds provisioners + short-lived-cert records). Barman backups are configured properly from day one, to TrueNAS NFS until Garage exists (M3) |
| A3 | "repoint `ca.crossplane.rye.ninja` … keep the old name serving through the transition" | Fresh root (A1) makes repointing the old name actively harmful: it would serve a different root behind a fingerprint clients already pinned. Also, the new cluster is IPv6-only and no out-of-LAN CA consumer exists until M6 | **`ca.rye.ninja` is born on the new CA; the old name never moves.** `ca.crossplane.rye.ninja` keeps pointing at Spot until decommission, then dies with it. Public exposure is AAAA-only (GUA VIP) + LAN ULA record; the IPv4 path is deferred to M6, which owns public-exposure work |
| A4 | (unstated) | After decommission, `estenrye/flux-platform-rendered` has no consumers — `controlplane` has its own rendered repo (M1) | **Archive the old rendered repo** at Spot decommission. Per-cluster rendered repos become the norm. The `DeployKey` managed resource for it is retired, not migrated |

Consequence worth stating plainly: because nothing state-critical moves for
step-ca, **the only true state migration in M2 is the Crossplane
managed-resource set for the `crossplane.rye.ninja` delegated zone** — ten
resources. That is small by design, and executing the Orphan → pause →
export → import → observe dance on it is a deliberate rehearsal of the
pattern M6+ cloud substrates will rely on, run here with a bounded blast
radius (worst case: DNS breaks for a name that is being retired anyway).

## 3. Inventory dispositions

Fills the empty disposition column of the [M0 inventory](../migration/m2-spot-migration-inventory.md).
No kickoff regeneration: with a fresh root and fresh DB (A1/A2), the only
state that must be current at migration time is the delegated-zone stack's
external names, and those come from the **live export in step 8** — the
2026-07-11 snapshot remains the Spot-death fallback (external IDs are
immutable while the resources exist). Note: the generator writes an empty
inventory when the cluster is unreachable instead of failing; do not run it
casually against the committed snapshot.

### 3.1 Crossplane managed resources

| Item | Disposition | Note |
|---|---|---|
| `DeployKey` flux-platform-rendered | **retire** | A4: set `deletionPolicy: Orphan`, leave in place; key dies when the repo is archived. Spot's Flux needs it until decommission |
| Delegated-zone stack for `crossplane.rye.ninja` (Zone, 4 NS Records, Role, Policy, RolePolicyAttachment, Profile) + `XDelegatedHostedZoneAWS` claim | **move-state, then retire at decommission** | Migrated to `controlplane` (section 5) so the zone keeps serving during the soak; at decommission the claim is deleted **from `controlplane`** so Crossplane garbage-collects zone, records, and IAM cleanly |
| XRDs, Compositions, providers, functions, DeploymentRuntimeConfigs, EnvironmentConfigs, ProviderConfigs | **recreate** | Installed by Flux from the same `applications/` sources; EnvironmentConfigs and Roles Anywhere ProviderConfigs get new trust-domain values (section 6) |

### 3.2 Databases, secrets, ESO

| Item | Disposition | Note |
|---|---|---|
| CNPG `step-ca-db` | **recreate** (A2) | Fresh cluster on `controlplane`; barman to TrueNAS NFS from day one; inventory's `move-state` policy row is superseded by A1/A2 |
| `step-ca/step-certificates-secrets` | **retire** | Fresh root; new secrets generated at re-bootstrap |
| `cert-manager/*` CA secrets, `csi-driver-spiffe-ca`, `trust-manager-tls` | **recreate** | Chain to the new root, trust domain `controlplane.rye.ninja` |
| `crossplane-system/aws-account-creds` | **move** | The static bootstrap credential — required to break the Roles Anywhere chicken-and-egg (section 4.4). Not in git or the compromised vault (applied at bootstrap); **[H]** source the value (or mint a fresh IAM key and revoke the old), SOPS-encrypt under `clusters/controlplane/` (new key); becomes the OpenBao break-glass entry in M3 |
| `external-secrets-operator/onepassword-sdk-token` | **recreate** | Per the [key-exposure incident](../../runbooks/crossplane-sops-key-exposure.md), every credential in the `crossplane` 1Password vault is treated as compromised. **[H]** mint a new 1Password service account scoped to the existing `controlplane` vault; SOPS-encrypt under `clusters/controlplane/`. The crossplane-scoped token is revoked at decommission |
| `crossplane-root-ca`, `crossplane-tls-*`, `envoy-*` | **recreate** | Generated by the installs themselves |
| `flux-system/sops-age` | **n/a** | `controlplane` already has its own key (M1) |
| ESO ClusterSecretStore `1password-sdk` + ExternalSecrets (`cloudflare-creds`, `github-token`, `flux-ssh-key-secret`) | **recreate** | Via Flux once the token secret lands |
| SOPS files under `clusters/crossplane/` | **retire** | Archived with the cluster entry. The original age key leaked to public history ([incident runbook](../../runbooks/crossplane-sops-key-exposure.md)); the dual-key rotation is in flight and its crossplane-scoped residue dies with the cluster |

### 3.3 PKI identity

The inventory's "MUST NOT change" section is superseded by A1/A5. New
hierarchy (generated by `.bin/generate-controlplane-pki.sh`, run by a human
so the root key never touches an agent session):

- **Root** `ryezone-labs Root CA`, 10 years, ECDSA P-256. Private key
  exists only SOPS-encrypted at
  `clusters/controlplane/secrets/step-ca-root.sops.yaml` (whole-file rule,
  bootstrap set per spec §8) — never applied to any cluster. Public cert
  ships in-repo as plain YAML (it is public material).
- **Intermediate** `ryezone-labs Intermediate CA controlplane`, 1 year,
  `maxPathLen=1` (must be ≥1: step-ca's x5c provisioner issues
  workload-cluster intermediates under it from M4 on). Stored as the
  `csi-driver-spiffe-ca` TLS Secret (name kept — chart mounts, ESO sync,
  and ClusterIssuer wiring stay untouched) with `ca.crt` carrying the root.
- **Fingerprint** (sha256 of the root cert) recorded in
  `tests/platform-baseline/values/controlplane.env`, in
  `docs/memory/step-ca-connectivity-validation.md` (rewritten for
  `ca.rye.ninja`), and in the migration ADR. Because the root is now
  stable, the pinned-fingerprint-goes-stale failure mode from M0 is gone.
- Rotation: intermediate annually (or by drill, plan M11); root only by
  deliberate ceremony. ADR-15's SPIFFE-CA section is amended accordingly.

## 4. Service designs

### 4.1 step-ca (fresh root, fresh DB)

1. CNPG operator (`applications/cnpg/`) added to
   `clusters/controlplane/kustomization.yaml`; `step-ca-db` cluster (3
   instances, `truenas-nfs` PVCs — see risk R2 on iSCSI). Backups: barman
   requires an S3 target, which does not exist until Garage (M3), so the
   M2 interim story is **scheduled logical dumps** (CronJob `pg_dump` to a
   `truenas-nfs` PVC, 14-day retention) plus the NAS's own ZFS snapshot
   schedule; barman-to-Garage lands in M3 as already planned. The restore
   drill (execution step 11) exercises the dump path.
2. step-ca deployed per the existing `applications/step-ca/` layout with a
   `controlplane` variant. Wiring change from Spot (A5): `ca.json` sets
   `root` to the root certificate and `crt`/`key` to the intermediate
   (today all three point at the same cert-manager CA). The mounted secret
   keeps the `csi-driver-spiffe-ca` name and the ESO cert-manager→step-ca
   sync pattern, so only the variant's config differs. DNS names
   `ca.rye.ninja` (primary, per A3) — the deployment never learns the old
   name.
3. Provisioners re-created declaratively (same provisioner set as Spot,
   verified against the regenerated inventory).

### 4.2 cert-manager / SPIFFE stack

cert-manager, approver-policy, trust-manager, csi-driver-spiffe on
`controlplane` with trust domain **`controlplane.rye.ninja` set before the
first SVID is issued** (ADR-16). Issuer change (A5): the ClusterIssuer is a
CA issuer over the SOPS-provisioned intermediate secret — the
`selfsigned` ClusterIssuer and the self-signed `csi-driver-spiffe-ca`
Certificate resource are **not** reproduced on `controlplane`.
trust-manager distributes the **root** as the fleet bundle.

**Deferred to M4** (Esten, 2026-07-13): evaluating
[smallstep/step-issuer](https://github.com/smallstep/step-issuer) as the
leaf-issuance path (cert-manager forwards CSRs to step-ca via a JWK
provisioner; intermediate key custody shrinks to the step-ca namespace and
the ESO mirror disappears). It cannot provision or rotate the intermediate
itself (`isCA` requests are rejected — leaf-only), and it couples every
SVID renewal to single-replica step-ca availability, so it is weighed at
M4 against the x5c per-cluster-intermediate pattern (ADR-7 Pattern D) when
workload-cluster issuance is designed; whatever wins can be retrofitted to
`controlplane` in the same stroke. Implementation must find and fix the cause
of the Spot drift (trust domain defaulted to `cluster.local` — almost
certainly the csi-driver-spiffe `--trust-domain` flag was never set in the
Spot variant) and add a render-time lint or chainsaw assertion so it cannot
recur. The `spiffe/` baseline suite asserts the URI SAN.

### 4.3 Crossplane install and state migration

Install via Flux from existing `applications/crossplane*/` sources (same
pinned versions as the inventory). State migration applies **only** to the
delegated-zone stack (section 3.1):

1. On Spot: set `deletionPolicy: Orphan` on the ten resources; scale
   Crossplane + providers to zero (pause).
2. Export claim, XR, and managed resources with
   `crossplane.io/external-name` annotations preserved (they are namespaced
   resources — preserve namespaces).
3. Apply on `controlplane`; verify every resource reaches `Synced=True,
   Ready=True` **without a create** (audit: external-name diff before/after,
   plus AWS/Cloudflare-side spot check that no new zone/record IDs appeared).
4. Flip `deletionPolicy` back to `Delete` on `controlplane`.
5. Spot's Crossplane stays scaled to zero for the remainder of the soak.

One provider at a time in the plan's sense reduces here to: kubernetes and
github providers have no migrated state (retire/recreate), so the dance runs
once, over the aws-iam / aws-route53 / aws-rolesanywhere / cloudflare
resources of the delegated zone.

A new `XDelegatedHostedZoneAWS` claim for **`controlplane.rye.ninja`** is
created fresh on `controlplane` (this was deferred from M1), fixing the
cluster's trust domain delegation per ADR-16.

### 4.4 Roles Anywhere re-enrollment (mandatory, per the drift finding)

Chicken-and-egg: the new cluster's provider SVIDs chain to the new root,
which AWS does not trust yet; creating the trust anchor requires AWS
credentials. Bootstrap sequence:

1. Apply `aws-account-creds` (moved static secret) as a temporary
   ProviderConfig credential for the iam/rolesanywhere providers.
2. Create (via Crossplane, so it is owned state): new trust anchor for the
   new root, profiles, and ABAC conditions pinned to
   `spiffe://controlplane.rye.ninja/...` URIs (ADR-12 pattern, replacing the
   `cluster.local` pins).
3. Flip provider ProviderConfigs to Roles Anywhere; verify each provider
   reconciles with SVID-derived credentials.
4. Quarantine the static secret (remove the ProviderConfig reference; keep
   the SOPS file as break-glass until OpenBao, M3).

The old trust anchor (old root, `cluster.local` ABAC) stays valid through
the soak — both clusters can hold AWS credentials simultaneously; the
Orphan+pause in 4.3 is what prevents them fighting over resources. It is
deleted at decommission.

### 4.5 ESO, external-dns, flux-monitoring

- ESO: operator via Flux; `onepassword-sdk-token` from SOPS; then the
  ClusterSecretStore and ExternalSecrets reconcile. Round-trip asserted by
  the `eso/` baseline suite.
- external-dns: `controlplane` already runs the UniFi webhook variant (M1).
  M2 adds the public-DNS variant (Roles Anywhere credentials, new SVID) for
  Route53/Cloudflare records — this is what publishes the `ca.rye.ninja`
  AAAA.
- flux-monitoring: already on `controlplane` since M1; nothing to do beyond
  the baseline suite passing.

### 4.6 DNS and naming (per A3)

| Name | During M2 | After decommission |
|---|---|---|
| `ca.rye.ninja` | New: public AAAA → GUA VIP; LAN ULA record via UniFi external-dns | Canonical CA name fleet-wide; all issuer configs use it |
| `ca.crossplane.rye.ninja` | Untouched, still → Spot (old root) | Deleted with the delegated zone (claim deletion GC) |
| `crossplane.rye.ninja` zone | Serving, owned by `controlplane` after 4.3 | Garbage-collected via claim deletion |

Workstation: re-run `step ca bootstrap` against `ca.rye.ninja` with the new
fingerprint; memory doc rewritten. No IPv4 path — LAN clients use the ULA
record; nothing off-LAN needs the CA until M6.

**VIP on-link caveat — resolved 2026-07-15:**
[2026-07-15-services-network-design.md](2026-07-15-services-network-design.md)
executed: both BGP VIP pools relocated onto dedicated routed,
not-on-link subnets (internal ULA `fd97:45c2:b3a1:f00::/112`, ingress GUA
`2607:3640:1064:27f::/112`, carved from the confirmed `/60` PD). The M1
"workstation can't self-test LB" limitation is gone, and the interim
manual host routes (`docs/memory/workstation-nat64-route.md`, now
retired) are no longer needed — validated from the client VLAN with zero
manual routes: `ca.rye.ninja` 15/15, and the NAT64 path incidentally
resolved by the same VLAN move. ADR-22 and ADR-23 carry the permanent
record (amendments dated 2026-07-15). Zone-based firewall (design §2 item
3) is a separate, still-open piece of that design — not blocking, since
routing correctness didn't depend on it.

A second, unrelated bug surfaced during validation and was also fixed:
Calico advertises a LoadBalancer service's BGP route from every node
regardless of `externalTrafficPolicy: Local` endpoint locality (no known-
good Calico version fixes this in our case — see ADR-22 amendment).
Mitigated by spreading Envoy across all 6 nodes with anti-affinity.

### 4.7 Change freeze

From the start of the state migration (4.3) until decommission,
`clusters/crossplane/` is frozen: no source-repo changes that render into
the Spot cluster entry. Enforced socially + a draft-PR label check; the
freeze is short (soak week + margin).

## 5. Decommission (gated on human go/no-go)

Preconditions: baseline runner green twice consecutively against
`controlplane` (with `STEP_CA_EXTERNAL_GATE=gate` — the Spot-era advisory
quarantine does not carry over), seven consecutive days of clean Flux
reconciliation and zero unintended MR recreations.

1. Delete the `crossplane-rye-ninja` claim on `controlplane`; verify AWS
   zone/records/IAM and Cloudflare NS records are garbage-collected.
2. Delete the old Roles Anywhere trust anchor + profiles (old root,
   `cluster.local` ABAC).
3. **[H]** Close out the [key-exposure incident](../../runbooks/crossplane-sops-key-exposure.md):
   revoke the crossplane-scoped 1Password service-account token, confirm the
   Cloudflare token rotation happened, and mark the runbook's crossplane-scoped
   items moot-by-decommission.
4. **[H]** Archive `estenrye/flux-platform-rendered` (A4).
5. Archive `clusters/crossplane/` in the source repo (move to
   `docs/migration/archive/` or delete — implementer's choice, recorded in
   the ADR); remove the Spot values file gate expectations that no longer
   apply (`values/crossplane.env` is kept for history, marked decommissioned).
6. **[H]** Delete the Rackspace Spot cloudspace; confirm next invoice is $0.
7. Update `docs/memory/`: `cluster-kubeconfig-lookup` (Spot path removed),
   `step-ca-connectivity-validation` (rewritten for `ca.rye.ninja`),
   `m1-implementation-status` superseded-note; update openbrain
   (`environment=home-lab`, `project=flux-platform`).

## 6. Execution sequence

Human steps marked **[H]**; roughly 4-6 working sessions across the 3-week
window (soak dominates the calendar).

| # | Step | Verify |
|---|---|---|
| 1 | Kickoff: parametrize `tests/step-ca/` (KUBECONFIG inheritance — the M0 README rule 3 debt); create `values/controlplane.env` | step-ca suites run against a values file |
| 2 | **[H]** Run `.bin/generate-controlplane-pki.sh`: 10y root + 1y intermediate (A5), SOPS-encrypt under `clusters/controlplane/`, fingerprint into the values file | sops round-trip; `ENC[` asserted on both files; fingerprint recorded; no plaintext key left on disk |
| 3 | CNPG operator + fresh `step-ca-db` + step-ca (`ca.rye.ninja`) + dump-based backup CronJob | CA health 200 on ULA VIP; fingerprint matches values file; dump lands on NFS |
| 4 | cert-manager stack, trust domain `controlplane.rye.ninja` (drift-cause fix + guard) | `spiffe/` suite green: URI SAN carries the right trust domain |
| 5 | DNS: `ca.rye.ninja` AAAA (GUA) + LAN ULA record; **[H]** workstation `step ca bootstrap` re-run | curl + fingerprint check from LAN and from a v6 external vantage |
| 6 | Crossplane + providers + functions + XRDs/compositions via Flux; Roles Anywhere bootstrap (4.4): static cred → new trust anchor/profiles/ABAC → flip to SVID auth → quarantine static cred | all providers `Healthy=True` on SVID credentials; `crossplane/` suite green |
| 7 | New `controlplane.rye.ninja` delegated-zone claim | claim Ready; `delegated-zone/` suite green with new trust domain |
| 8 | State migration of the `crossplane.rye.ninja` stack (4.3, Orphan → pause → export → import → observe); reconcile the live export against the 2026-07-11 snapshot before importing | external-name diff zero; no new cloud-side IDs; deletionPolicy restored |
| 9 | ESO + public external-dns variant (4.5) | `eso/` suite green; a test record reconciles |
| 10 | Full baseline runner x2 against `controlplane`; start 7-day soak; change freeze on `clusters/crossplane/` | both runs green, `STEP_CA_EXTERNAL_GATE=gate` |
| 11 | Restore drill: step-ca-db from a scheduled dump onto a scratch CNPG cluster | step-ca starts against restored DB |
| 12 | **[H]** Go/no-go review of soak evidence | sign-off |
| 13 | Decommission (section 5, includes **[H]** repo archive + Spot deletion) | GC verified; invoice $0 |
| 14 | ADR (migration executed, ADR-3 superseded, A1-A4 recorded); runbooks: state-migration pattern (reusable for M6+), step-ca restore; memory/openbrain updates | merged |

## 7. Exit criteria

- `.bin/run-platform-baseline.sh controlplane` green twice consecutively,
  external CA gate enforced, zero leftover test resources.
- Zero unintended managed-resource recreations (external-name audit from
  step 8 attached to the ADR).
- New root fingerprint recorded in values file, memory, and ADR; old CA
  name and old trust anchor gone.
- Spot cloudspace deleted; `clusters/crossplane/` archived; old rendered
  repo archived; monthly Spot spend $0.
- step-ca-db restore drill executed once.
- Migration ADR + runbooks merged; memory and openbrain updated.

## 8. Risks

| Risk | Handling |
|---|---|
| R1: Spot dies mid-migration (25% CA availability already observed) | Fresh-root design means `controlplane` never depends on Spot state; the only loss window is the delegated-zone import (step 8) — the inventory holds every external name, so resources can be imported from the snapshot even with Spot gone |
| R2: `truenas-iscsi` still blocked on IPv6 (upstream csi-lib-iscsi); step-ca-db lands on NFS | **Realized 2026-07-14, twice over**: driver-hardcoded NFS mapall broke postgres ownership (fixed: `truenas-nfs-pg` class mapall'd to NAS user `k8s-postgres` uid 26), then root:755 dataset roots blocked initdb entirely (bridged: `nfs-pg-owner` chown CronJob via JSON-RPC). Upstream issue filed; democratic-csi swap decision at M3 kickoff — see `docs/memory/truenas-nfs-ownership-workaround.md`. iSCSI move when unblocked still preferred |
| R3: barman-per-plan impossible until Garage (M3) | Interim dump CronJob + restore drill (steps 3, 11); barman-to-Garage is already an M3 task |
| R4: NAT64 appliance outage stalls provider reconciliation (AWS/Cloudflare/GitHub/1Password are v4-only paths) | Accepted M1 posture: outage breaks only v4 egress; appliance is its own tofu root with rebuild runbook; reconciliation resumes on recovery — no state loss |
| R5: observe-not-recreate fails on import (provider treats an MR as new) | Caught by the external-name/cloud-ID audit before deletionPolicy is flipped back; rollback = delete the imported MRs on `controlplane` (still Orphan), unpause Spot |
| R6: fingerprint-pinned clients missed in the fresh-root cutover | Known consumers enumerated in the inventory (workstation `~/.step`, baseline values file, Roles Anywhere trust anchor); step 5 re-bootstraps the workstation; anything else fails loudly against `ca.rye.ninja` and is fixed in the soak week |
| R7: change freeze slips and a render mutates Spot during soak | Freeze is scoped to `clusters/crossplane/` only and lasts ~1 week; baseline suites against `controlplane` are the gate, so a Spot-side wobble cannot fake a green migration |
