---
name: unifi-bgp-automation-investigation
description: Investigated automating unifi-frr.conf's BGP config changes under XNetworkSegment provisioning — no Terraform provider support exists; two risky paths identified, neither attempted
metadata:
  type: project
---

Investigated 2026-08-05 at Esten's request, after the third of three
stacked bugs blocking `observability`'s bootstrap Job turned out to be a
missing BGP route (`fd97:45c2:b3a1:200::/64` never advertised to
Calico) in the hand-maintained `providers/kvm/unifi-frr.conf` — the file
was correctly identified as needing an update, but that update, like
the firewall zone below, wasn't part of `XNetworkSegment` provisioning
itself, so it was silently missed until the bootstrap Job failed live.
Companion investigation to [[unifi-zone-firewall]]'s new section, which
WAS fixed at the source this session (`firewall_zone_id` on
`unifi_network`, confirmed to exist in the Terraform provider). BGP
did not have an equivalent fix available.

## No Terraform-native path exists

Checked `filipowm/terraform-provider-unifi`'s full resource and data
source list (provider docs). Confirmed: zero resources or data sources
related to BGP, dynamic routing, or FRR configuration. Everything the
provider exposes is Settings-panel/network/firewall/DNS scoped — BGP
peering and route/prefix-list config isn't modeled at all.

This isn't a gap in an otherwise-complete provider -- the *original*
M1 design (`docs/superpowers/specs/2026-07-11-m1-controlplane-cluster-design.md`
§ tradeoffs table) already identified "UniFi BGP config is manual
upload" as a known limitation and explicitly accepted it, mitigated by
"config lives in git (`unifi-frr.conf`) + runbook step + drift check"
— not by automation. `unifi-frr.conf`'s own header claims "the network
chainsaw suite drift-checks the running config against it," but no
`chainsaw-test.yaml` anywhere in the repo actually references
`unifi`/`frr`/`vtysh` — that claim appears aspirational, not a real
implemented check. Worth confirming/fixing independently of the BGP
automation question.

## Two possible automation paths, neither attempted

1. **Reverse-engineer the Network Application's own REST API** for the
   Settings → Routing → BGP upload form. This is UniFi's real
   config-management pipeline (the GUI presumably stores the pasted
   FRR text in its own DB/config store, then pushes it to the gateway's
   real FRR instance as part of normal provisioning) -- the safest
   option *if* it can be found, since it wouldn't fight the
   controller's own reprovisioning. Undocumented and version-fragile;
   finding it needs a human at the actual browser UI with devtools open
   (Network tab) while clicking Upload, to capture the real request --
   not something discoverable by reading docs or provider source.

2. **Write directly to the gateway's live FRR config via SSH/Ansible**
   (`vtysh -f <file>` or equivalent), mirroring the bridge-creation
   pattern already proven for `providers/kvm/ansible/roles/bridge/` and
   `provider-ansible`. Technically straightforward given SSH access
   already exists, but real risk: the GUI's stored copy is very likely
   still the controller's source of truth, and a future reprovision
   (any other UI change, a firmware update, a periodic sync) could
   silently overwrite or revert a config pushed this way, with no
   drift-check to catch it. This path bypasses UniFi's own config
   system rather than integrating with it.

## Recommendation

Neither path attempted -- both need either live browser-based API
discovery (option 1) or accepting real drift risk (option 2), and this
wasn't urgent enough to justify either mid-incident. Flagging as a
deferred research item, same as [[dmacvicar-libvirt-bridge-inplace-update-bug]]:
worth doing properly before the next `XNetworkSegment`-provisioned
cluster hits the identical missing-BGP-route gap, not before. If
pursued, option 1 first -- lower long-term risk if it can be found at
all.
