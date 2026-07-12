terraform {
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
    }
  }
}

# Empty zvol system disk. Talos installs itself here from the ISO on first
# boot (maintenance mode -> talosctl apply-config, driven by
# .bin/create-controlplane-cluster.sh). Machine configs are applied over the
# network, never through tofu, so no cluster secrets enter tofu state.
resource "libvirt_volume" "system" {
  name   = "${var.name}-system"
  pool   = var.pool
  size   = var.disk_size_bytes
  format = "raw"
}

resource "libvirt_domain" "vm" {
  name      = var.name
  vcpu      = var.vcpu
  memory    = var.memory_mb
  autostart = var.autostart

  cpu {
    mode = "host-passthrough"
  }

  # Empty disk has no bootloader, so firmware falls through to the ISO
  # (maintenance mode). Once Talos is installed, the disk boots directly and
  # the ISO is inert — no detach step needed on rebuilds.
  boot_device {
    dev = ["hd", "cdrom"]
  }

  disk {
    volume_id = libvirt_volume.system.id
  }

  disk {
    volume_id = var.iso_volume_id
  }

  network_interface {
    bridge = var.bridge
    mac    = var.mac
  }

  console {
    type        = "pty"
    target_port = "0"
  }

  # virtio memballoon and the qemu-guest-agent channel are added by
  # libvirt/the provider; the XSLT only marks the ISO disk read-only.
  xml {
    xslt = file("${path.module}/guest-agent-channel.xsl")
  }

  lifecycle {
    # A reprovisioned ISO volume must not force VM replacement; Talos runs
    # from disk after install.
    ignore_changes = [disk[1]]
  }
}
