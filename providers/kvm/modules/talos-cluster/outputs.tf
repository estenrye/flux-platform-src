output "nodes" {
  description = "Node name -> role/ULA/MAC. M4 step 2's Talos-bootstrap Job derives each node's EUI-64 maintenance-mode SLAAC address from its MAC, the same technique .bin/create-controlplane-cluster.sh uses today."
  value = {
    for name, n in local.nodes : name => {
      role = n.role
      ula  = n.ula
      mac  = n.mac
    }
  }
}

output "talos_iso_url" {
  value = local.iso_url
}

output "schematic_id" {
  description = "Computed once here (data.tf) -- the talos-cluster-bootstrap Job reads this instead of recomputing its own."
  value       = local.schematic_id
}
