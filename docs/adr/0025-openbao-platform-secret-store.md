# 25. OpenBao as the Platform Secret Store

Date: 2026-07-25

## Status

Accepted

Amended 2026-08-04: documents the `.bin/bootstrap-<consumer>-<credential>.sh`
naming variant (per-credential, reusing an existing consumer's policy)
alongside the original `.bin/configure-openbao-*-secrets.sh` pattern
(per-consumer, mints a new policy/role/`ClusterSecretStore`), plus the
`provider-terraform` `ClusterSecretStore`'s second consumer (M4's UniFi
API key, `.bin/bootstrap-provider-terraform-unifi-key.sh`).

## Context

M3 introduced a break-glass/dynamic secret store to sit alongside
SOPS-in-git: SOPS is fine for bootstrap-critical values needed before the
cluster can reach anything else, but it has no audit trail, no dynamic
credentials, and every rotation is a git commit. Full design:
[2026-07-21-m3-identity-secrets-design.md](../superpowers/specs/2026-07-21-m3-identity-secrets-design.md)
§A2–A4, §A6.

OpenBao (the Vault-compatible fork) was chosen over HashiCorp Vault for
license reasons only — the feature set this milestone uses (kv-v2,
Kubernetes auth, policies) is identical between the two.

## Decision

**Deployment**: OpenBao `2.6.1`, 3 replicas, `server.ha.enabled: true`.

**Storage backend deviates from the original design.** The design called
for integrated Raft storage; the actual deployment uses **PostgreSQL** (a
dedicated `openbao-db` CNPG cluster) instead, with `raft.enabled: false`
and `storage "postgresql" { ha_enabled = "true" }`. Reasons this changed
mid-milestone:

- This cluster already runs CNPG for every other stateful platform
  service (step-ca-db, keycloak-db) with a proven barman-cloud-to-Garage
  backup path (ADR pattern established in M2). Reusing it for OpenBao
  means one fewer storage technology to operate, one fewer backup/restore
  procedure to maintain, and no separate Raft snapshot/restore tooling to
  build.
- OpenBao's Postgres HA backend coordinates leader election via a
  dedicated lock table (`openbao_ha_locks`) — no Raft peer discovery or
  quorum management needed; every pod just points at the same CNPG
  primary via `BAO_PG_CONNECTION_URL`, sourced from CNPG's
  auto-generated app Secret. No database credentials land in a rendered
  manifest.
- This makes OpenBao's restore story identical in shape to every other
  CNPG-backed app on this cluster: barman-cloud WAL archiving + base
  backups to Garage, restored via a scratch `Cluster` with
  `bootstrap.recovery` — see
  [docs/runbooks/openbao-restore.md](../runbooks/openbao-restore.md).

**TLS**: server certificate is a real `cert-manager` `Certificate` issued
by `csi-driver-spiffe-ca` (not the SPIFFE CSI driver directly — it doesn't
support DNS SANs, only SPIFFE IDs, which OpenBao's own health checks and
peer communication need as real DNS names).

**Unseal strategy (A3)**: static Shamir key shares (5 shares, 3-of-5
threshold), SOPS-encrypted whole-file at
`clusters/controlplane/secrets/openbao-unseal.sops.yaml`. Every OpenBao
restart (pod recreation, `OnDelete` upgrade rollout) requires a manual
unseal — documented in
[docs/runbooks/openbao-unseal.md](../runbooks/openbao-unseal.md).
Auto-unseal (AWS KMS / a cloud KMS) is explicitly deferred: this cluster
has no cloud dependency for a storage decision at this milestone, and
introducing one only to avoid a manual step during restarts isn't worth
the coupling. Revisit as an M11 hardening item if manual unseal frequency
becomes a real operational burden.

**Audit logging**: `audit "file" "to-stdout"`, declared in OpenBao's own
HCL config file, not enabled via the API. OpenBao rejects `bao audit
enable` over the API outright — a deliberate upstream hardening, since
file/socket audit devices can write to arbitrary paths, so only the
server's own config file (not a runtime API call any authenticated caller
could make) may declare one. Because the StatefulSet uses `OnDelete`, a
config change like this needs a manual `kubectl delete pod` per replica
to take effect.

