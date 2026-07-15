---
name: workstation-nat64-route
description: Mac on VLAN 100 needs TWO manual v6 routes (NAT64 /96 and VIP /112); both vanish on reboot/interface flap
metadata:
  type: project
---

The workstation (Mac, VLAN 100, ULA **and GUA** via RA autoconf — the
earlier "no GUA" note was stale by 2026-07-15) requires two manually
added routes:

```bash
# NAT64: v4-only destinations via the appliance
sudo route -n add -inet6 64:ff9b::/96 fd97:45c2:b3a1:100::64
# BGP VIPs: carved from the on-link /64, so the Mac NDPs for them
# instead of routing via the gateway (which holds the BGP routes)
sudo route -n add -inet6 2607:3640:1064:270:ffff::/112 fe80::ae8b:a9ff:fe6e:13de%en0
```

macOS drops manual routes on reboot or interface flap, so both recur.
UniFi exposes no RA route-information/L-bit knobs, so the gateway cannot
push them (asked and settled 2026-07-15).

**Symptoms when missing:**
- NAT64 route: TLS timeouts to v4-only hosts (api.github.com, ghcr.io)
  while dual-stack sites work — first bit 2026-07-13 masquerading as
  "Spot is down".
- VIP route: "Network is unreachable" connecting to any LB VIP
  (ca.rye.ninja) — the M1 "workstation can't self-test LB" limitation,
  root-caused 2026-07-15: VIP pools live inside the on-link /64s.

**Verify:** `route -n get -inet6 64:ff9b::1` → gateway `…::64`;
`route -n get -inet6 2607:3640:1064:270:ffff::1` → gateway `fe80::…`.

**Structural fix deferred** (M2 design §4.6): if TFiber's PD is ≥/56,
renumber both VIP pools onto routed-not-on-link prefixes — deletes both
the VIP host route and the M1 limitation. A UniFi static route for
64:ff9b::/96 would retire the NAT64 route for all hosts (retest the M1
hairpin verdict). Persistence stopgap if re-adding annoys: LaunchDaemon.
