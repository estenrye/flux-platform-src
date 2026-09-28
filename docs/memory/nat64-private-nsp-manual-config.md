---
name: nat64-private-nsp-manual-config
description: Private-NSP NAT64 path (pcd.rye.ninja) — manual UniFi route/firewall rule not in Terraform, and live-only ndppd/proxy_ndp state not in the cloud-init template
metadata:
  type: project
---

Two gaps found closing out the review of
[2026-09-28-nat64-private-nsp-design.md](../superpowers/specs/2026-09-28-nat64-private-nsp-design.md):
one piece of required gateway config exists only on the live UniFi
gateway, and one piece of currently-running appliance config exists only
on the live `nat64-01` VM. Neither is visible from `git log` alone.

## Manual UniFi config: static route + Policy Table rule for the private NSP

Same class of gap [[unifi-zone-firewall]] already documents for the
well-known prefix (`64:ff9b::/96`) — routed-but-not-zone-bound prefixes
aren't reachable from other VLANs by default, see that file for why. This
is the second prefix that needed the identical treatment, done manually
on the UniFi gateway on 2026-09-28, outside Terraform (no
Terraform/Crossplane resource in this repo manages it — checked, none
exists):

1. A static route for `fd97:45c2:b3a1:64:65::/96` (the private-NSP
   prefix) via `fd97:45c2:b3a1:64::64` — the appliance's own address.
2. A UniFi Policy Table rule with **Destination scope = IP** for that
   same `/96` (not a zone-to-zone rule) — matching the exact pattern
   `docs/memory/unifi-zone-firewall.md` documents for `64:ff9b::/96`.

Without this, the private-NSP path works from the appliance itself but is
actively rejected (ICMPv6 "Destination unreachable: Address unreachable",
from the *requesting* VLAN's own gateway, before the packet ever reaches
`nat64-01`'s VLAN) from anywhere else — including the `controlplane`
cluster, the actual consumer of this path. See the design spec's §3.2 and
`docs/runbooks/nat64-appliance-rebuild.md`'s "One-time site-network
setup" section for the full incident. **If this appliance is ever rebuilt
against a different site network, redo both by hand** — nothing in this
repo recreates them.

## Live-only: `ndppd` / `proxy_ndp` — enabled on the box, not in git

`ndppd` (the NDP proxy daemon) and `net.ipv6.conf.lan.proxy_ndp=1` are
currently installed and enabled on the live `nat64-01` appliance, done
live during the same 2026-09-28 debugging session, as a candidate fix for
the reachability gap above. **This is not in the committed cloud-init
template** (`providers/kvm/modules/nat64-appliance/templates/user-data.yaml.tftpl`).
A future `tofu taint`-based rebuild (the only real rebuild path — see the
runbook) will silently lose both, and nothing in git history would tell
the next reader they were ever there. This file is that record.

**Reasoning for why `ndppd` is almost certainly not actually required**
(a testable prediction, not just a hedge): the static route above points
its next-hop at `fd97:45c2:b3a1:64::64` — the appliance's own real,
natively-configured `lan` address, the same address the gateway already
resolves via ordinary Neighbor Discovery for every other purpose. The
gateway therefore only ever needs to do NDP resolution for that one real,
already-resolvable address, never for any `fd97:45c2:b3a1:64:65::*`
address — so proxy NDP has nothing to resolve in this topology; there is
no "phantom" NSP address the gateway ever needs to discover, because the
route already terminates at a real on-link neighbor. This is consistent
with what was actually observed: enabling `ndppd` alone, *before* the
route/rule existed, changed nothing (the rejection happened upstream of
where NDP resolution would even be attempted); adding the route/rule is
what flipped the path to working, with `ndppd` already running at that
point but not obviously doing anything.

**Action for whoever does the next appliance rebuild:** rebuild
*without* re-enabling `ndppd`/`proxy_ndp` first. Confirm the private-NSP
path still works via the static route + Policy Table rule alone (same
checks as `docs/runbooks/nat64-appliance-rebuild.md`'s "Verify:
private-NSP path" section). Then update this file with the result either
way:

- **If confirmed unnecessary:** note that here, and the manual UniFi
  config section above becomes the complete list of what's needed.
- **If it turns out to be required after all:** that's a genuinely new
  fact — record what actually broke without it, and note that the
  reasoning above (route next-hop is a real, already-resolved on-link
  address) was wrong, and why.

**Status as of 2026-09-28: unresolved, prediction untested.** Nobody has
yet done a rebuild without `ndppd` to check.
