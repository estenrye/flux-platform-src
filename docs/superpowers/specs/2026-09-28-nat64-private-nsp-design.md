# NAT64 for a Private-IPv4 Destination: a Second, NSP-Based Translation Path

Date: 2026-09-28
Status: Draft, awaiting review
Parent: [ADR-23](../../adr/0023-ipv6-only-cluster-ula-nat64.md) (IPv6-only
cluster, ULA addressing, NAT64/DNS64) and its amendments — this design adds
an amendment to that ADR rather than superseding it.

## 1. Problem

`nat64-01`'s existing NAT64/DNS64 path (Tayga + Unbound, the appliance
ADR-23 established) translates via the RFC 6052 **Well-Known Prefix**
(`64:ff9b::/96`). RFC 6052 §3.1 explicitly forbids embedding a non-global
(RFC 1918) IPv4 address in the WKP, and Tayga enforces this: confirmed live
(2026-09-27/28) against a real destination — `pcd.rye.ninja` resolves to
`10.45.45.45`, an internal address on a private OpenStack cloud ("PCD")
this fleet's `CloudControllerManager` work needs to reach — while the same
appliance's WKP path to a public destination (`github.com`) succeeds
(`HTTP 200`) over the identical tun device, dynamic pool, and upstream
routing. The WKP is structurally incapable of reaching this address; no
config change to the existing instance fixes it.

**Confirmed, not assumed:** `nat64-01` already has plain IPv4 reachability
to `10.45.45.45` (sub-millisecond `ping`, via its existing default route on
`10.64.64.0/24`) — nothing about *routing to PCD* needs to change, only
*how a client asks to get there*.

