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
| Tayga self-address (v4/v6) | `192.168.255.1` / `fd97:45c2:b3a1:64::6401` (unchanged, see §1) | `192.168.254.1` / `fd97:45c2:b3a1:64:65::1` |
| tun interface address (v4/v6) | `192.168.255.2` / `fd97:45c2:b3a1:64::6402` | `192.168.254.2` / `fd97:45c2:b3a1:64:65::2` |
| systemd unit | `tayga.service` (unchanged) | `tayga-priv.service` (new) |

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
  `write_files` entries (`/etc/tayga-priv.conf`, `/etc/default/tayga-priv`,
  `/etc/systemd/system/tayga-priv.service.d/mtu.conf`), an added
  `local-data` line (a new `unbound.conf.d/pcd-private.conf` drop-in,
  matching how `lan-forward.conf` is already split out rather than
  growing `dns64.conf`), an added masquerade rule in the existing
  `nftables.conf` block, and `tayga-priv` added to `runcmd`'s
  `systemctl enable --now`/`restart` lines. The existing `tayga.conf`/
  `default/tayga` blocks are untouched (see §1 — no bug there).
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
  template on any rebuild.
- **Rollback.** Deleting the added `write_files`/`runcmd` lines and
  re-applying removes the private path entirely. The existing WKP
  instance, its unit, and its nftables rule are never touched by this
  change at all, so reverting carries no risk to public egress.

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
