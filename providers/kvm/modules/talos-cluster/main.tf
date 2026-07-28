# Reusable root-agnostic module: creates the VMs for one Talos-on-KVM
# cluster and boots the Talos factory ISO. Deliberately does not:
#   - declare a `provider "libvirt" {}` block (this is a *called* module,
#     not a standalone root module -- the provider config + state backend
#     are injected by the caller: for a claim-managed cluster that's
#     provider-terraform's ProviderConfig.spec.configuration, see
#     applications/crossplane-providers/provider-terraform/provider-config/
#     and docs/memory/m4-design.md D4)
#   - generate or apply Talos machine configs, or bootstrap etcd (that's
#     M4 step 2's Talos-bootstrap Job -- machine secrets never enter
#     Terraform state, same invariant providers/kvm/controlplane keeps by
#     doing this over the network via talosctl instead)
#
# This is a generalized port of providers/kvm/controlplane/{main,locals,
# variables,outputs}.tf -- that module stays as-is (controlplane is
# script-bootstrapped, the spec's stated exception, not claim-managed) and
# is not migrated onto this one.

resource "libvirt_pool" "images" {
  name = "${var.cluster_name}-images"
  type = "dir"
  target {
    path = "/var/lib/libvirt/${var.cluster_name}-images"
  }
}

# Talos factory metal ISO with the pinned schematic baked in. Every Talos
# VM boots disk-first with this ISO as fallback: an empty disk falls
# through to maintenance mode, an installed disk boots Talos directly.
resource "libvirt_volume" "talos_iso" {
  name   = "talos-${var.talos_version}-${var.schematic_id}.iso"
  pool   = libvirt_pool.images.name
  source = local.iso_url
  format = "raw"
}

module "talos_node" {
  source   = "../talos-vm"
  for_each = local.nodes

  name            = each.key
  vcpu            = each.value.vcpu
  memory_mb       = each.value.memory_mb
  disk_size_bytes = each.value.disk_size_bytes
  pool            = local.host.vm_pool
  iso_path        = libvirt_volume.talos_iso.id
  bridge          = local.host.bridge
  mac             = each.value.mac
}
