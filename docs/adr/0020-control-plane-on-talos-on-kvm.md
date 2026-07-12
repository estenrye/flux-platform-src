# 20. Control Plane on Talos-on-KVM

Date: 2026-07-12

## Status

Accepted

Supersedes the *placement* decision of [ADR-3](0003-bootstrapping-the-crossplane-controlplane-cluster.md)
(Rackspace Spot); the bootstrapping principles in ADR-3 remain valid.

## Context

The fleet control plane (Crossplane, Flux, step-ca — trust domain root for
the platform) has run on a Rackspace Spot cloudspace. Spot's availability
history has been poor for a control plane that everything else depends on:
the M0 baseline audit recorded a public CA endpoint observed at ~25%
availability over a sample window, and spot preemption is by definition
outside our control. Meanwhile a capable home lab host (`mf-ms-a2-01`,
16c/32t, 64 GB, 10 GbE, mirrored NVMe) sits on a network with a better
observed availability record.

A control plane host must be boring, reproducible, and rebuildable. Pet VMs
with mutable OS state are how homelab clusters rot.

## Decision

Run the fleet control plane as the `controlplane` cluster (trust domain
`controlplane.rye.ninja`): Talos Linux VMs on KVM/libvirt on `mf-ms-a2-01`,
provisioned by OpenTofu (`providers/kvm/`), bootstrapped by
`.bin/create-controlplane-cluster.sh`.

- Talos is API-only and image-based: no SSH, no shell, no config drift;
  machine secrets are SOPS-encrypted in git, so teardown/rebuild preserves
  cluster identity.
- The cluster is script-bootstrapped ("pet by script, cattle by parts") —
  it is NOT self-managed by Crossplane; it is the thing that runs Crossplane.
- 3 control plane VMs + 3 workers, RAM deliberately over-committed on the
  single host (balloon + KSM + capped ZFS ARC); the single-host SPOF is
  accepted and bounded by etcd snapshots, SOPS-encrypted secrets, and ZFS
  replication (DR posture in the M1 design).
- Control plane services migrate from Spot in M2 (parallel run, step-ca
  root preserved, Spot decommissioned last).

## Consequences

- Control plane availability is now bounded by home power/ISP rather than
  spot-market preemption; a second KVM host can be added without redesign
  (tofu takes a host list).
- Upgrades become deliberate: Talos version pinned in
  `providers/kvm/versions.yaml`, rolled per runbook.
- The apiserver endpoint is a Talos L2 shared VIP on ULA — cluster
  management works even when BGP or the ISP is down.
- Rackspace Spot remains only until M2 completes; its cluster's ADRs and
  variants (e.g. `global-network-policy-default-deny/rackspace-spot`)
  retire with it.
