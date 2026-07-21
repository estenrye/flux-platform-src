---
name: workstation-nat64-route
description: RETIRED 2026-07-15 — manual v6 routes are no longer needed after the client-VLAN move + VIP renumber
metadata:
  type: project
---

**Retired 2026-07-15.** The workstation previously needed two manual v6
routes (NAT64 `64:ff9b::/96` and the BGP VIP `/112`) while it lived on
VLAN 100, sharing an on-link `/64` with the VIP pools and the NAT64
appliance. Both are gone now that the workstation moved to a dedicated
client VLAN (101) and the VIP pools were renumbered onto routed,
not-on-link prefixes
([2026-07-15-services-network-design.md](../superpowers/specs/2026-07-15-services-network-design.md)).

Validated 2026-07-15 from VLAN 101 with **zero manual routes present**:
`curl https://ca.rye.ninja/health` 15/15 (VIP path) and
`curl https://api.github.com` (NAT64 path) both succeed via the default
route alone.

Root causes, for reference:
- VIP route: the pool lived inside VLAN 100's on-link `/64`, so on-link
  hosts NDP'd for it instead of routing via the gateway (the M1
  "workstation can't self-test LB" limitation). Fixed by relocating both
  VIP pools to dedicated routed subnets (ADR-22 amendment).
- NAT64 route: incidentally resolved by the same VLAN move — no longer
  needs investigating separately.

If a workstation ever needs to test from VLAN 100 directly again, expect
the VIP-route symptom to return for that specific case (VLAN 100 itself
wasn't renumbered, only the VIP pools moved off it).
