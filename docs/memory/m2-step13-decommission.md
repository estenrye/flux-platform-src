---
name: m2-step13-decommission
description: M2 step 13 decommission tracker — items completed and remaining as of 2026-07-21
metadata:
  type: project
---

Live tracker for [M2 design](../superpowers/specs/2026-07-13-m2-migration-design.md)
§5 decommission, gated by [[m2-step12-go-decision]] (Go, 2026-07-21).
Update this as items complete rather than writing a new memory per item.

**Mechanism note learned the hard way**: `controlplane`'s Flux reconciles
from `flux-platform-rendered-controlplane` (`main`), a separate rendered
repo — NOT from `flux-platform-src` directly. Pushing to a `flux-platform-src`
feature branch does nothing to the live cluster until that branch merges
to `main`, CI renders it, and the rendered PR is manually merged
(auto-merge is off, [[rendered-repo-automerge-milestone]]). Mid-migration
decommission actions on live cluster state were therefore done
imperatively via `kubectl`/`aws` CLI, matching the source-repo commit
that keeps the manifest removed for whenever the branch does merge —
same pattern as [[m2-step8-delegated-zone-migration]]'s import.

## Item 1 — delete `crossplane-rye-ninja` claim: DONE (2026-07-21)

Deleted imperatively (`kubectl delete xdelegatedhostedzoneaws
crossplane-rye-ninja -n crossplane-controlplane-cluster`); source manifest
already removed from `clusters/controlplane/crossplane-resources/`
(commit `af59e10`). Cascaded cleanly except the Route53 Zone, which
blocked on `HostedZoneNotEmpty` — two **Spot-era, non-Crossplane-managed**
records were still in the zone: `ca.crossplane.rye.ninja` A →
`174.143.59.222` and its `external-dns` ownership TXT record (written
directly by Spot's own external-dns, never a Crossplane MR). Per design
§4.6 these were always meant to die with this zone. Deleted directly via
`aws route53 change-resource-record-sets` (account `832767337984`,
profile `ops-opex-dns-automation`), after which the Zone's async delete
retry succeeded on its own.

Verified against AWS directly (not just Crossplane status, per the step
8 lesson): `NoSuchHostedZone` for `Z087069529GAZBM0GNQPI`, `NoSuchEntity`
for the IAM role, `ResourceNotFoundException` for the RolesAnywhere
profile. Kubernetes side fully clear (`kubectl -n
crossplane-controlplane-cluster get <all 9 kinds>` → empty).

**If this pattern recurs**: any Route53 Zone MR being deleted via a
Crossplane claim can be blocked by non-Crossplane-managed records
(external-dns writing directly, manual records, etc.) — check
`aws route53 list-resource-record-sets` before assuming a stuck deletion
is a Crossplane bug.

### Near-miss: Spot's Crossplane recreated the whole stack three times

**What happened.** Step 8 (2026-07-21, earlier the same day) scaled
Spot's `crossplane-system` deployments to 0 as the "pause" half of the
Orphan-protect-and-pause step, but never suspended Spot's own Flux
Kustomizations (`flux-platform`,
`flux-platform-external-dns-aws-rolesanywhere`). Sometime between step 8
and step 13, Spot's Flux reconciled those deployments back to their
desired (non-zero) replica counts — the exact "Gotcha 3" pattern already
documented in [[m2-step8-delegated-zone-migration]] for manual Deployment
patches, just not recognized in time as applying to replica *counts* too,
not only container args.

With Spot's providers running again and Spot's own copies of the 9
managed resources still present (Orphan-protected — `Delete` excluded
from `managementPolicies`, but `Create` still allowed), each provider's
next `Observe()` found nothing to do *until* item 1's claim deletion on
`controlplane` removed the AWS-side originals out from under them. At
that point Spot's standalone MRs saw "resource does not exist" and
called `Create()` — recreating the IAM role, policy, RolesAnywhere
profile, Route53 zone, and (once) the 4 Cloudflare NS records, live in
production DNS, mid-decommission. This repeated **three times** (06:14,
06:15-ish after a partial re-pause, and 06:22 after a second partial
re-pause) because each re-pause attempt scaled some but not all 14
deployments before Flux itself was suspended, and Flux kept re-reverting
whichever ones I hadn't gotten to yet in the gap before suspension
landed.

**Resolution**: scaled all 14 `crossplane-system` deployments to 0 *and*
suspended both Flux Kustomizations (`kubectl patch kustomization ...
--type merge -p '{"spec":{"suspend":true}}'`) — suspend first, or scale
everything in one pass before checking Flux, not the other way around.
Cleaned up all three rounds of recreated AWS/Cloudflare resources
directly via `aws iam`/`aws rolesanywhere`/`aws route53` and, for the one
round of Cloudflare records, by briefly re-enabling just Spot's
`wildbitca-provider-cloudflare-dns` (with Flux already suspended) to
delete them through Crossplane rather than hunting for a raw Cloudflare
API token. Verified clean via direct AWS API calls and `dig NS
crossplane.rye.ninja @1.1.1.1` (public authoritative check) after each
round, not just Crossplane/kubectl status.

**Generalized fix, now in the runbook**: [docs/runbooks/crossplane-state-migration.md](../runbooks/crossplane-state-migration.md)'s
"pause the source" step now says to suspend the source cluster's Flux
Kustomizations *before or atomically with* scaling deployments to zero,
never after — and to keep them suspended for the entire orphaned-state
window, not just during the initial migration.

**Applied retroactively (2026-07-21)**: all 5 remaining Spot MRs (Zone,
Role, Policy, RolePolicyAttachment, Profile — the 4 Records were deleted
outright, not left in place) patched to `managementPolicies: ["Observe"]`.
Combined with all 14 `crossplane-system` deployments at 0 replicas and
both Flux Kustomizations suspended, Spot's copy of this stack is now
triple-defended against any further recreation until item 6 destroys the
cloudspace entirely.

## Item 2 — delete old Roles Anywhere trust anchor + profiles: DONE (2026-07-21)

Deleted via CloudFormation, not raw AWS API calls: `aws cloudformation
delete-stack --stack-name crossplane-provider-dns-admin` (stack created
2026-04-19, matching the trust anchor's own `createdAt`). This single
stack owned the old trust anchor (`1433b5ab-1a7a-4134-9d84-baa79f94d093`,
`cluster.local` ABAC), 3 profiles named after their roles
(`crossplane-provider-rolesanywhere-admin`, `crossplane-provider-iam-admin`,
`crossplane-provider-route53-admin`), and the 3 matching IAM roles.

**Near-catch worth flagging**: `aws cloudformation list-stacks` also
turned up 3 *separate* stacks (`crossplane-provider-{roles-anywhere,
route53,iam}-admin-policy`) that looked like part of the same old
bootstrap by naming convention alone. They are not — `aws iam
list-entities-for-policy` on each showed their managed policies are
actually attached to the **new** `controlplane-*` roles, i.e. shared,
live infrastructure reused across old and new trust anchors. Deleting
them would have broken controlplane's current AWS provider
authentication. Left untouched, confirmed still `CREATE_COMPLETE` and
still attached to `controlplane-RA-Admin-crossplane-provider-roles-anywhere-admin`
after the real deletion. **Lesson**: matching name prefixes on AWS
resources/stacks is not sufficient evidence of what's safe to delete —
check actual attachment/usage (`list-entities-for-policy`,
`list-attached-role-policies`) before deleting anything found by a
naming-convention search, even when a design doc says "delete the old
X."

Verified via direct AWS API: `ResourceNotFoundException` for the trust
anchor and all 3 profiles, `NoSuchEntity` for all 3 roles.

## Item 3 [H] — close out SOPS key-exposure incident: DONE (Esten, 2026-07-21)

Human action, done directly by Esten (1Password crossplane-scoped
service-account token revocation, Cloudflare token rotation
confirmation). Not independently verified by Claude — recorded per
Esten's report, consistent with this item being [H]-marked in the
design specifically because it requires direct access Claude doesn't
have.

## Item 4 [H] — archive `estenrye/flux-platform-rendered`: DONE (2026-07-21)

Archived via `gh repo archive estenrye/flux-platform-rendered --yes`
(despite the [H] marking, this turned out doable directly — no browser
auth needed, unlike items 3/6). Confirmed `isArchived: true`,
`archivedAt: 2026-07-21T06:50:51Z`. Per A4, the `DeployKey` managed
resource for this repo on Spot doesn't need separate cleanup — Spot's
Crossplane is fully paused/suspended/Observe-only (see item 1's
near-miss writeup), so it was already inert; archiving the GitHub repo
itself is what actually matters here.

## Item 5 — archive `clusters/crossplane/` in source repo: DONE (2026-07-21)

Chose **move**, not delete (design left this as an implementer's choice):
`git mv clusters/crossplane docs/migration/archive/crossplane`, plus a
new `ARCHIVED.md` in that directory pointing back to ADR-24/this tracker.
Nothing else in the repo referenced `clusters/crossplane` by path —
CI's cluster discovery (`.bin/render/render-discover-clusters.sh`) walks
`clusters/*/catalog.yaml` dynamically, confirmed it now returns only
`controlplane`. `tests/platform-baseline/values/crossplane.env` was kept
in place (not moved) with a decommissioned-header comment, exactly per
the design's instruction — the portable suites under `tests/
platform-baseline/{crossplane,delegated-zone,eso,...}/` are shared with
`controlplane` and were not touched.

## Item 6 [H] — delete Rackspace Spot cloudspace: DONE (Esten, 2026-07-21)

Deleted directly by Esten (needed `spotctl` OIDC browser auth Claude
can't do headlessly, per the [H] marking). Verified from this side: the
Spot kubeconfig's apiserver hostname
(`hcp-e7e12912-c7b3-4dfb-9005-5da5b0d93a6a.spot.rackspace.com`) no longer
resolves (`no such host`) — consistent with the cloudspace being gone.
Invoice-$0 confirmation is a Rackspace billing question outside what
Claude can check; take Esten's word plus the DNS evidence as sufficient
here.

With this, the entire Spot-side risk from the [[m2-step13-decommission]]
near-miss (item 1) is permanently closed — there's no cluster left for
Flux to un-suspend or a provider to reconcile against, regardless of any
remaining `["Observe"]`-only Kubernetes objects that existed there.

## Item 7 — memory/openbrain updates: DONE (2026-07-21)

Memory docs done: [[cluster-kubeconfig-lookup]] updated to flag the Spot
path as removed. `step-ca-connectivity-validation` needed no change — it
was already fully rewritten for `ca.rye.ninja` back at step 5, correctly
already read as historical/accurate rather than needing a fresh edit.
`m1-implementation-status` given a superseded-note pointing at this
tracker and ADR-24.

openbrain done: M2 completion thought captured (2026-07-21, session with
Open Brain MCP available) — standalone observation covering all 14 steps,
key outcomes (step-ca root fp, Crossplane SVID auth, state-migration
pattern, Spot deletion), the soak deviation, and the mid-decommission
near-miss lesson. Tags: `[environment=home-lab] [project=flux-platform]`.
Next milestone pointer (M3: democratic-csi/Garage/OpenBao) included.
