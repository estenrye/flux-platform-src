variable "schematic_id" {
  description = <<-EOT
    Talos image factory schematic ID. Computed from the schematic definition
    in ../versions.yaml by .bin/create-controlplane-cluster.sh (POST to
    https://factory.talos.dev/schematics is deterministic). Passed as a var so
    the ID can never drift from the committed schematic definition.
  EOT
  type        = string
}

variable "controlplane_memory_mb" {
  type    = number
  default = 8192
}

variable "worker_memory_mb" {
  description = "Worker RAM. Drop to 12288 if host memory pressure appears (M1 design §7.3 mitigation)"
  type        = number
  default     = 16384
}
