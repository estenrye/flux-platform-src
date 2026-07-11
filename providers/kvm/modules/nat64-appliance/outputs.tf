output "name" {
  value = libvirt_domain.vm.name
}

output "ula_address" {
  description = "Resolver/NAT64 next-hop address the cluster points at"
  value       = split("/", var.ula_address)[0]
}