**ESO integration**: a `ClusterSecretStore` per consumer scope (not one
shared store), each with its own Kubernetes-auth role and policy —
`openbao` (crossplane-system secrets), `openbao-cert-manager`
(cert-manager-acme's Cloudflare token), `openbao-provider-terraform`
(M4: `provider-terraform`'s KVM SSH key and, since 2026-08-04, its UniFi
API key — see below). Least-privilege per consumer, matching this repo's
existing pattern of per-purpose Garage S3 keys rather than one shared
credential. OpenBao has no CRD-based configuration surface of its own (no
`VaultPolicy`/`VaultRole` CRDs) — every kv-v2 mount, Kubernetes auth
method, policy, and role is configured imperatively by a
`.bin/configure-openbao-*-secrets.sh` script (one per new consumer scope,
i.e. new policy/role/`ClusterSecretStore`), not by any manifest in this
repo. This is a deliberate gap, not an oversight: these scripts read the
OpenBao root token from 1Password and write directly via `bao` CLI
commands piped into `kubectl exec`, so the plaintext policy-defining
commands never touch a committed file or a rendered manifest.

**`.bin/bootstrap-<consumer>-<credential>.sh` is a related but distinct
naming pattern, not a single consistent one.**
`bootstrap-provider-terraform-kvm-key.sh` (M4 step 1) is actually a
`configure-openbao-*-secrets.sh`-equivalent under different naming — it
creates the `provider-terraform-secrets-read` policy and
`eso-provider-terraform` role itself, then generates an SSH keypair
(`ssh-keygen`) and stores it, all in one script, because it was the first
script to onboard that consumer scope. `bootstrap-provider-terraform-unifi-key.sh`
(M4, 2026-08-04) is narrower and doesn't repeat that: it assumes
`provider-terraform-secrets-read` already exists (confirmed via `bao
policy read` before writing anything; errors with a pointer to the KVM
key script if missing) and only adds one more `bao kv put` entry under
the path that policy already grants. It also can't auto-generate its own
credential the way `ssh-keygen` does — UniFi has no CLI/API to mint a new
admin API key, so it only stores a key generated by hand via the UniFi
Site Manager UI (documented in the script's own header), read from a
silent, non-echoed prompt rather than a file or argument. Future
per-credential scripts within an already-onboarded consumer should follow
the narrower `bootstrap-provider-terraform-unifi-key.sh` shape, not
re-create policy/role like the KVM key script did.

**Migration scope (A4) changed once step 6 actually started.** A4
named `aws-account-creds` as the thing to migrate first, closing an
M2-deferred item — but no such secret ever existed. The M2 Roles
Anywhere trust-anchor bootstrap was done interactively with the
operator's own AWS SAML SSO credentials, not a stored static IAM key;
A4's "move it, quarantine it, migrate it to OpenBao break-glass"
description was of a mechanism that was planned but never built. That
part of A4 was dropped, not completed — if a break-glass AWS credential
in OpenBao is ever wanted for a future manual bootstrap, that's a fresh
decision, not a migration.

What actually migrated instead, as the ESO+OpenBao proof-of-concept:
both of Crossplane's own `ExternalSecret`s (`github-token`,
`cloudflare-creds` — previously sourced from the `1password-sdk`
`ClusterSecretStore`), confirmed clean of any circular dependency on
OpenBao first (`kubectl get managed -A` showed Crossplane's only live
managed resources are DNS delegation + IAM Roles-Anywhere plumbing —
nothing OpenBao itself depends on). A4 scoped this to exactly one
secret as a proof of concept; both turned out to be equally clean
candidates once actually checked, so both moved rather than picking one
arbitrarily. Talos machine secrets and other bootstrap-critical SOPS
values stay in SOPS: they're only needed during cluster cold start,
before OpenBao is reachable at all, so moving them would create a hard
circular dependency. Full SOPS→OpenBao migration of non-bootstrap
secrets is explicitly an M11
hardening step, not part of M3.

**Off-site backup (A6)**: OpenBao's real backup data is `openbao-db`'s
barman WAL archive + base backups in Garage's `openbao-db-barman` bucket
(a consequence of the Postgres-backend pivot above — there is no separate
Raft snapshot to manage). That bucket is mirrored off-site to a
Cloudflare R2 bucket via a scheduled sync Job
(`applications/openbao-snapshots-sync/base`), the same pattern later
reused for `step-ca-db`'s off-site copy. R2 was chosen over S3 for this:
free egress, S3-compatible API, and a static scoped API token in SOPS
avoids the circular-dependency problem of storing the off-site-backup
credential inside the thing being backed up (a Crossplane-provisioned
bucket would make the DR artifact depend on Crossplane being healthy;
Roles Anywhere/SPIFFE auth would add a SPIFFE volume mount to a sync
CronJob whose only job is copying bytes). Cost is negligible either way
at home-lab snapshot volumes.

## Consequences

- OpenBao's availability is now coupled to `openbao-db`'s (CNPG/Postgres)
  availability — a deliberate trade of "one fewer storage technology" for
  "one more dependency in OpenBao's own boot chain." Restoring OpenBao
  after data loss means restoring `openbao-db` first (barman-cloud
  recovery), then unsealing against the restored data — two runbooks in
  sequence, not one.
- Every OpenBao pod restart requires a human with SOPS access to unseal —
  accepted risk (R4 in the M3 design), revisit if it becomes burdensome.
- OpenBao's own kv-v2 mounts, auth methods, policies, and roles are
  **not** in GitOps — they only exist as scripts and live OpenBao state.
  A full cluster rebuild needs the unseal ceremony, then every consumer's
  policy/role script, then every per-credential script for that consumer,
  before that consumer's `ExternalSecret`s can resolve — but scripts for
  *different* consumers are independent of each other (no ordering
  between them), since each owns its own policy/role. As of 2026-08-04,
  known scripts by consumer: `provider-terraform`
  (`bootstrap-provider-terraform-kvm-key.sh`, which also creates that
  consumer's policy/role, then `bootstrap-provider-terraform-unifi-key.sh`);
  crossplane (`configure-openbao-crossplane-secrets.sh`); cert-manager
  (`configure-openbao-cert-manager-secrets.sh`); talos-cluster-bootstrap
  (`configure-openbao-talos-cluster-bootstrap-secrets.sh`). This list is
  maintained by hand here — there's no automated check that it stays
  complete as new consumers/credentials are added.
- Two independent secret stores now exist in production (SOPS-in-git,
  OpenBao) with different trust models and rotation stories. This is
  intentional for M3's scope (A4) but means engineers need to know which
  one a given secret lives in — SOPS for bootstrap-critical/pre-OpenBao
  values, OpenBao for everything migrated on a case-by-case basis going
  forward.
