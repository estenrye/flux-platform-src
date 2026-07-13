terraform {
  required_version = ">= 1.8.0"
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
      # Pinned to the mature SDKv2 line. 0.9.x is a full plugin-framework
      # rewrite with an incompatible schema — migrating is a deliberate,
      # separate change.
      version = "~> 0.8.0"
    }
  }
}
