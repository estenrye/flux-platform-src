# 28. VLAN 100 On-Link Routing Fix via Policy-Routing DaemonSet

Date: 2026-09-09

## Status

Accepted

## Context

Any client genuinely resident on `controlplane`'s VLAN 100 (confirmed live
against two independent real clients — the KVM host `mf-ms-a2-01` and
`pcd-ce-hyp-01` — and two independent VIPs, the GUA ingress VIP and a
purpose-built ULA-internal VIP) saw its connection to a Gateway-fronted
Service hang: the TCP handshake would complete and the next data packet
would be silently dropped, or the node's SYN-ACK would be retransmitted
and never ACKed. Full investigation history:
[docs/memory/node-gua-onlink-reply-unreliable.md](../memory/node-gua-onlink-reply-unreliable.md),
design:
[2026-09-09-vlan100-onlink-routing-daemonset-design.md](../superpowers/specs/2026-09-09-vlan100-onlink-routing-daemonset-design.md),
plan:
[2026-09-09-vlan100-onlink-routing-daemonset.md](../superpowers/plans/2026-09-09-vlan100-onlink-routing-daemonset.md).

**Root cause**: every Talos node's `ens3` carries kernel-installed
connected routes for both of VLAN 100's prefixes (ULA
`fd97:45c2:b3a1:100::/64`, TFiber's PD-delegated GUA
`2607:3640:1064:270::/64`), handed out via SLAAC/RA. Any destination in
either prefix is on-link by the kernel's own determination, so the node
replies via direct NDP/L2 resolution instead of normal routing — and
something in that on-link reply path silently drops the connection
mid-flow. The exact mechanism (conntrack state, a driver/NIC offload bug,
something gateway-side) was never fully isolated; a routing-level
workaround that sidesteps it was pursued instead of chasing the mechanism
further, once early diagnosis (2026-09-08) showed raw NDP itself is
reliable (30/30 `ping6`, 0% loss) and the failure is specific to the
on-link reply path.

Two earlier fix attempts were tried and disproven before this one:

