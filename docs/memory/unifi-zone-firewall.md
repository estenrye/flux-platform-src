---
name: unifi-zone-firewall
description: UniFi 10.x zone-based firewall on the home gateway — routed subnets (VIPs, NAT64) aren't bound to any zone, and WireGuard clients land in External not VPN
metadata:
  type: project
---

Executed the `[H] validate how UniFi zones bind to BGP-learned prefixes`
item from
[2026-07-15-services-network-design.md](../superpowers/specs/2026-07-15-services-network-design.md)
§2 item 3, deferred since that design shipped. Found on 2026-07-20/21
while chasing a public step-ca outage and a subsequent
GitHub/NAT64 outage.

## The core gap: routed subnets aren't bound to any zone

UniFi 10.x's zone model classifies traffic by which defined
**network/interface** a destination belongs to (backed by ipsets like
`UBIOS_ALL_NETv6_br100`). Anything reachable only via a **routed**
prefix — not on-link, not a UniFi "Network" object — isn't a member of
any zone's ipset, regardless of which physical interface actually
carries it. Confirmed for two distinct cases:

- The Calico ingress-VIP pool (`2607:3640:1064:27f::/112`, routed via
  `br100`) — WAN-classified traffic silently dropped at
  `UBIOS_WAN_WAN_USER`'s default-deny (the "unclassified destination"
  bucket), even though a valid BGP route to it exists.
- The NAT64 well-known prefix (`64:ff9b::/96`) serviced by the
  `nat64-01` VM (itself on-link within `ryezone-labs-ipv6`/VLAN 100,
  but the *translation prefix* it services is not a UniFi network
  object) — broke for both Internal- and External-classified sources
  once VLAN 100 moved into a new zone (see below) and default
  zone-pair policy tightened.

**Fix pattern**: a Policy Table rule with **Destination scope = IP**
(the specific `/112` or `/96`, not a zone), not a zone-to-zone rule.
Confirmed working: `External → [zone]`, destination IP
`2607:3640:1064:27f::9280/128` (single VIP, tightest scope available
since the containing subnet has no network object to reference), port
443 only, action Allow — restored public `ca.rye.ninja` access.

## WireGuard clients classify as External, not VPN

Confirmed via root shell on the gateway
([[unifi-gateway-pd-discovery]]): traffic arriving on interface
`wgclt1` (a WireGuard client tunnel) jumps straight to
`UBIOS_WAN_IN_USER` (`ip6tables -L UBIOS_FORWARD_IN_USER`), the same
bucket as the two real WAN uplinks (`eth7`, `eth8`). The zone matrix
(Settings → Zones) shows a built-in **VPN** zone with `VPN → Internal:
Allow All` — much more permissive than `External → Internal: Allow
Return` only — but that zone currently has **no networks/interfaces
assigned to it** (shown as `-`, same as Gateway/Hotspot/DMZ before use).
So a WireGuard remote-access session gets the strict External policy
by default, not the more-trusted VPN one, until the WireGuard network
is explicitly bound to the VPN zone. Not fixed this session — noted as
a likely-intentional-oversight worth a deliberate decision, not
something to silently correct.

## DMZ-Kubernetes zone (VLAN 100 / `ryezone-labs-ipv6`)

A custom zone, `DMZ-Kubernetes`, was created for the cluster's own
network (previously grouped into the default `Internal` zone with every
other home network). Sequencing that mattered: build every needed
Policy Table rule *before* reassigning the network's zone, since the
reassignment is what actually starts enforcing the new zone-pair
defaults (mostly deny, until rules exist) — reassigning first would
have cut kubectl/SSH/HTTPS access from the rest of the LAN immediately.

Rules built, in order:
1. `DMZ-Kubernetes → DMZ-Kubernetes`: Allow All (intra-cluster).
2. `Internal → DMZ-Kubernetes`: Allow All, any port (kubectl 6443,
   Talos API 50000-50001, SSH 22, HTTPS 443 all needed; ended up
   broader than strictly necessary — accepted as-is, not tightened).
3. `External → DMZ-Kubernetes`: Allow, destination IP `2607:3640:1064:27f::/112`
   (the whole Calico ingress pool, not just the current VIP — covers
   future services without a new rule per VIP), port 443 only.
4. `Internal`/`External → [NAT64 prefix]`: Allow, all ports/protocols
   (NAT64 carries arbitrary translated traffic, not just 443/80) —
   needed once the zone move started enforcing default-deny against the
   previously-implicit NAT64 path.

Return traffic (`DMZ-Kubernetes → Internal`, `DMZ-Kubernetes → VPN`)
appeared automatically as "Allow Return" zone-pair entries once the
forward rules existed — no separate manual rule needed for that
direction.

## Debugging tools used

- `traceroute6 <dest>` from a client: a hard admin-prohibited/blocked
  path shows the trace stalling at the gateway's own first hop; a
  working NAT64 path shows real internet hops all the way to the
  destination's actual network (e.g. `github-ic-*.ip.twelve99-cust.net`
  for GitHub) — a trailing `* * *` on the last few hops is normal
  traceroute behavior (destinations often don't respond to the UDP
  probes) and does **not** by itself mean the path is blocked; confirm
  with a real `curl`/`nslookup` before concluding otherwise.
- `nslookup -type=AAAA <v4-only-host> [resolver]` / `dig AAAA <host>
  @<resolver>` — a working DNS64 resolver synthesizes `64:ff9b::...`
  for a host with no real `AAAA` (`github.com` is the reference
  v4-only test host, matching
  `tests/controlplane-baseline/values/controlplane.env`'s
  `V4ONLY_HOST`); NXDOMAIN/no-answer means that resolver isn't doing
  DNS64 synthesis for the query.
- Per-network IPv6 DNS: UniFi has **two** places DNS gets set — the
  RA's RDNSS option (what a Mac on SLAAC actually uses) and a
  separate DHCPv6-side field. Editing the wrong one (or editing the
  wrong *network* entirely — VLAN 100 vs. the actual client VLAN) is a
  silent no-op from the client's perspective; `scutil --dns` after a
  Wi-Fi toggle shows what's really being used.
