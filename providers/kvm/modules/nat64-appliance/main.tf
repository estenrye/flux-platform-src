terraform {
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
    }
  }
}

locals {
  tayga_pool_gw = cidrhost(var.tayga_pool_cidr, 1) # tayga's own v4 tunnel address
}

# RAW Ubuntu cloud image as a file-backed volume in the images dir pool:
# zvol-backed volumes hit a libvirt/udev race on upload (device node not yet
# present), and the appliance is cattle — file backing is fine.
#
# Two-step because the provider forbids size+source together: `base` is a
# plain import of the cloud image at its native size (~3.5G), and `system`
# is a sized clone of it (base_volume_id + size IS allowed together) so
# cloud-init growpart has real room to expand the root fs into instead of
# just the base image's own unused slack (M0-era bug — the single-volume
# form left ~2.4G of actual root fs after /boot + /boot/efi, which
# unattended-upgrades filled and broke unbound; found live 2026-08-15,
# see docs/runbooks/nat64-appliance-rebuild.md).
resource "libvirt_volume" "system_base" {
  name   = "${var.name}-system-base"
  pool   = var.cloudinit_pool
  source = var.base_image_path
  format = "raw"
}

resource "libvirt_volume" "system" {
  name           = "${var.name}-system"
  pool           = var.cloudinit_pool
  base_volume_id = libvirt_volume.system_base.id
  size           = var.disk_size_bytes
  # qcow2, not raw: libvirt only supports a backing-store reference
  # (base_volume_id) on formats that record one in their own file structure.
  # Raw files have no such header, so pairing base_volume_id with format =
  # "raw" is rejected by the storage backend ("backing storage not
  # supported for raw volumes") — found live 2026-08-23 on the first
  # rebuild to actually exercise this path.
  format = "qcow2"
}

resource "libvirt_cloudinit_disk" "seed" {
  name = "${var.name}-cloudinit.iso"
  pool = var.cloudinit_pool
  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    hostname            = var.name
    mac                 = var.mac
    ula_address         = var.ula_address
    ipv4_address        = var.ipv4_address
    ipv4_gateway        = var.ipv4_gateway
    tayga_pool_cidr     = var.tayga_pool_cidr
    tayga_pool_gw       = local.tayga_pool_gw
    nat64_prefix        = var.nat64_prefix
    dns64_allowed_cidr  = var.dns64_allowed_cidr
    lan_forward_domain  = var.lan_forward_domain
    lan_dns_addr        = var.lan_dns_addr
    authorized_ssh_keys = var.authorized_ssh_keys
  })
  meta_data = <<-EOT
    instance-id: ${var.name}
    local-hostname: ${var.name}
  EOT
  # Delivered as cloud-init network config (not write_files): VLAN 100 has no
  # DHCP, so cloud-init's default DHCP fallback would stall first boot.
  # Dual-stack is this VM's deliberate exception: static ULA + static IPv4 for
  # translated egress; GUA + v6 default route arrive via accept-ra (SLAAC).
  network_config = <<-EOT
    version: 2
    ethernets:
      lan:
        match:
          macaddress: "${var.mac}"
        set-name: lan
        dhcp4: false
        dhcp6: false
        accept-ra: true
        addresses:
          - "${var.ula_address}"
          - "${var.ipv4_address}"
        routes:
          - to: default
            via: ${var.ipv4_gateway}
        nameservers:
          addresses: [1.1.1.1, 9.9.9.9]
  EOT
}

resource "libvirt_domain" "vm" {
  name      = var.name
  vcpu      = var.vcpu
  memory    = var.memory_mb
  autostart = true
  cloudinit = libvirt_cloudinit_disk.seed.id

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.system.id
  }

  network_interface {
    bridge = var.bridge
    mac    = var.mac
  }

  console {
    type        = "pty"
    target_port = "0"
  }
}
