---
name: designate-pdns4-shim-gotchas
description: Designate (PCD) + pdns4-shim operational traps found moving the shim to core-infra: pool nameserver host must be an IP, designate-worker caches the pool, pdns4 backend never re-creates zones, NOTIFY target is dnsmasq
metadata:
  type: project
---

Found 2026-11-11 moving pdns4-shim from controlplane to core-infra (plan:
`docs/superpowers/plans/2026-11-10-pdns4-shim-to-core-infra.md`). Each was reproduced, not assumed.

- **Pool `nameservers[].host` must be an IP.** The ovo field `IPOrHost` accepts a hostname in its constructor (and
  `coerce`) but rejects it in `from_primitive`, so `designate-manage pool update` fails over RPC with
  `failed to detect a valid IP address`. Reading the code is not enough: round-trip the object on `designate-central`.
  `targets[].options.*` are free-form strings, so a hostname works there.
- **A pool change is not live until `pf9-designate-worker` restarts.** It lazily caches each pool in `pools_map`; it kept
  polling the old VIP for 8 min and every zone sat `PENDING UPDATE`. Restart on `pcd-ce-hyp-01`; zones go `ACTIVE` in ~40 s.
- **The pdns4 backend only has `create_zone`/`delete_zone`; `update_zone` is a no-op.** Existing zones are never re-created on a
  new shim. Copy the shim's `DNSEndpoint` objects (its state) instead, once, with kubectl, not via Flux.
- **NOTIFY goes to `targets[0].options.host`.** It was `10.45.60.1` (a dnsmasq that ignores NOTIFY), so record changes never
  reached the shim; fixed 2026-11-11 by setting it to `pdns4-shim.rye.ninja` (free-form `options` accept a hostname over RPC).
  Manual NOTIFY for debugging: `dig +opcode=notify +aaflag +norecurse @<VIP> -p 53 SOA <zone>`. Changing a zone's description
  in Designate is a harmless way to trigger a NOTIFY and prove the path.
- Two Designate installs exist on the hypervisor: `/opt/pf9/pf9-designate` (py3.12, what `designate-manage` runs) and
  central's `/var/lib/openstack` (py3.10 in the `designate-central` pod). Check the one that fails.
- Neutron SGs filter a Gateway VIP's traffic at the node port: each exposed protocol/port needs a group on the Talos ports
  ([[core-infra-nfs-outage-2026-11]] lists the others; `talos-dns` is 53/udp).
- A failed `ssh_resource` apply leaves Terraform state ahead of reality; re-apply `main` to resync (an identical
  `pool update --delete` still bumps every zone serial).

**Why:** these cost hours and two of them (hostname, stale worker) looked like success until the zones stayed PENDING.
**How to apply:** before touching Designate's pool, snapshot `designate-manage pool show_config` and the zone list; after,
restart the worker and wait for all zones ACTIVE; test with a throwaway recordset and a manual NOTIFY.
