---
name: m4-network-architecture-no-isolation-requirement
description: Cluster VLANs don't need L2/firewall-zone isolation from each other at this time; VLAN 200 (observability) exists to fix the ICMPv6 hairpin bug, not for isolation
metadata:
  type: project
---

Esten does not require L2/firewall-zone isolation between cluster VLANs at
this time (confirmed 2026-08-06). `observability`'s dedicated VLAN 200 was
provisioned specifically to fix the ICMPv6 hairpin-routing bug (see
`177da4d`) — the bug was caused by a static route for a subnet nested/layered
on top of an already-connected bridge (UniFi's firewall/zone classification
can't distinguish an on-link host from a routed sub-block), not by two
clusters sharing a VLAN or subnet. Isolation between clusters was never the
design goal for the VLAN split.

**Why:** Came up while evaluating options for giving `observability` real
IPv6 internet egress (it currently only has NAT64-reachable IPv4 egress, no
GUA). One option — deploying a cluster on VLAN 100 with the *same* ULA and
GUA subnet as `controlplane`, using BGP (Calico) to advertise per-cluster
pod/service CIDRs for isolation instead of a VLAN boundary — was initially
weighed down for "losing L2 isolation," which the user corrected as not a
real cost given their actual priorities. Also relevant:
[[feedback-dont-inflate-tradeoff-costs]].

**How to apply:** Future network-architecture proposals for this repo can
default to sharing VLAN 100 (and its real GUA-via-PD capacity — confirmed
14 spare `/64`s in the PD block beyond what VLAN 100/101 use, ADR-23) rather
than assuming each new cluster needs its own dedicated VLAN for isolation.
Reserve per-cluster VLANs for cases with an actual stated isolation need, or
where a distinct subnet is otherwise required — not as a default. If a
future change reintroduces isolation as a goal (e.g. before exposing a
cluster beyond the LAN), revisit this.
