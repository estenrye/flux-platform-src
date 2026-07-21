# Archived: `crossplane` cluster (Rackspace Spot)

This directory is the former `clusters/crossplane/` Flux cluster entry,
moved here at M2 decommission (2026-07-21) rather than deleted, so the
manifests remain available for historical reference. It is no longer a
live render target — CI's cluster discovery
(`.bin/render/render-discover-clusters.sh`) only looks under `clusters/`,
so this tree is inert by its new location alone.

Do not resurrect this by moving it back. The cluster it described —
Rackspace Spot, cloudspace `crossplane-controlplane-cluster` — was
deleted as part of the same decommission (M2 design §5, execution step
13). Its services live on `controlplane` now.

See:

- [ADR-24: M2 Control Plane Service Migration off Rackspace Spot](../../adr/0024-m2-control-plane-service-migration-off-spot.md)
- [M2 design](../../superpowers/specs/2026-07-13-m2-migration-design.md)
- [docs/memory/m2-step13-decommission.md](../../memory/m2-step13-decommission.md)
- [docs/migration/m2-spot-migration-inventory.md](../m2-spot-migration-inventory.md) —
  the pre-migration resource snapshot this cluster entry corresponds to
