# M4 step 3: computes the schematic ID internally instead of taking it as a
# caller-supplied input (see variable "schematic_customization_json"). The
# Talos factory's schematic ID is a deterministic hash of the customization
# document -- same mechanism .bin/create-controlplane-cluster.sh already
# relies on, just moved into Terraform so this module is the single place
# that computes it (the bootstrap Job reads it back via output "schematic_id"
# instead of recomputing it independently).
data "http" "schematic" {
  url             = "https://factory.talos.dev/schematics"
  method          = "POST"
  request_headers = { Content-Type = "application/json" }
  request_body    = var.schematic_customization_json
}

locals {
  schematic_id = jsondecode(data.http.schematic.response_body).id
}
