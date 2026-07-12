# 23. IPv6-Only Cluster with ULA Internal Addressing and NAT64

Date: 2026-07-12

## Status

Accepted

## Context

Dual-stack clusters carry two address families through every layer — CNI
pools, services, policies, BGP, DNS — doubling configuration surface and
failure modes. The home lab has working IPv6 (delegated GUA prefix via
TFiber), but the delegated prefix can be renumbered by the ISP at any
time, and critical dependencies (github.com, ghcr.io) still publish no
AAAA records. UniFi 10.5 has no native NAT64.

## Decision

The `controlplane` cluster is **IPv6-only**, with a two-tier addressing
model and a NAT64/DNS64 appliance for the v4-only internet:

- **ULA is identity** (`fd97:45c2:b3a1::/48`, RFC 4193): node addresses,
  etcd, the apiserver VIP, pod/service CIDRs, internal LB VIPs, and
  storage paths to the NAS — all site-stable and immune to ISP
  renumbering.
- **GUA is reachability**: SLAAC addresses for v6 internet egress and the
  ingress VIP pool. Everything GUA derives from a single `gua_prefix`
  variable (`providers/kvm/network.yaml`); a renumber is one variable, a
  re-render, and the FRR config (runbook: gua-prefix-renumber).
- **NAT64/DNS64**: a minimal Ubuntu VM (`nat64-01`) running Tayga
  (userspace, apt-packaged — chosen over Jool to avoid an out-of-tree
  kernel module) plus unbound DNS64. Nodes resolve through it and route
  `64:ff9b::/96` to it. It is the single deliberate dual-stack exception.
- **No IPv4 anywhere on cluster nodes.**

## Consequences

- One address family through CNI, policy, BGP, and DNS; the network
  baseline suite asserts v6-only pod IPs.
- The appliance is a SPOF whose blast radius is only v4-only egress
  (GitHub/ghcr pulls); it is rebuildable from cloud-init in minutes, with
  a break-glass side-load path (runbook: nat64-appliance-rebuild). It
  retires with zero cluster changes if UniFi ships NAT64 or GitHub ships
  AAAA.
- CI runners (GitHub-hosted, IPv4-only) can never reach the cluster
  directly — render pipelines push to GitHub, and Flux pulls from inside.
- Anything terminating raw mTLS for v4-only clients cannot hide behind
  Cloudflare's proxy (it terminates TLS); that decision is deferred to the
  first out-of-LAN consumer (M5/M6).
