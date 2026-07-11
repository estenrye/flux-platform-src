provider "libvirt" {
  # qemu+ssh with the automation-user key from ssh-agent (host inventory in
  # ../hosts.yaml).
  uri = local.host.libvirt_uri
}