**A dead end worth recording, so it isn't re-investigated:** during live
debugging, `/etc/tayga.conf`'s `ipv6-addr` (`...::6401`) not matching
`/etc/default/tayga`'s `IPV6_TUN_ADDR` (`...::6402`, what the init script
actually binds to the tun interface) initially looked like a bug. It is
not: the IPv4 side uses the identical split
(`tayga_pool_gw = cidrhost(var.tayga_pool_cidr, 1)`, commented "tayga's
own v4 tunnel address", vs. the hardcoded `IPV4_TUN_ADDR="192.168.255.2"`)
and the appliance demonstrably works over this exact instance (the
`github.com` test above). Per `tayga.conf(5)`, `ipv4-addr`/`ipv6-addr` are
only the source address Tayga uses for its *own* generated ICMPv4/ICMPv6
errors and echo replies — a distinct role from the address the init
script binds to the tun interface for the kernel's own routing. The two
addresses are meant to differ; `.1` (self) and `.2` (tun) is this
appliance's established convention on both address families, applied
identically to the new instance below.

## 2. Non-goals

- A general mechanism for arbitrary future private hostnames. Scoped to
  `pcd.rye.ninja` only (see the design brainstorm's explicit choice). A
  second private hostname is one more `local-data` line, not a new
  mechanism.
- Changing anything about the existing WKP path, its addressing, or its
  systemd unit at all (see §1 — the `.6401`/`.6402` split is by design,
  not a bug to fix).
- Any Talos machine config or Crossplane composition change.
  `NAT64_ULA`/`NAT64_PREFIX` (`applications/crossplane-resources/xkubernetescluster/composition.yaml`)
  are untouched: per ADR-23's 2026-09-06 amendment, nodes reach the
  appliance via their **default route**, not a NAT64-specific static
  route, so a new prefix within the appliance's own already-routed `/64`
  needs no node-side awareness at all.
- A route from PCD's own network into the cluster, or any change on PCD's
  side. This is entirely appliance-local.
- Detecting or alerting on `pcd.rye.ninja`'s IPv4 address changing. The
  `local-data` override is a manually maintained value (see §5).

## 3. Design

### 3.1 A second, independent Tayga instance

Tayga is single-prefix-per-process. Reaching both the public internet (WKP,
which must stay public-IPv4-only per RFC 6052) and PCD's private range
needs two daemons on `nat64-01`:

| | Existing (public) | New (private) |
|---|---|---|
| tun device | `nat64` | `nat64priv` |
| prefix | `64:ff9b::/96` (RFC 6052 Well-Known Prefix) | `fd97:45c2:b3a1:64:65::/96` (Network-Specific Prefix — see §3.2) |
| dynamic pool | `192.168.255.0/24` | `192.168.254.0/24` |
| Tayga self-address (v4/v6) | `192.168.255.1` / `fd97:45c2:b3a1:64::6401` (unchanged, see §1) | `192.168.254.1` / `fd97:45c2:b3a1:64:66::1`¹ |
| tun interface address (v4/v6) | `192.168.255.2` / `fd97:45c2:b3a1:64::6402` | `192.168.254.2` / `fd97:45c2:b3a1:64:66::2`¹ |
| systemd unit | `tayga.service` (unchanged) | `tayga-priv.service` (new) |

¹ Corrected from an earlier `:65::1`/`:65::2` (inside the prefix itself)
after Tayga rejected that at startup; deliberately in a different `/96`
sub-block than the `:65::/96` prefix — see the runbook's "Gotchas found
rebuilding this path" section for why.

RFC 6052's private-IPv4 restriction applies only to the Well-Known Prefix;
a Network-Specific Prefix is the network operator's own address space, and
Tayga does not restrict what IPv4 ranges may be embedded in one.

### 3.2 The prefix: carved from the appliance's own `/64`, not a new allocation

`network.yaml`'s `vlan64` is explicitly a dedicated, client-free VLAN
("Only the appliance and the UniFi gateway itself are ever on this
segment") — confirmed no collision risk from any other host. Carving a
`/96` out of the *existing*, already-routed `fd97:45c2:b3a1:64::/64` (as
opposed to allocating a wholly separate `/64`) means **no new route
anywhere** — traffic to anything under `fd97:45c2:b3a1:64::/64` already
reaches this VLAN via the existing `vlan64` RA-advertised route; Tayga's
own init script installs the more-specific `/96` route to its tun device
locally, exactly as it already does for the WKP (`ip route add
"$IPV6_PREFIX" dev "$TUN_DEVICE"`, confirmed in `/etc/init.d/tayga`).

**Correction, confirmed live 2026-09-28 (Task 3) — the "no new route
anywhere" claim above is wrong:** being carved from an on-link,
already-routed `/64` does not make a more specific `/96` automatically
reachable from other VLANs. The site's router still has to be told to
deliver packets for that specific `/96` — being a sub-block of an
already-routed prefix isn't the same as being routed itself. Confirmed
live: `ping`/`curl` to the NSP address from a different VLAN (the
`controlplane` cluster, on its own peering VLAN) failed with an immediate
ICMPv6 "Destination unreachable: Address unreachable" from *that
cluster's own gateway* — an active rejection, not a timeout, and it
happened before the packet could ever reach the appliance's VLAN. NDP
proxying (`ndppd`) was installed and tested live on the appliance as a
candidate fix and made no difference, ruling it out as the (sole) cause —
the rejection happens before NDP resolution would ever be attempted. The
actual fix, added manually by the site operator, outside Terraform
(matching how `docs/memory/unifi-zone-firewall.md` already documents the
identical problem for the *existing* well-known-prefix path when it was
first stood up): a static route for `fd97:45c2:b3a1:64:65::/96` via the
appliance's own address (`fd97:45c2:b3a1:64::64`), plus a UniFi Policy
Table rule with Destination scope = IP for that specific `/96` (not a
zone-to-zone rule) — the same pattern already used for `64:ff9b::/96`. No
Terraform/Crossplane resource in this repo manages this kind of rule
(checked; none exists) — it's manual UniFi configuration, same as it was
for the well-known prefix.

What's still true from the reasoning above: the `/96` genuinely is
collision-free within the client-free `vlan64` segment (no other host on
that VLAN needed to be considered), and Tayga's own init script does
still install the more-specific local route to its tun device once
traffic actually arrives at the appliance — that part was never in
question and needed no change. What was wrong is the inference from
those two true facts to "no new route anywhere": carving the NSP from an
on-link `/64` saved a *second `/64` allocation*, not the router-level
route/firewall work needed to make the `/96` reachable from off-VLAN in
the first place.

Chosen prefix: `fd97:45c2:b3a1:64:65::/96` — the `65` (16th bit-group)
is unused by anything currently on this VLAN (`::1` gateway, `::64`
appliance, `::6401`/`::6402` Tayga, and one MAC-derived SLAAC address in
the `5054:...` range), so there is no risk of colliding with any existing
or future SLAAC-assigned address on this segment.

`10.45.45.45` embeds as `fd97:45c2:b3a1:64:65::a2d:2d2d`
(`0x0a2d2d2d` = `10.45.45.45`).

### 3.3 DNS64: a targeted override, not a second Unbound instance

Unbound's `dns64-prefix` is global to the instance — it cannot apply the
WKP to `github.com` and the new NSP to `pcd.rye.ninja` simultaneously.
Rather than run a second Unbound instance, add one static `local-data`
line (consistent with the existing `lan-forward.conf` split-horizon
pattern for `rye.ninja`) that bypasses DNS64 synthesis entirely for this
one name:

```
local-data: "pcd.rye.ninja. AAAA fd97:45c2:b3a1:64:65::a2d:2d2d"
```

### 3.4 NAT44

One more masquerade rule in `/etc/nftables.conf`'s existing `postrouting`
chain, for the new pool (`192.168.254.0/24`) out the `lan` interface —
mirroring the existing rule for `192.168.255.0/24`. This is what gives
translated packets to `10.45.45.45` a routable source address once they
leave `nat64-01`.

## 4. Files touched

All within `providers/kvm/`, no other repo, no other module:

- `modules/nat64-appliance/templates/user-data.yaml.tftpl`: new
  `write_files` entries — `/etc/tayga-priv.conf` (the second instance's
  Tayga config) and `/etc/systemd/system/tayga-priv.service`, a **native
  systemd unit**, not a `/etc/default/tayga-priv` env file plus an
  `/etc/init.d/tayga`-derived sysv script or a `tayga.service.d/mtu.conf`
  drop-in on a generated unit (an earlier draft of this section described
  both, matching the public instance's shape; neither exists in the
  committed template). This was the single most consequential design
  decision in this change: the packaged `/etc/init.d/tayga` script
  extracts `TUN_DEVICE`/`IPV6_PREFIX`/`DYNAMIC_POOL` via `sed` against the
  hardcoded path `/etc/tayga.conf`, not `/etc/$NAME.conf` — a renamed copy
  (`NAME=tayga-priv`) would still read the *original* WKP config for those
  values, misconfiguring the new instance against the *public* instance's
  tun device. `tayga-priv.service` instead calls `tayga` directly with
  `-c`/`--config` and `-p`/`--pidfile` (per `tayga(8)`) and does its own
  `ip link`/`ip addr`/`ip route`/MTU setup in `ExecStartPre`, needing no
  init-script copy or drop-in at all. Also new: an added `local-data` line
  (a new `unbound.conf.d/pcd-private.conf` drop-in, matching how
  `lan-forward.conf` is already split out rather than growing
  `dns64.conf`), an added masquerade rule in the existing `nftables.conf`
  block, and, in `runcmd`, a `mkdir -p /var/spool/tayga-priv` line (Tayga
  does not create its own `data-dir`), a `systemctl daemon-reload` (needed
  because `tayga-priv.service` is a hand-written unit systemd hasn't seen
  before, unlike `tayga.service`, which the sysv generator already
  produces at boot from the packaged init script), and `tayga-priv` added
  to the `systemctl enable --now`/`restart` lines. The existing
  `tayga.conf`/`default/tayga` blocks are untouched (see §1 — no bug
  there).
- `network.yaml`: two new lines under the existing `allocations.nat64_appliance`
  block — `tayga_priv_pool: 192.168.254.0/24` and
  `nat64_priv_prefix: fd97:45c2:b3a1:64:65::/96`.
- No changes to `variables.tf`, `main.tf`, or any file outside
  `providers/kvm/` — the new prefix/pool are literals in the template,
  matching how the existing WKP/pool are already hardcoded there rather
  than parameterized.

## 5. Operational notes

- **Staleness is accepted.** If `pcd.rye.ninja`'s IPv4 changes, the
  `local-data` line goes stale silently — wrong answers, not an error.
  This is the accepted cost of the "just this one host" scope (§2); a
  second private hostname is one more line in the same file, at the same
  cost.
- **Rebuild.** `nat64-01` is cattle (`docs/runbooks/nat64-appliance-rebuild.md`);
  both instances and the DNS override come back identically from the one
  template on any rebuild — but that is only true of the appliance's own
  config. **Correction:** the private-NSP path as a whole is not fully
  reproduced by a rebuild. The runbook's "One-time site-network setup"
  section documents a manual static route (`fd97:45c2:b3a1:64:65::/96` via
  the appliance's own address) and a UniFi Policy Table rule, made
  directly on the site's router/gateway, that are required for the `/96`
  to be reachable from off-VLAN at all — neither is created or restored by
  any `tofu apply`/rebuild of the appliance, since neither is a Terraform
  resource. A rebuild that doesn't also re-verify this manual config can
  silently leave the private path unreachable from other VLANs even
  though the appliance itself looks healthy.
- **Rollback.** Deleting the added `write_files`/`runcmd` lines and
  re-applying removes the private path's *appliance-side* config. The
  existing WKP instance, its unit, and its nftables rule are never touched
  by this change at all, so reverting carries no risk to public egress.
  **Correction:** "re-applying" here is not a bare `tofu apply`. This
  project separately confirmed (plan Task 3 Step 1; runbook "Gotchas")
  that a bare `tofu apply` for a template-only change does not actually
  rebuild the guest — `instance-id: nat64-01` never changes, so
  cloud-init's NoCloud datasource skips re-running `write_files`/`runcmd`
  for an instance-id it has already provisioned. `tofu taint` on the
  domain and volume resources is required first (see the runbook's
  "Rebuild" section). Also note rollback here is silent on the manual
  UniFi route/rule above: removing the template's `write_files` doesn't
  remove that gateway config, so a rolled-back appliance leaves an orphaned
  (harmless but stale) route/rule on the gateway until someone removes it
  by hand.

## 6. Testing

After `tofu apply`:

- `dig @fd97:45c2:b3a1:64::64 pcd.rye.ninja AAAA` → the NSP address
  (`fd97:45c2:b3a1:64:65::a2d:2d2d`), not a WKP or stale address.
- `systemctl status tayga-priv` → active; `nft list ruleset` shows the new
  masquerade rule.
- From a diagnostic pod on the cluster (as used throughout the live
  investigation): `curl https://pcd.rye.ninja/keystone/v3` → succeeds.
- **Regression check**: `curl https://github.com` still succeeds
  unchanged — confirms the existing WKP path, its unit, and its rule were
  not disturbed.
- Then: retry the `CloudControllerManager` live verification on the
  `controlplane` cluster (the actual motivating case) and confirm the CCM
  pod's `openstack.go` client initializes against Keystone.

## 7. ADR

This is an amendment to
[ADR-23](../../adr/0023-ipv6-only-cluster-ula-nat64.md), following the
same pattern as its 2026-07-15 and 2026-09-06 amendments: the "single
deliberate dual-stack exception" framing still holds; only the appliance
now runs two translation instances instead of one, for two genuinely
different traffic classes (public WKP, private NSP), each RFC
6052-compliant for what it carries.
