locals {
  network  = yamldecode(file("${path.module}/../network.yaml"))
  versions = yamldecode(file("${path.module}/../versions.yaml"))
  hosts    = yamldecode(file("${path.module}/../hosts.yaml"))

  # M1 is single-host; modules take per-node host indirection so a second
  # host slots in later without redesign (M1 design §3).
  host = local.hosts.hosts[0]

  talos_version = local.versions.talos.version
  iso_url       = "https://factory.talos.dev/image/${var.schematic_id}/${local.talos_version}/metal-amd64.iso"

  # MAC scheme 52:54:00:b3:a1:<ula-suffix> is deterministic on purpose: the
  # bootstrap script derives each node's maintenance-mode SLAAC (EUI-64)
  # address from the MAC before the static ULA config is applied.
  nodes = merge(
    {
      for name, ula in local.network.allocations.controlplane_nodes : name => {
        role            = "controlplane"
        ula             = ula
        mac             = format("52:54:00:b3:a1:%s", substr(ula, length(ula) - 2, 2))
        vcpu            = 4
        memory_mb       = var.controlplane_memory_mb
        disk_size_bytes = 100 * 1024 * 1024 * 1024
      }
    },
    {
      for name, ula in local.network.allocations.worker_nodes : name => {
        role            = "worker"
        ula             = ula
        mac             = format("52:54:00:b3:a1:%s", substr(ula, length(ula) - 2, 2))
        vcpu            = 4
        memory_mb       = var.worker_memory_mb
        disk_size_bytes = 200 * 1024 * 1024 * 1024
      }
    }
  )
}
