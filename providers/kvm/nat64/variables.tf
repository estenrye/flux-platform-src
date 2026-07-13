
variable "nat64_image_path" {
  description = "Local path to the Ubuntu cloud image converted to RAW (downloaded/converted by .bin/create-controlplane-cluster.sh)"
  type        = string
}

variable "nat64_authorized_ssh_keys" {
  description = "Break-glass SSH public keys for the NAT64 appliance admin user"
  type        = list(string)
  default     = []
}
