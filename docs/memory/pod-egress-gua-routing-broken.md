---
name: pod-egress-gua-routing-broken
description: Pod-sourced traffic cannot reach ANY GUA-space destination (confirmed with an unrelated external control, not just fleet VIPs) — a real, previously-unknown Calico/BGP routing gap, unrelated to M4 completion step B6. Also now confirmed as the likely blocker for external-client-to-VIP ingress (see 2026-09-08 update) — the reply is pod-sourced traffic egressing to the client's GUA address, so this may be one bug, not two
metadata:
  type: project
---

## Finding

Pod-sourced traffic on `observability` (very likely fleet-wide — `controlplane`
was not independently re-tested from a pod, but there is no reason to expect
it differs) cannot reach **any** GUA (global unicast, `2xxx:`-prefixed)
destination at all — confirmed both for the fleet's own Envoy Gateway VIP
(`2607:3640:1064:27f::9280`, shared by every `merged-eg` `TLSRoute`:
`ca.rye.ninja`, `id.rye.ninja`, `sso.rye.ninja`, and now `bao.rye.ninja`) and
for a completely unrelated external control target (Google DNS,
`2001:4860:4860::8888:443`). Both hang with no response until timeout — no
TCP `SYN-ACK`, nothing at the TLS layer (`openssl s_client` never even
prints `CONNECTED`).

**The same traffic works perfectly from the exact same node's own network
stack** (a `hostNetwork: true` pod): both the external control and the
Gateway VIP get a real `CONNECTED(00000003)` at the TCP level immediately.
This isolates the problem precisely to Calico's pod-network egress path for
GUA destinations — it is not a Gateway, DNS, NetworkPolicy, TLSRoute, or
application-level problem. It reproduces with zero fleet-specific
configuration involved (the Google DNS control has nothing to do with this
repo's manifests at all).

## Why this was found now, and why it was never caught before

Discovered while live-verifying
[`2026-08-15-m4-completion-design.md`](../superpowers/specs/2026-08-15-m4-completion-design.md)
step B6 (OpenBao
cross-cluster SPIFFE-cert auth, PRs #172-#177). Every layer B6 actually built
was independently confirmed correct before this was found: DNS resolves
`bao.rye.ninja` to the right VIP, the `Gateway` is `Programmed`, the
`TLSRoute` is `Accepted`/`ResolvedRefs`, Envoy's own xDS config (`/clusters`
admin endpoint, checked across all 6 `merged-eg` replicas after a rolling
restart) shows the `openbao` backend cluster with all 3 pod endpoints marked
`healthy`, and the NetworkPolicy chain (`envoy-proxy-allow`'s egress list
already coincidentally included port 8443 from an earlier, unrelated
Pinniped Supervisor rule) permits the traffic. None of that mattered because
the packets never leave the pod's own network position correctly in the
first place.

This is a **pre-existing** gap in the fleet's on-prem substrate, not
something introduced by B6 or any other recent work. It was never caught
before because every prior GUA-destined endpoint (`ca.rye.ninja` for step-ca,
`id.rye.ninja` for Keycloak, `sso.rye.ninja` for Pinniped Supervisor) has
only ever been validated from human/workstation LAN clients or from
`hostNetwork`-style paths — never from an ordinary pod's own network
position. B6 is the first thing in this fleet's history to need pod-to-VIP
GUA reachability for a real, non-human client.

## What's confirmed vs. still a hypothesis

**Confirmed, via direct live diagnosis** (this session had real
`kubectl`/`kubectl exec` access to both clusters for this investigation,
unlike most of this session which had none — see below):
- Pod → GUA (any destination, fleet VIP or external control): fails, no
  response, every time.
- `hostNetwork` pod on the same node → same destinations: succeeds
  immediately (`CONNECTED`).
- The `observability` IPPool already has `natOutgoing: true` set
  (`kubectl get ippool -o yaml`) — so this isn't simply "NAT was never
  turned on."
- Pod's own `ip -6 route` shows only a default route via a synthetic
  link-local next-hop (`fe80::ecee:eeff:feee:eeee`), no explicit route
  visible for GUA space at all — consistent with, but not proof of, the
  hypothesis below.

**Hypothesis, not yet confirmed** — needs a fresh investigation:
Calico may be treating the Gateway VIP's GUA prefix (and possibly GUA space
generally, if it's within a BGP-advertised aggregate Calico considers
"on-fabric") as an internal/BGP-known destination and skipping
`natOutgoing` masquerade for it, while the pod CIDR block's own return route
either isn't being propagated to the upstream UniFi gateway via BGP, or
isn't propagated in a way that survives back to the originating pod's ULA
source address. This would explain the SYN-with-no-reply symptom exactly
(packet leaves fine, whatever answers it has no route back to a bare pod
ULA address). **Not independently verified** — the next session should
check Felix's actual NAT/iptables-nft rules on a real node, Calico's BGP
peering status/advertised routes for the pod CIDR blocks specifically, and
whether the same failure reproduces on `controlplane` too (only
`observability` was tested).

