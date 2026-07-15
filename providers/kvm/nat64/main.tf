# Root module for the NAT64/DNS64 appliance (nat64-01).
#
# Deliberately SEPARATE from the controlplane cluster root module: the
# appliance is shared, long-lived infrastructure that the IPv6-only cluster
# depends on to reach IPv4-only endpoints (factory.talos.dev, ghcr.io). The
# cluster is cattle — created and destroyed freely — and must NOT take the
# appliance down with it (which would also cut the workstation's own path to
# factory/ghcr during a rebuild). Each root module owns its own libvirt dir
# pool so `tofu destroy` on one never removes media the other needs.

resource "libvirt_pool" "images" {
  name = "nat64-images"
  type = "dir"
  target {
    path = "/var/lib/libvirt/nat64-images"
  }
}

module "nat64" {
  source = "../modules/nat64-appliance"

  # System disk + cloud-init both live in this dir pool (file-backed: the
  # zvol upload path races udev, and the appliance is cattle).
  cloudinit_pool = libvirt_pool.images.name

  base_image_path    = var.nat64_image_path
  bridge             = local.host.bridge
  mac                = "52:54:00:b3:a1:64"
  ula_address        = "${local.network.allocations.nat64_appliance.ula}/64"
  ipv4_address       = local.network.allocations.nat64_appliance.ipv4
  ipv4_gateway       = local.network.vlan100.ipv4_gateway
  tayga_pool_cidr    = local.network.allocations.nat64_appliance.tayga_pool
  nat64_prefix       = local.network.allocations.nat64_appliance.nat64_prefix
  dns64_allowed_cidr = local.network.ula_prefix
  lan_forward_domain = "rye.ninja"
  lan_dns_addr       = local.network.vlan100.ipv6_gateway_ula

  authorized_ssh_keys = var.nat64_authorized_ssh_keys
}
