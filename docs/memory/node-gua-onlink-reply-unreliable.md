---
name: node-gua-onlink-reply-unreliable
description: Root cause confirmed and a fix VALIDATED (manual single-node test, 2026-09-09) — see docs/superpowers/plans/2026-09-09-vlan100-onlink-routing-daemonset.md. Any genuinely VLAN-100-resident peer's connection (GUA or ULA address, since ens3 carries connected routes for both VLAN 100 prefixes) gets its reply silently dropped on-link. Policy-routing (custom table + ip -6 rule forcing those two prefixes through the gateway instead of on-link NDP, with /128 peer exceptions for other Talos nodes) fixed it in a hand-run test on one node (wk-1): 4/6 attempts succeeded (the other 2 landed on unfixed nodes, as expected), zero cluster-health impact. Not yet built as a permanent DaemonSet — that's the plan's remaining Tasks 2-7.
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

## ULA-VIP fix built (PR #189, #190, #191), then disproven as a real fix, 2026-09-09

The "move `pdns4-shim` to a ULA-internal VIP" direction below was designed,
built, and landed across three PRs — worth keeping for the real bugs it
fixed, but it **does not solve the connectivity problem for the actual
consumer**.

- **What got built**: a new `internal-eg` GatewayClass/`EnvoyProxy`
  (`applications/envoy-gateway/base/resources/internal-proxy-config.envoyproxy.yaml`)
  whose Service is pinned to the `lb-internal-ula-routed` IPPool via
  Calico's `projectcalico.org/ipv6pools` annotation (not
  `cni.projectcalico.org/ipv6pools` — that prefix is for pod IPAM, silently
  ignored for Services; wasted one full PR cycle discovering this),
  `externalTrafficPolicy: Cluster` (2 lightweight replicas instead of
  mirroring `merged-eg`'s 6-replica/required-anti-affinity ECMP mitigation,
  which starved a near-capacity node), and — the real blocker —
  `spec.ipFamily: IPv6` (undocumented anywhere in git for the *existing*
  `merged-eg` fleet either; it only works because someone set it
  imperatively on the live object and Flux's server-side-apply doesn't own
  or revert un-declared fields; both `EnvoyProxy` objects now declare it
  explicitly). `EnvoyProxy.spec.ipFamily` defaults to **IPv4-only** — on
  this IPv6-only cluster that silently broke every listener, including the
  kubelet readiness probe, until fixed.
