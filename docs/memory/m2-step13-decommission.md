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

## Item 2 — delete old Roles Anywhere trust anchor + profiles

Status: not started.

## Item 3 [H] — close out SOPS key-exposure incident

Status: not started. Human action (1Password token revocation).

## Item 4 [H] — archive `estenrye/flux-platform-rendered`

Status: not started.

## Item 5 — archive `clusters/crossplane/` in source repo

Status: not started.

## Item 6 [H] — delete Rackspace Spot cloudspace

Status: not started. Needs `spotctl` OIDC browser login (same blocker
pattern as the kubeconfig refresh earlier in this session).

## Item 7 — memory/openbrain updates

Status: not started. `cluster-kubeconfig-lookup` (Spot path removal),
`step-ca-connectivity-validation` rewrite, openbrain
`environment=home-lab`/`project=flux-platform`.
