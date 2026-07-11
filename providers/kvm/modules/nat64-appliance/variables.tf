variable "name" {
  description = "Domain (VM) name"
  type        = string
  default     = "nat64-01"
}

variable "vcpu" {
  type    = number
  default = 1
}

variable "memory_mb" {
  type    = number
  default = 1024
}

variable "disk_size_bytes" {
  description = "System disk size in bytes (design: 10 GB)"
  type        = number
  default     = 10737418240
}

variable "pool" {
  description = "libvirt storage pool (type zfs) for the system disk zvol"
  type        = string
}

variable "cloudinit_pool" {
  description = "Directory-type pool for the cloud-init ISO"
  type        = string
}

variable "base_image_path" {
  description = "Local path to the Ubuntu cloud image converted to RAW (see .bin/create-controlplane-cluster.sh)"
  type        = string
}

variable "bridge" {
  description = "Host bridge carrying VLAN 100"
  type        = string
}

variable "mac" {
  description = "Fixed MAC address (netplan matches on it)"
  type        = string
}

variable "ula_address" {
  description = "Static ULA address with prefix length, e.g. fd97:45c2:b3a1:100::64/64"
  type        = string
}

variable "ipv4_address" {
  description = "Static IPv4 with prefix length for translated egress, e.g. 10.45.0.64/16"
  type        = string
}

variable "ipv4_gateway" {
  description = "VLAN 100 IPv4 gateway"
  type        = string
}

variable "tayga_pool_cidr" {
  description = "Private dynamic IPv4 pool tayga maps v6 flows into"
  type        = string
  default     = "192.168.255.0/24"
}

variable "nat64_prefix" {
  description = "NAT64 translation prefix"
  type        = string
  default     = "64:ff9b::/96"
}

variable "dns64_allowed_cidr" {
  description = "IPv6 CIDR allowed to query the DNS64 resolver (site ULA /48 covers nodes, pods, services)"
  type        = string
}

variable "authorized_ssh_keys" {
  description = "SSH public keys for the break-glass admin user on the appliance"
  type        = list(string)
  default     = []
}
