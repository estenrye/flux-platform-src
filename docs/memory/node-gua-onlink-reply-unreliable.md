---
name: node-gua-onlink-reply-unreliable
description: A GUA-sourced connection from a VLAN-100 client (in the same /64 TFiber's PD delegates to VLAN 100) to a fleet ingress VIP completes its TCP handshake but has the next packet silently dropped, every time — NDP/on-link delivery itself is reliable, confirmed via 30/30 ping and live tcpdump. A ULA-sourced connection from the same client succeeds reliably (proven via curl --interface A/B test) and is the validated, not-yet-implemented fix direction (internal Gateway + split-horizon DNS), no Talos-side change needed.
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

## Refined finding, confirmed live 2026-09-09: it's not NDP flakiness, it's a mid-flow silent drop, and ULA-sourced traffic sidesteps it entirely

Follow-up live testing (`hostNetwork` `netshoot` pod on `cp-1` in a throwaway
`netdebug` namespace; `mf-ms-a2-01` — the KVM host itself, same stand-in the
original investigation used as "same bug class as the real OpenStack
Designate host") sharpened the diagnosis:

- Plain `ping6` from `cp-1` to the KVM host's GUA address
  (`2607:3640:1064:270::2000`): **30/30, 0% loss, sub-ms RTT.** On-link
  NDP resolution itself is not flaky — the earlier "sometimes gets a
  SYN-ACK, sometimes doesn't" read on raw reachability was wrong; NDP
  works fine every time.
- Real repro (`curl` from the KVM host to `https://pdns4-shim.rye.ninja/healthz`,
  captured with `tcpdump` simultaneously on `cp-1`'s `ens3` and on the KVM
  host itself): the TCP handshake **completes** (SYN out `ens8`, SYN-ACK
  correctly reaches the KVM host via `ens3`'s on-link path, confirmed
  arriving via `tcpdump`'s `br0 In`) — the failure is the **very next
  packet**, the client's ACK+TLS-ClientHello, which is silently dropped
  with no trace of a reply, every time. This matches ADR-22's original
  description of the pre-VLAN-179 hairpin bug's packet-loss signature
  almost exactly, but recurring here post-migration for a different
  underlying reason (on-link GUA source, not a hairpin through the
  gateway).
- **Controlled A/B test, `curl --interface`, isolates the cause**: forcing
  the KVM host's connection out `br0` (its VLAN 100 interface — the only
  one with a GUA address, in `2607:3640:1064:270::/64`) failed 3/3,
  identical signature (handshake completes, ClientHello vanishes). Forcing
  it out `br200` (a different VLAN's interface with **no GUA address** —
  curl was forced to source from a ULA address instead) succeeded **3/3**,
  full TLS 1.3 handshake, HTTP/2 200, ~30ms. Source address, not
  destination or interface topology, is the discriminator: a GUA source in
  the delegated `2607:3640:1064:270::/64` reliably breaks mid-flow; a ULA
  source reliably works.
- **This resolves the "flaky proxy-NDP" open question from 2026-09-08 in
  the other direction**: it isn't an unreliable ISP-side proxy-NDP
  mechanism at all — NDP itself is solid. Something (most likely
  stateful/conntrack-based, given a working handshake but a dropped
  next-packet) drops the flow specifically when the client's source
  address is in the on-link GUA range, independent of NDP reachability.
  Exact mechanism (gateway conntrack? asymmetric path beyond what was
  captured?) still not pinned down — the practical discriminator (GUA
  source vs. ULA source) is confirmed regardless of mechanism.
- **Network-position discrepancy found and resolved**: `applications/pdns4-shim/base/resources/gateway.yaml`
  (committed 2026-09-08, PR #184, one day before this note) carries a
  comment claiming Designate "calls in from outside the home network" and
  needs a publicly-trusted cert — apparently stale/inaccurate leftover
  reasoning from before Designate's host moved onto VLAN 100 ([[m2-step8-delegated-zone-migration]]-era Rackspace hosting). Esten confirmed
  2026-09-09 live: the real Designate caller **is** on VLAN 100 today,
  matching ADR-22 and the 2026-09-08 design doc, not the gateway.yaml
  comment. The comment should be corrected/removed in a follow-up PR to
  avoid re-confusing this investigation later.

## Fix direction now validated, not yet implemented

Because the real Designate caller is confirmed VLAN-100-resident (not
internet-external), the ULA-source workaround just proven live is a real,
low-risk candidate fix — no Talos machine-config or kernel-level change
needed on any of the 6 nodes:

- **Envoy Gateway's shared LoadBalancer Service currently has only one
  VIP**: `envoy-merged-eg-668ac7ae` in `envoy-gateway-system`, GUA-only
  (`2607:3640:1064:27f::9280`, the `lb-ingress-gua-routed`/`ippool-lb-ingress-routed`
  pool). `mergeGateways: true` means every Gateway-fronted hostname in the
  fleet shares this one Service/VIP — there is currently no
  ULA-internal-routed counterpart wired up for it, unlike the pattern
  ADR-22 already established at the IPPool level (`ippool-lb-internal(-routed)`
  exists but nothing currently binds a Gateway listener to it).
- **Candidate fix, not yet built**: stand up an internal-facing Gateway
  (or a second listener/Service bound to the ULA-internal IPPool) for
  `pdns4-shim.rye.ninja` (and potentially other Gateway-fronted hostnames
  VLAN-100 clients call), plus split-horizon DNS so VLAN-100-resident
  callers resolve to the ULA VIP while genuine internet clients keep
  resolving to the GUA ingress VIP. TLS should still terminate correctly
  either way since Envoy matches by SNI/Host header, not by which VIP was
  hit.
- Not yet evaluated: whether this generalizes cleanly to a
  fleet-wide split-horizon policy for all Gateway-fronted hostnames, or
  should stay scoped to just `pdns4-shim` for now. Also not yet checked:
  whether Calico/Kubernetes Services support a clean way to give one
  Service two IPv6 LB addresses (one GUA, one ULA) versus needing a
  wholly separate internal Gateway/Service object.
- **Still open, deliberately not pursued given the above**: the three
  2026-09-08 candidate directions (Talos-side policy routing, disabling
  on-link/NDP behavior fleet-wide, TFiber/gateway-side changes) — the
  ULA-source fix is strictly simpler and lower-risk than any of them, so
  they're superseded unless the ULA approach turns out not to generalize.
- Worth testing whether this reproduces identically for other GUA-fronted
  services (`id.rye.ninja`, `ca.rye.ninja`, `sso.rye.ninja`, `bao.rye.ninja`)
  once the fix direction is implemented — expect yes, same shared Envoy
  Service.
- **Blocks `controlplane`'s VLAN 179 migration's final cutover step**
  (removing VLAN 100 from the gateway's BGP peer-group) and the original
  goal that started this whole investigation (Designate's automatic retry
  loop successfully creating the pending `usmnblm01.rye.ninja` zone) —
  neither should proceed until this is fixed.
