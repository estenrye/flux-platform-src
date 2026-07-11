output "nodes" {
  description = "Node name -> role/ULA/MAC (bootstrap script derives EUI-64 maintenance addresses from the MACs)"
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

output "nat64_address" {
  value = module.nat64.ula_address
}

output "apiserver_vip" {
  value = local.network.allocations.apiserver_vip
}
