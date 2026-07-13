locals {
  network  = yamldecode(file("${path.module}/../network.yaml"))
  versions = yamldecode(file("${path.module}/../versions.yaml"))
  hosts    = yamldecode(file("${path.module}/../hosts.yaml"))

  # M1 is single-host; modules take per-node host indirection so a second
  # host slots in later without redesign (M1 design §3).
  host = local.hosts.hosts[0]

  talos_version = local.versions.talos.version
  iso_url       = "https://factory.talos.dev/image/${var.schematic_id}/${local.talos_version}/metal-amd64.iso"

  # MAC scheme 52:54:00:b3:a1:<octet> where <octet> is the ULA host part
  # (hex after "::") parsed as a byte. Deterministic on purpose:
  # create-controlplane-cluster.sh predicts each node's maintenance-mode
  # EUI-64 SLAAC address from the MAC before the static ULA is applied.
  #
  # Parsing (not string-slicing) + %02x formatting makes the octet correct for
  # single-hex suffixes (::a -> "0a", not ":a") and any width; the check block
  # below rejects an allocation that would exceed a byte, collide, or reuse the
  # NAT64 appliance's octet (0x64) — a bad network.yaml fails at plan, not with
  # a duplicate/invalid MAC at domain-define time.
  node_ulas = merge(
    local.network.allocations.controlplane_nodes,
    local.network.allocations.worker_nodes,
  )
  node_mac_octet = { for name, ula in local.node_ulas :
  name => parseint(element(split("::", ula), 1), 16) }
  nat64_mac_octet = 100 # 0x64, the appliance's fixed MAC last octet

  nodes = merge(
    {
      for name, ula in local.network.allocations.controlplane_nodes : name => {
        role            = "controlplane"
        ula             = ula
        mac             = format("52:54:00:b3:a1:%02x", local.node_mac_octet[name])
        vcpu            = 4
        memory_mb       = var.controlplane_memory_mb
        disk_size_bytes = 100 * 1024 * 1024 * 1024
      }
    },
    {
      for name, ula in local.network.allocations.worker_nodes : name => {
        role            = "worker"
        ula             = ula
        mac             = format("52:54:00:b3:a1:%02x", local.node_mac_octet[name])
        vcpu            = 4
        memory_mb       = var.worker_memory_mb
        disk_size_bytes = 200 * 1024 * 1024 * 1024
      }
    }
  )
}

# Fail the plan (not domain-define) on an allocation that would produce an
# invalid, colliding, or NAT64-conflicting node MAC.
check "node_mac_octets" {
  assert {
    condition = alltrue([
      for name, o in local.node_mac_octet :
      o >= 1 && o <= 255 && o != local.nat64_mac_octet
    ])
    error_message = "Each node ULA host part (providers/kvm/network.yaml) must be a single byte 0x01-0xff and not 0x64 (the NAT64 appliance MAC octet)."
  }
  assert {
    condition     = length(values(local.node_mac_octet)) == length(distinct(values(local.node_mac_octet)))
    error_message = "Two node ULAs map to the same MAC last octet — node MACs would collide. Fix allocations in providers/kvm/network.yaml."
  }
}