- **Why it doesn't fix the real problem**: `pcd-ce-hyp-01` — a real
  standalone consumer of `pdns4-shim` (`10.45.60.1`, confirmed
  VLAN-100-resident, `br-tun` interface with both a `fd97:45c2:b3a1:100::/64`
  ULA and a `2607:3640:1064:270::/64` GUA address, SLAAC-assigned same as
  every other VLAN-100 host) — hit the **identical bug signature** against
  the new ULA VIP: `tcpdump` on the Talos node's `ens3` (matching the
  exact 2026-09-08 GUA-case capture) showed the SYN-ACK repeatedly
  retransmitted out `ens3`, never ACKed. `ens3` carries a connected route
  for `fd97:45c2:b3a1:100::/64` (the node's *own* subnet) exactly as it
  does for the GUA prefix — so a genuinely VLAN-100-resident peer's ULA
  address is *just as on-link* as its GUA one, and hits the same drop.
- **Corrected discriminator**: it was never "GUA vs ULA." The 2026-09-08
  `br200`-forced test succeeded because that source address was on a
  *different VLAN entirely* (200, not 100) — genuinely off-link with
  `ens3`'s connected routes for either VLAN-100 prefix. Any client
  genuinely resident on VLAN 100 — GUA or ULA sourced, doesn't matter —
  hits this bug against any VIP a Talos node replies to on-link for. Since
  the real Designate caller and `pcd-ce-hyp-01` are both confirmed
  VLAN-100-resident, **no VIP-relocation fix can work for them** — the fix
  has to live at the on-link-reply mechanism itself.
- **Net assessment**: the three PRs are good infrastructure to keep (fixed
  three real, independent bugs: the annotation, the oversized replica
  fleet, the missing `ipFamily`) but do not close out this investigation.
  The three original 2026-09-08 candidate directions are back in scope:
  policy-based routing on each Talos node, disabling on-link/NDP-direct
  behavior for VLAN 100's connected-route prefixes in favor of always
  routing through the gateway (even for genuinely on-link peers — matching
  behavior a *normal* router would use is not obviously the same as what a
  Talos node identity should do here, still needs research), or a
  TFiber/gateway-side change. None evaluated yet.
- Worth testing whether this reproduces identically for other Gateway-fronted
  services (`id.rye.ninja`, `ca.rye.ninja`, `sso.rye.ninja`, `bao.rye.ninja`)
  — expect yes, since the mechanism is about the *client's* VLAN-100
  residency, not which Service/VIP is targeted.
- **Still blocks `controlplane`'s VLAN 179 migration's final cutover step**
  (removing VLAN 100 from the gateway's BGP peer-group) and the original
  goal that started this whole investigation (Designate's automatic retry
  loop successfully creating the pending `usmnblm01.rye.ninja` zone) —
  neither should proceed until this is actually fixed.

## Policy-routing fix designed and validated, 2026-09-09

Full design:
[2026-09-09-vlan100-onlink-routing-daemonset-design.md](../superpowers/specs/2026-09-09-vlan100-onlink-routing-daemonset-design.md).
Plan: [2026-09-09-vlan100-onlink-routing-daemonset.md](../superpowers/plans/2026-09-09-vlan100-onlink-routing-daemonset.md).

- **Mechanism**: a custom `ip -6` routing table on each Talos node,
  containing routes for VLAN 100's two prefixes via the gateway's
  link-local next-hop (not on-link), plus `/128` on-link exceptions for
  every *other* node's own ULA address (so etcd/kubelet/Calico's BGP mesh
  stay genuinely on-link, unaffected) — discovered dynamically via the
  Kubernetes Node API, ULA-only (confirmed sufficient; nothing legitimate
  uses GUA for inter-node traffic). Two `ip -6 rule`s route those
  prefixes to the custom table instead of `main`.
- **Manual single-node validation, Task 1, PASSED**: hand-applied on
  `wk-1` via a throwaway privileged `hostNetwork` debug pod. Cluster
  health stayed completely clean (all 6 nodes `Ready`, zero new restarts
  anywhere) throughout.
- **Validation methodology note, worth remembering for Task 3**: plain
  repeated `curl` attempts from `pcd-ce-hyp-01` did **not** reliably land
  on the pilot node at all. `internal-eg`'s `externalTrafficPolicy:
  Cluster` (set in PR #191, specifically to avoid needing `merged-eg`'s
  6-replica full-node-coverage mitigation) means kube-proxy forwards a
  connection cross-node from whichever node ECMP originally picks to
  wherever the pod actually runs, and the reverse NAT for the reply
  happens back at *that original receiving node*, not the pod's node —
  confirmed via simultaneous `tcpdump` on all 6 nodes, which caught SYNs
  landing on `cp-3` and `wk-2` while `wk-1` (the only node with the
  routing fix, and the pod's actual node) saw nothing. Fix: temporarily
  patched the live `Service` to `externalTrafficPolicy: Local` (both
  replicas already ran on `wk-1`), which makes only attempts landing on
  `wk-1` reach the pod at all — isolating the fix for a clean test.
  Reverted to `Cluster` immediately after.
- **Result**: 4 of 6 attempts under the temporary `Local` policy returned
  `HTTP 200` (the other 2 failed fast, consistent with landing on one of
  the 5 still-unfixed nodes, not a partial failure of the fix itself).
  This is the first successful end-to-end connection from a genuinely
  VLAN-100-resident client to any fleet service through this whole
  investigation.
- **Not yet done**: this was a manual, temporary, single-node test —
  cleaned up immediately after (routes/rules flushed on `wk-1`, `Service`
  reverted, debug namespaces deleted). The permanent fix (a `DaemonSet`
  covering all 6 nodes, RBAC, dynamic peer discovery) is plan Tasks 2-7,
  not yet built.
