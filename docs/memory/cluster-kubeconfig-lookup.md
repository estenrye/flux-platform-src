---
name: cluster-kubeconfig-lookup
description: Authoritative source for cluster kubeconfig paths is clusters/<name>/catalog.yaml rye.ninja/kubeconfig annotation
metadata:
  type: reference
---

# Cluster Kubeconfig Lookup

The authoritative source for which kubeconfig file to use to connect to a cluster is the `rye.ninja/kubeconfig` annotation in `clusters/<cluster-name>/catalog.yaml`.

For example, `controlplane` uses:

```sh
export KUBECONFIG=~/.kube/homelab/controlplane.yaml
```

as documented in `clusters/controlplane/catalog.yaml`.

**Spot removed 2026-07-21 (M2 decommission)**: the `crossplane` cluster
entry (`~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml`)
no longer applies — the Rackspace Spot cloudspace was deleted and
`clusters/crossplane/` moved to
`docs/migration/archive/crossplane/`. Its `catalog.yaml` still exists
there for historical reference but is no longer a valid lookup target;
the cloudspace's apiserver hostname no longer resolves. See
[[m2-step13-decommission]] and [ADR-24](../adr/0024-m2-control-plane-service-migration-off-spot.md).
