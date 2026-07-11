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

# RAW Ubuntu cloud image uploaded into the zvol. `size` > source size grows
# the volume; cloud-init growpart expands the root filesystem on first boot.
resource "libvirt_volume" "system" {
  name   = "${var.name}-system"
  pool   = var.pool
  source = var.base_image_path
  size   = var.disk_size_bytes
  format = "raw"
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
