---
name: node-gua-onlink-reply-unreliable
description: A Talos node treats any external client sharing its own connected GUA /64 as on-link and replies via direct NDP/L2 resolution on its VLAN 100 interface, bypassing routing entirely, regardless of which interface the inbound packet arrived on — reliability of that direct reply is inconsistent, causing intermittent connection hangs for external-client-to-fleet-VIP traffic. Confirmed root cause of the symptom controlplane's VLAN 179 BGP-peering migration did not fix
metadata:
  type: project
---

## Finding, confirmed live 2026-09-08

While validating
[2026-09-08-calico-bgp-peering-vlan179-design.md](../superpowers/specs/2026-09-08-calico-bgp-peering-vlan179-design.md)
(`controlplane`'s Calico BGP peering session moved to a dedicated VLAN 179
to fix a confirmed, *different* hairpin bug at the UniFi gateway — that fix
verified working correctly, see the design doc and ADR-22's amendment): the
original end-to-end symptom that started the whole investigation (an
external VLAN-100 client — reproduced from the KVM host itself, same bug
class as the real OpenStack Designate host — calling
`https://pdns4-shim.rye.ninja/healthz`) still hung identically after the
TLS ClientHello, `HTTP 000`, every time, completely unchanged by the VLAN
179 fix.

Root-caused via `hostNetwork: true` `nicolaka/netshoot` debug pods
deployed simultaneously on all 6 `controlplane` nodes, `tcpdump`-capturing
`host 2607:3640:1064:27f::9280` on each while triggering one client
attempt from the KVM host:

- The inbound SYN correctly arrives at whichever node ECMP selects, via
  **`ens8`** (the VLAN 179 NIC) — this is *correct*, matching the VLAN 179
  fix: the gateway forwards the client's packet toward the BGP-advertised
  next-hop, which is now a VLAN 179 address.
- The node's SYN-ACK reply goes back out via **`ens3`** (the VLAN 100 NIC)
  — a different interface than the one the SYN arrived on.
- `talosctl -n <node> get routes` explains why: `ens3` carries a
  **connected route to `2607:3640:1064:270::/64`** — the exact GUA prefix
  TFiber's PD delegation puts on VLAN 100, and the exact prefix the
  external client's own address falls in. The node's kernel sees the
  client's address as **on-link** with `ens3` and answers via direct
  NDP/L2 resolution, entirely bypassing normal routing — a decision made
  independently of which interface the request arrived on. `ens8` (VLAN
  179) carries no GUA route at all (by design — it's ULA-only, no
  clients, no PD), so it was never a candidate for the reply either way.

## This is not the VLAN 179 fix's fault, and not the same bug as pod-egress-GUA

This asymmetry is a **side effect of exposing**, not a bug **introduced
by**, the VLAN 179 migration. Before that migration, SYN and reply both
happened to transit `ens3` (same interface, same underlying flawed
assumption, already broken) — the hairpin at the gateway and this on-link
misassumption were two independent bugs stacked on the same path, and
fixing the first one made the second one's asymmetry visible rather than
hidden inside a single interface's traffic.

Also confirmed **not** the same bug as [[pod-egress-gua-routing-broken]]:
that bug is about a *pod's own* newly-initiated egress connections to GUA
destinations failing outright. This bug is about the *node's own network
stack* (equivalent to a `hostNetwork` path) replying to an *inbound*
connection from a client it incorrectly considers on-link — a plain
pod-network pod on `controlplane` was directly confirmed able to reach
external GUA destinations fine (see that memory file's 2026-09-08 update),
ruling that bug out as the explanation here.

## Why "on-link" is the wrong assumption

TFiber's DHCPv6-PD delegation puts a single `/64` (`2607:3640:1064:270::/64`)
on VLAN 100, and every node's `ens3` gets a connected route to it via
SLAAC. The kernel's standard behavior for a connected route is: any
address within it is on-link, resolve via NDP, no gateway needed. This is
correct for genuine same-L2-segment neighbors, but **an arbitrary external
client on the public internet does not actually share a physical L2
segment with these nodes** just because its address happens to fall within
the same numerically-delegated `/64` — TFiber (or an intermediate router)
must be doing some form of proxy-NDP or routing trick to make this
"on-link" fiction work at all for genuinely external clients, and that
mechanism is evidently unreliable: sometimes the direct reply gets through
(this session's own testing showed a client occasionally receiving a
SYN-ACK and sending a ClientHello, which then also hung), sometimes it
doesn't (the same client's later attempts got no SYN-ACK at all). This
inconsistency, not a hard on/off failure, is consistent with a flaky
proxy-NDP/bridging path rather than a clean routing gap.

## Not yet done

- **Not yet fixed.** No concrete remediation attempted this session —
  this finding is diagnostic only, handed off for a dedicated follow-up.
- Candidate directions, none evaluated yet: policy-based routing on each
  Talos node (force replies to VIP-destined flows back out whichever
  interface the request arrived on — Talos's declarative machine config
  has no obvious first-class support for arbitrary `ip rule` policy
  routing; would need research), disabling on-link/NDP-direct behavior
  for this specific GUA prefix in favor of always routing through the
  gateway, or investigating whether TFiber/the gateway can be configured
  to stop presenting VLAN 100's GUA `/64` as on-link to nodes at all for
  addresses that aren't genuinely local.
- Worth testing whether this reproduces identically for other GUA-fronted
  services (`id.rye.ninja`, `ca.rye.ninja`, `sso.rye.ninja`, `bao.rye.ninja`)
  or is somehow specific to the ECMP/multipath conditions around
  `pdns4-shim`'s ingress VIP.
- **Blocks `controlplane`'s VLAN 179 migration's final cutover step**
  (removing VLAN 100 from the gateway's BGP peer-group) and the original
  goal that started this whole investigation (Designate's automatic retry
  loop successfully creating the pending `usmnblm01.rye.ninja` zone) —
  neither should proceed until this is fixed.
