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

  # Boot fallthrough (empty disk -> ISO) is via per-device boot order
  # elements injected by the XSLT: os-level <boot dev=hd/cdrom> never tries
  # a second virtio disk, and the provider can't express per-disk order.

  disk {
    volume_id = libvirt_volume.system.id
  }

  disk {
    # .iso file paths are attached as a CDROM device by the provider.
    file = var.iso_path
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

  # No ignore_changes on the ISO disk: a new ISO (Talos version bump) rolls
  # the VM deliberately — Talos runs from its system disk after install, so
  # the recreate is a plain reboot from the node's perspective.
}
