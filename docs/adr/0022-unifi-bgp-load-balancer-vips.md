# 22. UniFi BGP Load-Balancer VIPs

Date: 2026-07-12

## Status

Accepted

## Context

On-prem clusters have no cloud load balancer. LoadBalancer Services need
two things: something to *assign* a VIP, and something to make that VIP
*routable* beyond the cluster. The common answer is MetalLB; but the
cluster already runs Calico for CNI and network policy (ADR-17), Calico
≥ 3.30 assigns LoadBalancer IPs natively (LB IPAM), and the UniFi gateway
(UniFi Network 10.5) speaks BGP via FRR. Running MetalLB would add a second
BGP speaker and a second IPAM system for no capability we need.

## Decision

Calico does both halves; the UniFi gateway is the route reflector into the
rest of the network:

- **Assignment**: Calico LB IPAM with two `IPPool`s (`allowedUses:
  [LoadBalancer]`): `lb-internal-ula` (`fd97:45c2:b3a1:100:ffff::/112`,
  site-stable) and `lb-ingress-gua` (`<gua_prefix>:ffff::/112`,
  internet-facing). Services pick a pool via the
  `projectcalico.org/ipPools` annotation.
- **Advertisement**: `BGPConfiguration.serviceLoadBalancerIPs` advertises
  both pools; Calico (AS 64513) peers with the gateway (AS 64512) over
  IPv6. The gateway side is a hand-uploaded FRR config
  (`providers/kvm/unifi-frr.conf`) using **dynamic neighbors** (node BGP
  sessions originate from SLAAC addresses) with inbound prefix filters
  that accept only the two VIP pools and an outbound deny-all.
- **Deliberate exception**: the apiserver VIP is a Talos L2 shared VIP,
  NOT BGP-advertised — cluster management survives BGP being down; other
  VLANs reach it via a static route on the gateway.

## Consequences

- One CNI, one BGP speaker, one IPAM; no MetalLB to operate.
- ULA VIPs never leave the site (gateway filters + no upstream BGP); GUA
  VIPs are internet-routable by design and renumber with the ISP prefix
  (runbook: gua-prefix-renumber).
- The UniFi FRR config is manual and can drift — it lives in git and the
  lb baseline suite proves end-to-end reachability from another VLAN.
- UniFi BGP is a young feature; if it regresses, the fallback is a small
  FRR VM peering with Calico, with no cluster-side changes.
