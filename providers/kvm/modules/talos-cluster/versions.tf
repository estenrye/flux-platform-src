terraform {
  # provider-terraform (the only caller of this module as of M4 step 1) is
  # frozen at Terraform 1.5.7 and will not adopt newer, BSL-licensed
  # releases -- see docs/memory/m4-design.md D4. Do not use any HCL feature
  # newer than 1.5.7 here (check blocks are fine -- they landed in 1.5.0).
  required_version = ">= 1.5.7"
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
      # Pinned to the mature SDKv2 line, same as providers/kvm/controlplane
      # -- 0.9.x is a full plugin-framework rewrite with an incompatible
      # schema.
      version = "~> 0.8.0"
    }
  }
}
