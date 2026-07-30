locals {
  # Single-host fleet as of M4 step 1 -- see variable "hosts" doc in
  # variables.tf and docs/memory/m4-design.md D1.
  host = var.hosts[0]

  iso_url = "https://factory.talos.dev/image/${local.schematic_id}/${var.talos_version}/metal-amd64.iso"

  # MAC scheme "<mac_prefix>:<octet>" where <octet> is the ULA host part
  # (hex after "::") parsed as a byte -- same deterministic scheme as
  # providers/kvm/controlplane/locals.tf, generalized to a caller-supplied
  # prefix. Parsing (not string-slicing) + %02x formatting makes the octet
  # correct for single-hex suffixes (::a -> "0a", not ":a") and any width;
  # the check block below rejects an allocation that would exceed a byte,
  # collide, or reuse a reserved octet -- a bad allocation fails at plan,
  # not with a duplicate/invalid MAC at domain-define time.
  node_ulas = merge(var.control_plane_node_ulas, var.worker_node_ulas)
  node_mac_octet = { for name, ula in local.node_ulas :
  name => parseint(element(split("::", ula), 1), 16) }

  nodes = merge(
    {
      for name, ula in var.control_plane_node_ulas : name => {
        role            = "controlplane"
        ula             = ula
        mac             = format("%s:%02x", var.mac_prefix, local.node_mac_octet[name])
        vcpu            = var.control_plane_vcpu
        memory_mb       = var.control_plane_memory_mb
        disk_size_bytes = var.control_plane_disk_size_bytes
      }
    },
    {
      for name, ula in var.worker_node_ulas : name => {
        role            = "worker"
        ula             = ula
        mac             = format("%s:%02x", var.mac_prefix, local.node_mac_octet[name])
        vcpu            = var.worker_vcpu
        memory_mb       = var.worker_memory_mb
        disk_size_bytes = var.worker_disk_size_bytes
      }
    }
  )
}

# Fail the plan (not domain-define) on an allocation that would produce an
# invalid, colliding, or reserved-octet-conflicting node MAC.
check "node_mac_octets" {
  assert {
    condition = alltrue([
      for name, o in local.node_mac_octet :
      o >= 1 && o <= 255 && !contains(var.reserved_mac_octets, o)
    ])
    error_message = "Each node ULA host part must be a single byte 0x01-0xff and must not collide with reserved_mac_octets (e.g. the NAT64 appliance)."
  }
  assert {
    condition     = length(values(local.node_mac_octet)) == length(distinct(values(local.node_mac_octet)))
    error_message = "Two node ULAs map to the same MAC last octet within this cluster's own node set -- node MACs would collide."
  }
}
