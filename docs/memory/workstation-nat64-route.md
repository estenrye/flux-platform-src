---
name: workstation-nat64-route
description: Mac on VLAN 100 needs a manual 64:ff9b::/96 route to the NAT64 appliance; it vanishes on reboot/interface flap
metadata:
  type: project
---

The workstation (Mac, VLAN 100, ULA via RA autoconf, no GUA) requires a
manually added route for NAT64 traffic:

```bash
sudo route -n add -inet6 64:ff9b::/96 fd97:45c2:b3a1:100::64
```

The UniFi gateway deliberately does NOT carry this route (hairpin through
the gateway was dropped as asymmetric during M1 — [[m1-implementation-status]]).
macOS drops manual routes on reboot or interface flap, so this recurs.

**Symptom when missing:** TLS handshake timeouts to IPv4-only hosts
(api.github.com, ghcr.io, Rackspace Spot endpoints) while dual-stack sites
(google.com) work fine — DNS64 synthesizes AAAA records that route into
the void via the default gateway. First observed 2026-07-13 masquerading
as "Spot cluster is down" during M2 kickoff.

**Verify:** `route -n get -inet6 64:ff9b::1` should show gateway
`fd97:45c2:b3a1:100::64`, not `fe80::...%en0`.

Persistence option (not yet installed): a LaunchDaemon or a
`networksetup`-based login script; revisit if the re-add becomes annoying.