1. **VLAN 179 BGP-peering migration** (#186, ADR-22 amendment) fixed a
   real, separate hairpin bug (the client's own outbound packets
   bypassing the gateway) but did not touch this one.
2. **Relocating `pdns4-shim` to a ULA-internal VIP** (PRs #189-191) was
   built on the mistaken theory that the bug was GUA-specific. Disproven
   2026-09-09: a genuinely VLAN-100-resident client (`pcd-ce-hyp-01`) hit
   the identical failure against the ULA VIP too — `ens3` carries a
   connected route for VLAN 100's ULA prefix exactly as it does the GUA
   one, so any VLAN-100-resident peer is equally on-link regardless of
   address family. No VIP relocation can fix this for a client that is
   actually on VLAN 100.

## Decision

A privileged `hostNetwork` `DaemonSet`
(`applications/vlan100-onlink-routing-fix/`, `controlplane`-only) running
on all 6 nodes, reconciling a custom `ip -6` routing table every ~60s:

- Routes for VLAN 100's two prefixes via the gateway's link-local
  next-hop instead of on-link, in a separate table (100) selected by two
  `ip -6 rule`s.
- A `/128` on-link exception for every node's own address, discovered
  dynamically via the Kubernetes Node API (`ClusterRole`: `get`/`list`/
  `watch` on `nodes`, nothing else) — so etcd/kubelet/Calico's BGP mesh
  stay genuinely on-link and unaffected. ULA-only discovery is sufficient
  (nothing legitimate uses GUA for inter-node traffic; a node's own
  address needs no explicit exception either — the kernel's `local` table
  always wins for self-addressed traffic before this custom rule is even
  consulted).

This is a deliberate, permanent exception to Talos's immutable-host
model — the only component in this fleet that reaches into a node's own
kernel routing state from outside Talos's declarative machine config.
That tradeoff is scoped as tightly as the fix allows:

- `NET_ADMIN` only (`capabilities: {drop: [ALL], add: [NET_ADMIN]}`), not
  full `privileged` — though **empirically confirmed live (2026-09-09)
  that `NET_ADMIN` alone as non-root still fails** (`RTNETLINK answers:
  Operation not permitted` on a plain `ip route add`); the container
  genuinely runs as root, this was tested rather than assumed.
- A read-only-root-filesystem, seccomp `RuntimeDefault`, `ALL` other
  capabilities dropped, no privilege escalation.
- Dynamic peer discovery (not a hardcoded node list) so it self-updates
  as the fleet scales, without needing a maintenance touch per node
  addition/removal.
- Validated in stages before any permanent commitment: a manual,
  single-node, hand-run test (throwaway debug pod) *before* writing any
  of this DaemonSet; then a pilot deployment scoped to one node via
  `nodeSelector`; only then fleet-wide. Every stage was followed
  immediately by a full cluster-health check (`kubectl get nodes`,
  `calico-system`/`kube-system` pod status) given the real risk that a
  scoping mistake here could disrupt etcd/kubelet/Calico mesh traffic,
  not just this one bug.

**Kept, not reverted**: the `internal-eg` GatewayClass/ULA-VIP
infrastructure from PRs #189-191, even though it didn't turn out to fix
the actual bug — it fixed three real, independent bugs along the way
(wrong Calico Service IP-pool annotation, an oversized 6-replica fleet
starving a near-capacity node, a missing `EnvoyProxy.spec.ipFamily`
causing IPv4-only listener binds on an IPv6-only cluster) and is
reasonable infrastructure to have regardless.

## Consequences

- **Fixes the original goal of the whole investigation**: Designate's
  pre-existing automatic retry loop successfully created the pending
  `usmnblm01.rye.ninja` zone, confirmed live 2026-09-09, with zero manual
  intervention on Designate's side — it simply succeeded once the
  underlying connectivity was fixed.
- **Unblocks `controlplane`'s VLAN 179 migration's final cutover step**
  (removing VLAN 100 from the gateway's BGP peer-group, plan Task 9 of
  [2026-09-08-controlplane-bgp-vlan179.md](../superpowers/plans/2026-09-08-controlplane-bgp-vlan179.md)),
  which had been blocked on this bug since discovery.
- **New maintenance surface**: a permanent, root, `hostNetwork` DaemonSet
  is a meaningfully different risk/complexity profile than the rest of
  this fleet's Talos-declarative networking. Anyone debugging node
  networking behavior on `controlplane` going forward needs to know this
  exists and reconciles kernel routing state outside Talos's own config.
- **The exact drop mechanism this fix routes around was never isolated.**
  If VLAN 100's addressing, the gateway, or TFiber's PD-delegation
  behavior changes materially in the future, this fix's assumptions
  (which two prefixes need routing around, which interface, how the
  gateway's link-local is discovered) should be re-verified, not assumed
  to still apply unchanged.
- **Applies to `controlplane` only, deliberately.** An earlier version of
  the ULA-VIP infrastructure (PRs #189-191) was placed directly in a base
  shared with `observability`, which has no VLAN-100/TFiber situation of
  its own — caught and fixed (#195) before landing here; this DaemonSet's
  own `controlplane`-only overlay was built correctly from the start as a
  direct result of that lesson.

## References

- [docs/memory/node-gua-onlink-reply-unreliable.md](../memory/node-gua-onlink-reply-unreliable.md) — full investigation history
- [2026-09-09-vlan100-onlink-routing-daemonset-design.md](../superpowers/specs/2026-09-09-vlan100-onlink-routing-daemonset-design.md) — design, open risks
- [2026-09-09-vlan100-onlink-routing-daemonset.md](../superpowers/plans/2026-09-09-vlan100-onlink-routing-daemonset.md) — execution plan, live validation results
- [ADR-22: UniFi BGP LoadBalancer VIPs](0022-unifi-bgp-load-balancer-vips.md) — the related, separate hairpin bug this fix's design deliberately avoids reintroducing
- [2026-09-08-controlplane-bgp-vlan179.md](../superpowers/plans/2026-09-08-controlplane-bgp-vlan179.md) — the migration this fix unblocks (Task 9, final cutover)
