# providers/kvm/modules/talos-cluster — reusable Talos-on-KVM cluster module

Generalized, root-agnostic Terraform module that creates the VMs for one
Talos cluster (control-plane + optional worker node pools) on the fleet's
KVM host inventory, and boots the Talos factory ISO. Introduced in M4 step 1
([design doc](../../../docs/superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md),
[[m4-design]] / [[m4-step-tracker]] in `docs/memory/`) as the module
`provider-terraform` instantiates per `XKubernetesCluster` claim (M4 step 3).

This module intentionally does **not**:
- Declare a `provider "libvirt" {}` block or a Terraform state backend —
  it's a called module, not a root module. When invoked through
  `provider-terraform`, both are injected by that provider's
  `ProviderConfig.spec.configuration` (see
  `applications/crossplane-providers/provider-terraform/provider-config/`).
- Generate or apply Talos machine configs, or bootstrap etcd/kubeconfig —
  that's M4 step 2's Talos-bootstrap `Job`. Talos machine secrets never
  enter Terraform state, the same invariant `providers/kvm/controlplane`
  keeps today by doing this over the network via `talosctl` instead of
  through tofu.

`providers/kvm/controlplane/` (the existing hand-rolled root module for the
`controlplane` cluster) is **not** migrated onto this module and stays
as-is — the control plane cluster is script-bootstrapped, the spec's stated
exception (§5.3), not claim-managed. `providers/kvm/modules/talos-vm/` (the
single-VM leaf module both root modules call) is unchanged and shared by
both.

## Inputs worth knowing before calling this module

- `hosts`: only index 0 is used today — one physical KVM host exists for
  the whole fleet (`docs/memory/m4-design.md` D1); multi-host placement
  logic isn't built yet.
- `control_plane_node_ulas` / `worker_node_ulas`: caller-resolved node
  name → ULA maps. Keys are used as-is for the libvirt domain name, so
  callers must already qualify them (e.g. `observability-cp-1`), mirroring
  `providers/kvm/network.yaml`'s convention. `worker_node_ulas` may be
  empty — Talos supports control-plane-only clusters
  (`allowSchedulingOnControlPlanes`).
- `mac_prefix` / `reserved_mac_octets`: every node's MAC is
  `<mac_prefix>:<octet>`, `<octet>` derived from its ULA host part. The
  `check "node_mac_octets"` block only guards against collisions *within*
  one cluster's own node set — if two clusters share a host and the
  default `mac_prefix`, the caller (the composition, per-claim) is
  responsible for allocating disjoint ULA-octet ranges across clusters.

Network/VIP allocation (subnet, BGP ASN, apiserver VIP) is deliberately
**not** an input here — it's resolved at the composition layer (M4 step 3)
and handed to the Talos-bootstrap Job directly, since this module has no
use for it beyond what already flows through the node ULA maps.