## Impact on M4 completion step B6

B6 itself (docs/superpowers/specs/2026-08-16-openbao-cross-cluster-auth-design.md,
PRs #172-#177, all merged) is **fully correct and complete as designed** —
every component independently verified working right up to this networking
boundary. The `openbao-remote` `ClusterSecretStore` on `observability` will
report `Ready: True` the moment this routing gap is fixed; nothing in B6
needs to change. Don't re-open or re-debug B6's own manifests based on this
finding — the next session should treat this as a wholly separate
investigation into fleet pod-egress networking.

## 2026-09-08 update: likely the same bug, seen from the ingress side

Found again while validating
[2026-09-08-calico-bgp-peering-vlan179-design.md](../superpowers/specs/2026-09-08-calico-bgp-peering-vlan179-design.md)
(moving `controlplane`'s Calico BGP peering session to a dedicated VLAN
179 to fix a *different*, confirmed-and-fixed hairpin bug at the gateway).
That migration's own fix was verified working exactly as designed —
`tcpdump` on both the gateway's `br100` and `br179` during a live attempt
showed the client's packet correctly transiting `br100` → `br179` toward
the real BGP next-hop, no more same-interface loop.

**But the end-to-end symptom that started the whole VLAN 179 investigation
(an external VLAN-100 client — reproduced from the KVM host itself,
same bug class as the original Designate host — calling
`https://pdns4-shim.rye.ninja/healthz`, a `2607:3640:1064:27f::/64`
ingress VIP) still hangs identically after the TLS ClientHello, HTTP 000,
every time**, completely unchanged by the VLAN 179 fix. The client's TCP
handshake appears to complete (its own ACK implies a SYN-ACK was received,
even though no such reply appears in the `br100`/`br179` captures — it
must arrive via some other path), but no application data ever comes
back.

This matches this bug's own hypothesis exactly: the pod's SYN-ACK/reply
*is* pod-sourced traffic egressing toward a GUA destination (the external
client's address) — if pod-egress-to-GUA is broken generally, an
external-client-to-VIP ingress flow would show precisely this signature
(inbound reaches the pod fine, DNAT/ingress all correct, but the pod's own
reply can never route back). **Not yet confirmed as the same root cause**
— the design doc's own author was explicit about not conflating the two
during that migration's validation — but the symptom match is strong
enough that the next investigation into this bug should test the ingress
direction too, not just pod-initiated egress. If confirmed as one bug,
fixing it would unblock both the original B6 finding and Designate's
pending `usmnblm01.rye.ninja` zone creation.

`controlplane`'s VLAN 179 migration itself is complete and correct on its
own terms (PR #186, merged) — this finding is why its final cutover step
(removing VLAN 100 from the gateway's BGP peer-group) was deliberately
left undone: the phased-migration design's own gate for that step
("Designate's own retry loop successfully creates the pending zone") was
not met, and won't be until this bug is fixed.

## Session context this was found in

This session had no live cluster access for most of its duration (confirmed
early on: `kubectl get nodes` against `controlplane` failed with `no route
to host`) — all live debugging happened via the user running commands and
pasting output back. Direct `kubectl` access to both clusters unexpectedly
became available late in the session (unclear why — network conditions on
the operator's machine likely changed), which is what made this direct,
fast diagnosis possible. **Don't assume live access is available in a fresh
session** — check with a quick `kubectl get nodes --request-timeout=8s`
before planning further live diagnosis, and fall back to the
copy-paste-with-the-user pattern if it isn't (slower, but this session
proved it still works end-to-end).
