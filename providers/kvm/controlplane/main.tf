# Root module for the `controlplane` cluster VMs on the KVM host.
# ZFS pools `vms` and `appliances` are created by scripts/prep-kvm-host.sh
# (human step); this module only consumes them. Talos machine configs are
# applied over the network by .bin/create-controlplane-cluster.sh — never
# through tofu — so no cluster secrets enter tofu state.

# Directory pool for ISO/cloud-init media (zvols are a poor fit for streamed
# media volumes).
resource "libvirt_pool" "images" {
  name = "controlplane-images"
  type = "dir"
  target {
    path = "/var/lib/libvirt/controlplane-images"
  }
}

# Talos factory metal ISO with qemu-guest-agent + iscsi-tools baked in.
# Every Talos VM boots disk-first with this ISO as fallback: an empty disk
# falls through to maintenance mode, an installed disk boots Talos directly.
resource "libvirt_volume" "talos_iso" {
  name   = "talos-${local.talos_version}-${var.schematic_id}.iso"
  pool   = libvirt_pool.images.name
  source = local.iso_url
  format = "raw"
}

module "talos_node" {
  source   = "../modules/talos-vm"
  for_each = local.nodes

  name            = each.key
  vcpu            = each.value.vcpu
  memory_mb       = each.value.memory_mb
  disk_size_bytes = each.value.disk_size_bytes
  pool            = "vms"
  iso_volume_id   = libvirt_volume.talos_iso.id
  bridge          = local.host.bridge
  mac             = each.value.mac
}

module "nat64" {
  source = "../modules/nat64-appliance"

  cloudinit_pool     = libvirt_pool.images.name
  base_image_path    = var.nat64_image_path
  bridge             = local.host.bridge
  mac                = "52:54:00:b3:a1:64"
  ula_address        = "${local.network.allocations.nat64_appliance.ula}/64"
  ipv4_address       = local.network.allocations.nat64_appliance.ipv4
  ipv4_gateway       = local.network.vlan100.ipv4_gateway
  tayga_pool_cidr    = local.network.allocations.nat64_appliance.tayga_pool
  nat64_prefix       = local.network.allocations.nat64_appliance.nat64_prefix
  dns64_allowed_cidr = local.network.ula_prefix

  authorized_ssh_keys = var.nat64_authorized_ssh_keys
}
