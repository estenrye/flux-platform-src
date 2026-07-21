---
name: m2-step8-delegated-zone-migration
description: M2 step 8 state migration executed 2026-07-21 — crossplane-rye-ninja delegated-zone stack moved from Spot to controlplane, plus the Crossplane managementPolicies gotchas hit along the way
metadata:
  type: project
---

Per [M2 design](../superpowers/specs/2026-07-13-m2-migration-design.md)
§4.3/§6 step 8: the ten `crossplane.rye.ninja` delegated-zone resources
(Zone, 4 Cloudflare NS Records, IAM Role/Policy/RolePolicyAttachment,
Roles Anywhere Profile, plus the claim) were migrated from Spot to
`controlplane` on 2026-07-21. Commit: "M2 step 8: migrate
crossplane-rye-ninja delegated-zone stack to controlplane" on
`m2-spot-migration`. Manifests: `clusters/controlplane/crossplane-resources/
{namespace,delegated-hosted-zone-aws}.crossplane-rye-ninja.yaml`.

**Result:** zero external-name diff across all 9 managed resources;
verified directly against AWS (`aws iam get-policy`, `aws rolesanywhere
get-profile`) that `PolicyId`/`profileId`/`CreateDate` were unchanged —
nothing was recreated cloud-side. Spot's Crossplane (`crossplane-system`
namespace, all 14 deployments) is now scaled to zero for the rest of the
soak, per design step 8's "pause" requirement. The 9 MRs on Spot were
also switched to a Delete-excluding `managementPolicies` before export as
an orphan safety net.

**Gotcha 1 — `deletionPolicy` is gone.** This Crossplane version replaced
the old `spec.deletionPolicy: Orphan/Delete` field entirely with
`spec.managementPolicies` (array of `Observe|Create|Update|Delete|
LateInitialize|*`, default `["*"]`). The design doc's "set deletionPolicy:
Orphan" instructions translate to: patch `managementPolicies` to a list
excluding `Delete` for orphan protection, and back to `["*"]` to restore
full management. Applies to any future migration (M6+) following this
pattern.

**Gotcha 2 — three resource kinds silently stall under a partial
managementPolicies list.** IAM `Policy`, IAM `RolePolicyAttachment`, and
RolesAnywhere `Profile` (unlike `Zone`, `Record`, and `Role`, which worked
fine) reconciled to `Synced=True` but never populated `status.atProvider`
or set a `Ready` condition when `managementPolicies` was the restricted
list. No error, no event — just silence indefinitely. Root cause not
fully diagnosed (provider-side quirk, likely specific to these upjet
resource kinds' Observe path with a non-wildcard policy list); the fix is
to set `managementPolicies: ["*"]` on these three kinds as soon as
Delete-protection is no longer needed, rather than expecting them to
report status under a partial policy. If this recurs at M6+, don't spend
time chasing provider logs — go straight to `["*"]` and independently
verify against the cloud API (see below) instead of trusting Crossplane's
own status object for these three kinds specifically.

**Gotcha 3 — manually patching a Flux-managed Deployment (e.g. to add
`--debug`) gets silently reverted.** `crossplane-providers`/`crossplane-
resources` Kustomizations reconcile frequently enough (observed within
~1 min) that an imperative `kubectl patch` on provider deployment args is
wiped before it's useful for live debugging. Don't bother; go straight to
independent verification against the actual cloud provider API instead.

**Verification technique used** (reusable at M6+): with an AWS SSO
session (`aws sso login --profile ops-opex-dns-automation`, account
`832767337984`), `aws iam get-policy --policy-arn ...`, `aws iam
list-attached-role-policies --role-name ...`, and `aws rolesanywhere
get-profile --profile-id ...` gave authoritative ground truth independent
of Crossplane's status reporting — this is the fallback when Crossplane's
own Synced/Ready conditions are ambiguous or silent.

This procedure is now generalized as
[docs/runbooks/crossplane-state-migration.md](../runbooks/crossplane-state-migration.md)
(M2 step 14 deliverable) — reuse it rather than re-deriving the pattern
at M6+.

See also [[m2-change-freeze]] (freeze on `clusters/crossplane/` does not
block this `clusters/controlplane/`-only change) and
[[crossplane-bootstrap-phasing]] for the general composition/XRD
dependency pattern this claim relies on.
