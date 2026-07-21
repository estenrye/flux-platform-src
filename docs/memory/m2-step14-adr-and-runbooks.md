---
name: m2-step14-adr-and-runbooks
description: M2 step 14 paper trail drafted 2026-07-21 — migration ADR-24, ADR-15/ADR-20 amendments, generalized state-migration runbook
metadata:
  type: project
---

Per [M2 design](../superpowers/specs/2026-07-13-m2-migration-design.md)
§6 step 14: drafted the migration ADR and the reusable state-migration
runbook ahead of decommission, since both were fully derivable from work
already done (steps 8 and 11) and don't need to wait on the soak window.

**What landed (commit on `m2-spot-migration`, not yet pushed as of
2026-07-21):**

- [ADR-24](../adr/0024-m2-control-plane-service-migration-off-spot.md) —
  the migration decision record. Status is intentionally "Accepted —
  execution in progress": steps 0-11 done, 12/13 (go/no-go, decommission)
  still pending the soak window closing (~2026-07-28). Update this ADR
  (not a new one) when decommission actually completes.
- [ADR-15 amendment](../adr/0015-secret-and-certificate-rotation-strategy.md#amendment-2026-07-21-fresh-offline-root-on-controlplane-m2) —
  revised SPIFFE-CA rotation cadence for `controlplane` (10y root by
  ceremony only, 1y intermediate annual/by-drill), replacing the old
  90-day cert-manager-auto-rotated model the ADR originally described.
- [ADR-20 amendment](../adr/0020-control-plane-on-talos-on-kvm.md#amendment-2026-07-21-step-ca-root-was-not-preserved--corrects-the-line-above) —
  corrects a stale line ("step-ca root preserved") that M2's actual A1
  decision (fresh root) contradicted; ADR-20 was written before the M0
  audit ran.
- [docs/runbooks/crossplane-state-migration.md](../runbooks/crossplane-state-migration.md) —
  generalizes [[m2-step8-delegated-zone-migration]]'s procedure into a
  reusable 5-phase pattern (recon → orphan-protect+pause → export+diff →
  import+observe-not-create → restore management or roll back) for M6+
  cloud-substrate migrations, with the managementPolicies and
  batch-command-classifier gotchas folded in.

**Deliberately not done yet:** the design's step 14 also lists
"memory/openbrain updates" as a deliverable, but per §5 step 7 of the
design those specific updates (`cluster-kubeconfig-lookup` losing the
Spot path, `step-ca-connectivity-validation` rewritten, openbrain
`environment=home-lab`/`project=flux-platform`) are decommission-gated —
they'd be wrong to make before Spot is actually gone. The per-step memory
docs ([[m2-step8-delegated-zone-migration]], [[m2-step11-restore-drill]],
this one) are the step-14 memory updates that *can* happen now.

See also [[m2-change-freeze]] for the current soak/freeze status this
all sits inside.
