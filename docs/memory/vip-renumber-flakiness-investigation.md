---
name: vip-renumber-flakiness-investigation
description: Post-renumber ingress VIP is intermittently unreachable; SNI-less curl gives a misleading RST, real cause still open
metadata:
  type: project
---

After the services-network VIP renumber
([2026-07-15-services-network-design.md](../superpowers/specs/2026-07-15-services-network-design.md))
went live (`lb-ingress-gua-routed` / `2607:3640:1064:27f::/112`, gateway FRR
uploaded, envoy Service recreated to pick up the new VIP), `ca.rye.ninja`
is only reachable on a fraction of attempts (roughly 1 in 8–10), not the
100%-failure the pre-renumber bug produced, but not healthy either.
Investigation is still open as of 2026-07-15; recorded here so the next
session doesn't repeat the same dead ends.

**Testing gotcha (resolved, not a real bug):** curling the raw VIP literal
(`https://[2607:3640:1064:27f::9280]/health`) sends no SNI matching
`ca.rye.ninja` per RFC 6066. Envoy-gateway's TLS-passthrough listener
filter-chains match on `server_names: ["ca.rye.ninja"]` only (confirmed via
`/config_dump?resource=dynamic_listeners` on the envoy admin port,
port-forwarded from the pod) — no destination-IP restriction. A raw-IP
curl gets an immediate `RST` right after the (SNI-less) ClientHello is
sent, which looks exactly like a backend-level rejection but is actually
Envoy correctly failing to match a filter chain. **Always test with
`curl --resolve ca.rye.ninja:443:<vip> https://ca.rye.ninja/...`** — never
the bare IP literal — or the RST noise drowns out the real signal.

**Real remaining symptom (open):** with SNI set correctly, most attempts
still get zero response at all (bare SYN retransmission, no SYN-ACK,
curl exit 000 after full timeout) — not a RST, a silent drop. Packet
capture on the gateway's `br100` (`tcpdump -e` to see real MACs) during a
batch of gateway-originated test connections showed **every SYN
consistently hashed to the same real next-hop, `52:54:00:b3:a1:13`
(controlplane-cp-3, `fd97:45c2:b3a1:100::13`), and none of them got a
response.** A separate earlier success was traced to a different next-hop,
`52:54:00:b3:a1:23` (controlplane-wk-3), which is very likely where the
envoy backend pod actually runs. Working theory, not yet confirmed: the
6-node BGP mesh gives ECMP reachability to the ingress VIP from every
node, but only the node(s) that can actually deliver the packet to the
backend (via a fresh kube-proxy/Calico dataplane rule for the
newly-recreated Service) work — and rule propagation to the other 5 nodes
may be incomplete or broken, silently dropping traffic that lands on them.
Not yet checked: per-node iptables/eBPF NAT rules for this specific
Service IP on a "good" node (wk-3) vs a "bad" one (cp-3).

**Useful technique recorded here:** to correlate ECMP next-hop selection
with success/failure, capture with `tcpdump -e` (shows real MACs, not just
IPs) on the gateway's `br100` while running test traffic **from the
gateway itself** (`ssh root@<gateway-ULA>`, then curl locally) — this
removes the client-VLAN hop from the picture and makes the gateway's own
ECMP decision directly observable. Background the tcpdump with `&`
*inside* a single SSH command that also runs the test loop (a bare
`ssh ... "tcpdump ... &"` followed by a second, separate ssh call blocks
until the first exits — the capture and the test traffic never overlap).
