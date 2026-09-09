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

  # Optional second NIC (e.g. controlplane's dedicated VLAN 179 BGP-peering
  # segment, kept physically separate from var.bridge's egress traffic --
  # docs/superpowers/specs/2026-09-08-calico-bgp-peering-vlan179-design.md).
  # Omitted by every other caller of this module (e.g. talos-cluster, used
  # by XKubernetesCluster-managed clusters) -- both bridge2 and mac2 default
  # to null, so this block only materializes when a caller opts in.
  #
  # CONFIRMED live 2026-09-08, adding this to all 6 controlplane VMs: when
  # bridge2/mac2 are added to an ALREADY-CREATED domain, dmacvicar/libvirt
  # (tested: v0.8.x line) reports "Modifications complete" and updates state
  # to show both network_interface blocks, but never actually attaches the
  # second NIC to the running OR persistent domain XML (confirmed via `virsh
  # domiflist`/`dumpxml` immediately after a "successful" apply -- only the
  # first interface was present). State then matches config, so a later
  # `tofu plan` shows no drift and never surfaces the gap. The fix that
  # avoids a reboot: `virsh attach-device <domain> <iface.xml> --live
  # --config` by hand, once, per existing VM -- this is ONLY needed for a
  # NIC added to a domain that already existed before the config change;
  # a brand-new domain created with both blocks from the start (e.g. a
  # from-scratch cluster rebuild, or a genuinely new node) attaches both
  # NICs correctly at create time and needs no manual step.
  dynamic "network_interface" {
    for_each = var.bridge2 != null && var.mac2 != null ? [1] : []
    content {
      bridge = var.bridge2
      mac    = var.mac2
    }
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
