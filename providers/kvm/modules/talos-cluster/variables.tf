variable "cluster_name" {
  description = "Cluster name. Used to namespace this cluster's libvirt image pool/ISO volume so multiple clusters can coexist on one host without collision."
  type        = string
}

variable "schematic_id" {
  description = <<-EOT
    Talos image factory schematic ID. Computed upstream of this module (a
    POST to https://factory.talos.dev/schematics) -- for `controlplane` this
    is `.bin/create-controlplane-cluster.sh`; for a claim-managed cluster
    this is step 2's Talos-bootstrap Job or a composition step. Passed as a
    var so the ID can never drift from whatever schematic definition
    produced it.
  EOT
  type        = string
}

variable "talos_version" {
  description = "Talos release, e.g. v1.13.5."
  type        = string
}

variable "hosts" {
  description = <<-EOT
    KVM host inventory this cluster may schedule VMs onto. List-shaped
    (mirrors providers/kvm/hosts.yaml) so a second host slots in without
    redesign, same precedent as the M1 design. Only index 0 is used as of
    M4 step 1 -- the fleet has one physical KVM host
    (docs/memory/m4-design.md D1); multi-host placement logic is not built
    yet.
  EOT
  type = list(object({
    name        = string
    fqdn        = string
    libvirt_uri = string
    bridge      = string
    # Pre-existing libvirt storage pool (type zfs) for VM system-disk
    # zvols, created by providers/kvm/scripts/prep-kvm-host.sh -- this
    # module consumes it, never creates it.
    vm_pool = string
  }))
  validation {
    condition     = length(var.hosts) > 0
    error_message = "At least one KVM host must be supplied."
  }
}

variable "control_plane_node_ulas" {
  description = "Fully-qualified node name -> ULA, control-plane role. Node names are used as-is for the libvirt domain name -- callers should already include the cluster name, e.g. \"observability-cp-1\" (mirrors providers/kvm/network.yaml's convention)."
  type        = map(string)
  validation {
    condition     = length(var.control_plane_node_ulas) > 0
    error_message = "At least one control-plane node is required."
  }
}

variable "worker_node_ulas" {
  description = "Fully-qualified node name -> ULA, worker role. May be empty -- a cluster can run control-plane-only, with workloads scheduled on the control-plane nodes (Talos `allowSchedulingOnControlPlanes`)."
  type        = map(string)
  default     = {}
}

variable "mac_prefix" {
  description = <<-EOT
    First 5 octets of every node's MAC, formatted "xx:xx:xx:xx:xx". The 6th
    octet is derived per-node from the ULA host part (see locals.tf).
    Nodes across *different* clusters sharing this same prefix (the
    default, and every cluster on this fleet today) must be allocated from
    disjoint ULA-octet ranges by the caller -- this module only checks for
    collisions *within* its own node set, via the "node_mac_octets" check
    block.
  EOT
  type    = string
  default = "52:54:00:b3:a1"
}

variable "reserved_mac_octets" {
  description = "MAC last octets reserved by other fleet infrastructure sharing this bridge (e.g. the NAT64 appliance's 0x64/100) that this cluster's nodes must not collide with."
  type        = list(number)
  default     = [100]
}

variable "control_plane_vcpu" {
  type    = number
  default = 4
}

variable "control_plane_memory_mb" {
  type    = number
  default = 8192
}

variable "control_plane_disk_size_bytes" {
  type    = number
  default = 107374182400 # 100 GiB
}

variable "worker_vcpu" {
  type    = number
  default = 4
}

variable "worker_memory_mb" {
  type    = number
  default = 16384
}

variable "worker_disk_size_bytes" {
  type    = number
  default = 214748364800 # 200 GiB
}
