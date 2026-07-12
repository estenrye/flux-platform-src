variable "name" {
  description = "Domain (VM) name, e.g. controlplane-cp-1"
  type        = string
}

variable "vcpu" {
  description = "Number of vCPUs"
  type        = number
}

variable "memory_mb" {
  description = "RAM in MiB"
  type        = number
}

variable "disk_size_bytes" {
  description = "Size of the zvol-backed system disk in bytes"
  type        = number
}

variable "pool" {
  description = "libvirt storage pool (type zfs) for the system disk zvol"
  type        = string
}

variable "iso_path" {
  description = <<-EOT
    Host filesystem path of the Talos factory metal ISO. Attached via the
    provider's file argument: paths ending .iso become a true CDROM device —
    required because Talos ISOs are not isohybrid and only boot via El
    Torito, never as a disk.
  EOT
  type        = string
}

variable "bridge" {
  description = "Host bridge carrying VLAN 100"
  type        = string
}

variable "mac" {
  description = <<-EOT
    Fixed MAC address. Deterministic on purpose: the bootstrap script derives
    each node's maintenance-mode SLAAC address (EUI-64) from this MAC to find
    the node before its static ULA config is applied.
  EOT
  type        = string
}

variable "autostart" {
  description = "Start the domain on host boot"
  type        = bool
  default     = true
}
