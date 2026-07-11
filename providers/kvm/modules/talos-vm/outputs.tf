output "name" {
  value = libvirt_domain.vm.name
}

output "mac" {
  description = "Fixed MAC; the bootstrap script derives the EUI-64 SLAAC maintenance address from it"
  value       = var.mac
}
