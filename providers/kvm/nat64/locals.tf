locals {
  network  = yamldecode(file("${path.module}/../network.yaml"))
  versions = yamldecode(file("${path.module}/../versions.yaml"))
  hosts    = yamldecode(file("${path.module}/../hosts.yaml"))

  # M1 is single-host; modules take per-node host indirection so a second
  # host slots in later without redesign (M1 design §3).
  host = local.hosts.hosts[0]

}