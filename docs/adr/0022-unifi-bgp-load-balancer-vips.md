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

## Amendment 2026-07-15 (routed VIP subnets)

Both VIP pool CIDRs above are stale — carving them from VLAN-100's on-link
`/64`s (the original `lb-internal-ula` and `lb-ingress-gua` values) turned
out to be a genuine bug, not a stylistic choice. Full design:
[2026-07-15-services-network-design.md](../superpowers/specs/2026-07-15-services-network-design.md).

- **Symptom**: clients on VLAN 100 NDP'd for VIP addresses instead of
  routing via the gateway (the addresses looked on-link), and got no
  answer.
- **Root cause, found going deeper during the fix**: the bug wasn't
  limited to clients. The UniFi gateway itself silently drops BGP-learned
  routes whose prefix is numerically nested inside one of its own
  connected VLAN subnets — its firewall/zone classification (ipset
  membership keyed on the connected `/64`) doesn't distinguish "on-link
  host" from "routed sub-block," so the route resolves in the BGP RIB and
  kernel FIB but the packet is never actually delivered onto the wire.
  Moving the client off VLAN 100 didn't fix this — only relocating the
  pools did.
- **Fix**: two new pools, `lb-internal-ula-routed`
  (`fd97:45c2:b3a1:f00::/112`) and `lb-ingress-gua-routed`
  (`2607:3640:1064:27f::/112`, a spare `/64` carved from the confirmed
  `/60` PD — see ADR-23 amendment), on prefixes that belong to no VLAN, no
  RA, on-link nowhere. Calico's `IPPool.spec.cidr` is immutable, so this
  was a new-pool-plus-disable-old swap, not an in-place edit — the
  original `lb-internal-ula`/`lb-ingress-gua` pools still exist, disabled,
  pending deletion (docs/memory/vip-renumber-flakiness-investigation.md).
- **Separate, unrelated bug found during validation**: Calico advertises
  a LoadBalancer service's BGP host route from every node regardless of
  `externalTrafficPolicy: Local` endpoint locality (this cluster is on
  v3.32.1; the closest matching upstream issues,
  projectcalico/calico#6074 and #8162, were reportedly fixed by v3.25/
  v3.30, and a v3.30.5 report, #11540, was closed "not planned" — no
  known-good version to upgrade to). Effect: only the ECMP path landing on
  the node with the actual backend pod works; the rest silently drop.
  Mitigated, not fixed, by spreading one Envoy replica onto every node
  (required pod anti-affinity + a control-plane taint toleration) so every
  possible ECMP next-hop has a working local endpoint. This applies to any
  future `externalTrafficPolicy: Local` LoadBalancer Service on this
  cluster, not just Envoy.
