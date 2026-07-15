---
name: vip-renumber-flakiness-investigation
description: RESOLVED — post-renumber ingress VIP flakiness was externalTrafficPolicy:Local + a Calico BGP-advertisement bug, not the renumber itself
metadata:
  type: project
---

**Resolved 2026-07-15.** After the services-network VIP renumber
([2026-07-15-services-network-design.md](../superpowers/specs/2026-07-15-services-network-design.md))
went live, `ca.rye.ninja` was only reachable on a fraction of attempts
(~1 in 6–10), not the 100%-failure the pre-renumber bug produced, but not
healthy either. Root-caused and fixed same day; see ADR-22 amendment for
the permanent record. Kept here for the investigation trail and the
reusable testing/debugging techniques.

**Testing gotcha (not a real bug):** curling the raw VIP literal
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

**Root cause:** the `envoy-merged-eg` Service uses
`externalTrafficPolicy: Local` with one backend pod. Calico advertises the
LoadBalancer's BGP host route from **every** node regardless of endpoint
locality — a known class of upstream bug (projectcalico/calico#6074,
#8162; a related v3.30.5 report, #11540, was closed "not planned"; no
known-good version to upgrade to, and this cluster is already on v3.32.1).
Nodes without the backend correctly have no kube-proxy redirect for the
VIP, and Calico's own `cali-cidr-block` nftables chain (anti-routing-loop
protection for its own IPPool CIDRs) drops the packet outright. Since the
gateway's BGP ECMP treats all 6 advertised paths as equally valid, only
the 1-in-6 chance of landing on the actual backend node worked.

**Diagnosis technique that found it:** capture with `tcpdump -e` (real
MACs, not just IPs) on the gateway's `br100` while running test traffic
**from the gateway itself** (`ssh root@<gateway-ULA>`, then curl locally)
— removes the client-VLAN hop and makes the gateway's own ECMP next-hop
selection directly observable. Background the tcpdump with `&` *inside*
a single SSH command that also runs the test loop — a bare
`ssh ... "tcpdump ... &"` followed by a second, separate ssh call blocks
until the first exits, so the capture and test traffic never overlap.
Confirming a `cali-cidr-block` DROP counter incrementing on the "bad" node
(`nft list ruleset` inside a privileged debug pod, `calico-system`
namespace has a `privileged` PodSecurity label) was the final piece.

**Fix:** spread one Envoy replica onto every node (required pod
anti-affinity + a control-plane taint toleration, 6 replicas for 6 nodes)
so every ECMP path has a working local endpoint — validated 15/15 after.
Also hit and fixed a related deadlock: the default `maxSurge: 25%` rollout
strategy tries to schedule a surge pod before retiring an old one, which
can't succeed when replicas == available nodes and anti-affinity is
required. Fixed with `maxSurge: 0, maxUnavailable: 1`.
