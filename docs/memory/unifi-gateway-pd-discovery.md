---
name: unifi-gateway-pd-discovery
description: How to find the real DHCPv6 prefix delegation (PD) TFiber granted, and how to get a root shell on the UniFi gateway to check it
metadata:
  type: reference
---

The UniFi controller UI does not surface the actual DHCPv6-PD grant in an
obvious place. To confirm it directly, get a root shell on the gateway and
read the WAN DHCPv6 diagnostic log.

**Access:** `ssh root@<gateway-ULA>` (e.g. `fd97:45c2:b3a1:101::1` for the
VLAN-101 gateway address; any VLAN's `::1` reaches the same box). No key was
pre-authorized — first connection needs
`-o StrictHostKeyChecking=accept-new`. This is UniFi's own dataplane VM
(hostname pattern `usmnblm0<n>ryeninja`), a Debian-based Linux with
`vtysh`/FRR, `ip6tables` (legacy, not nftables), `ipset`, and `odhcp6c` as
the DHCPv6-PD client.

**Find the actual delegated prefix:**
```bash
tail -80 /var/log/wan-diag-dhcpv6.log
```
Look for the `IA_PD` lines, e.g.:
```
odhcp6c[4242]: IA_PD 0001 T1 43200 T2 72000
odhcp6c[4242]: 2607:3640:1064:270::/60 preferred 86400 valid 86400
```
That's the real grant (TFiber: `2607:3640:1064:270::/60`, confirmed
2026-07-15) — distinct from `ps aux | grep odhcp6c`'s `-P 60` flag, which is
only the *requested* hint, not what was actually delegated. The WAN's own
address (`ip -6 addr show dev eth8`) is a separate `/128`, not part of the
PD block.

**Other useful gateway-side checks used during this same investigation:**
- BGP RIB for a specific prefix: `vtysh -c 'show bgp ipv6 unicast <prefix>'`
- Kernel FIB / ECMP resolution for a flow: `ip -6 route get <dst> from
  <src> iif <in-if>`
- Firewall zone classification chains: `ip6tables -L UBIOS_FORWARD_JUMP -n
  -v` and follow the chain (`UBIOS_FORWARD_USER_HOOK` →
  `UBIOS_FORWARD_IN_USER` → `UBIOS_LAN_IN_USER`, etc.); membership in
  `UBIOS_local_zoned_subnets` / `UBIOS_ALL_NETv6_br<n>` ipsets governs
  LAN-vs-WAN classification per destination prefix.
- Live traffic: `tcpdump -ni br<n> icmp6` on the gateway itself (calico-node
  pods lack `tcpdump`; a privileged debug pod works in `calico-system`,
  which has a `privileged` PodSecurity label, for capturing on cluster
  nodes instead).

**Why this mattered:** confirming the real `/60` (not just "≥/56") was the
blocking unknown for
[2026-07-15-services-network-design.md](../superpowers/specs/2026-07-15-services-network-design.md)
§2 item 1 — it determines whether the ingress GUA VIP pool gets a routed
spare `/64` or stays ULA-only.
