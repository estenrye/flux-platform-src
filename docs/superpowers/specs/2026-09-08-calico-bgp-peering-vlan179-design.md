# Calico BGP Peering Design: Dedicated VLAN 179

Date: 2026-09-08
Status: **Proposed.** Root cause confirmed live (extensive `tcpdump`
reproduction from a real consumer — see §1); design not yet executed.
Parent: amends [ADR-22](../../adr/0022-unifi-bgp-load-balancer-vips.md)
(UniFi BGP); same bug class as ADR-23's 2026-09-06 NAT64 amendment and the
2026-08-04 `observability` VLAN 200 incident
(`docs/memory/m4-step-tracker.md` step 5).
Execute: before any other VLAN-100-resident client needs to reach a
cluster LoadBalancer VIP — the bug is 100%-reproducible today for any such
client, not edge-case.

## 1. Problem

ADR-22's 2026-07-15 amendment moved the LoadBalancer **VIP pools**
(`lb-internal-ula-routed`, `lb-ingress-gua-routed`) off VLAN 100 onto
routed, no-VLAN prefixes — that fixed clients NDP'ing for VIPs instead of
routing. It did not touch the **BGP peering session addresses**: Calico
nodes still peer from their VLAN 100 SLAAC/InternalIP addresses
(`fd97:45c2:b3a1:100::11-13, ::21-23`), and the `BGPPeer` targets the
gateway's VLAN 100 GUA (`2607:3640:1064:270::1`). Because the ECMP
next-hops advertised for the (now-routed) VIP prefixes are themselves still
on VLAN 100, any VLAN-100-resident client hitting a VIP triggers the exact
same hairpin bug the VIP-pool move was supposed to eliminate — just at a
different layer.

**Confirmed live** (2026-09-08, using a real consumer — an OpenStack
Designate host on VLAN 100 calling `pdns4-shim.rye.ninja`, a
`pdns4-shim`-backed Gateway API HTTPRoute behind Envoy's shared LoadBalancer
Service): `tcpdump -i br100` on the gateway during a live connection
attempt showed **only client→server packets, never server→node** — replies
bypass the gateway entirely via direct L2 (the Talos node sees the client's
address as on-link, same `fd97:45c2:b3a1:270::/64` — [sic, ULA/GUA both
apply], and answers directly), while the client's own packets must hairpin
through the gateway (arrive on `br100`, route-lookup resolves the ECMP
next-hop to a Talos node also on `br100`, re-transmit back out the same
interface). The SYN survives this (first-packet/slow-path), but the very
next packet from the same flow — the client's ACK, piggybacked with the
TLS ClientHello — is silently dropped, every time, on every node tested
(reproduced identically on 4 of the 6 Talos nodes across the
investigation: `cp-1`, `cp-3`, `wk-1`(recheck), `wk-2`, `wk-3`). No
`ctstate INVALID` drops, no NIC errors, no LACP/bonding issue, no FRR
nexthop-group quirk found on the client's own path — all individually
ruled out. Root cause is squarely the same-VLAN client/peer overlap ADR-22
already names for the VIP-pool case, now recurring for the peering session
itself.

`docs/memory/m4-network-architecture-no-isolation-requirement.md`'s
governing principle — dedicated VLANs exist in this fleet only to fix this
exact hairpin bug class, not for isolation — applies cleanly here: a
distinct subnet is *required*, not a preference.

## 2. Design

Move the BGP peering session itself — not the VIP pools, which are already
correctly placed — off VLAN 100 onto a new, dedicated, **client-free** VLAN
179:

- `10.179.0.0/16` IPv4 (required by the `XUnifiNetwork`/`unifi_network`
  Terraform shape even for an IPv6-only concern — UniFi won't claim router
  ownership of a network with no IPv4 subnet — but DHCP stays off; nothing
  ever gets a lease here).
- `fd97:45c2:b3a1:179::/64` IPv6 ULA, SLAAC (Router Advertisement, no
  DHCPv6, no GUA — this segment never needs to be internet-routable, unlike
  the ingress VIP prefix).
- No clients, no other appliances, ever placed on this VLAN. That's the
  entire fix: once nothing is ever on-link with a BGP next-hop, the hairpin
  condition cannot occur, for any current or future VLAN-100/101 client,
  permanently.

Concretely, per the reusable pattern from the 2026-09-06 NAT64 migration
(same bug class, same fix shape):

1. **New segment**: an `XNetworkSegment` claim (`vlanId: 179`, brand-new
   dedicated shape — no `taggedVlan`/`bondInterface`/`bridgeName` override,
   `dhcp4`/`dhcp6: false`, `routes: {}` — a nested route here is exactly
   the bug this fixes, same warning the XRD schema itself carries) and an
   `XUnifiNetwork` claim (`vlanId: 179`, `infraSubnet:
   "fd97:45c2:b3a1:179::/64"`, `ipv4Subnet: "10.179.0.1/16"`). **Crossplane
   is currently unreachable** (`~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml`
   → stale hostname, same blocker the NAT64 migration hit) — claims get
   written as the declarative record, same as `vlan64-nat64.yaml`, but the
   actual UniFi network object gets created via a standalone `tofu apply`
   using the `filipowm/unifi` provider directly (same HCL shape the
   Composition would generate — see the plan), authenticated with the
   `op://controlplane/unifi-os-external-dns/credential` 1Password item.
2. **Calico's node address moves to the new VLAN**: `nodeAddressAutodetectionV6`
   in `applications/calico/controlplane/values.yaml` changes from
   `kubernetes: NodeInternalIP` to a `cidrs: ["fd97:45c2:b3a1:179::/64"]`
   match. `resources/bgp-peer.yaml`'s `peerIP` moves from the gateway's
   VLAN 100 GUA to its new VLAN 179 ULA gateway address
   (`fd97:45c2:b3a1:179::1`, assigned automatically once the network
   exists, same convention as `vlan64.ipv6_gateway_ula`).
3. **Gateway's FRR listen-range** gains `fd97:45c2:b3a1:179::/64` for the
   `CALICO` peer-group (`providers/kvm/unifi-frr.conf`, updated in git as
   the declarative record). **No Terraform/API path exists for this
   specifically** — `docs/memory/unifi-bgp-automation-investigation.md`
   confirms `filipowm/terraform-provider-unifi` has zero BGP/FRR resources,
   and reverse-engineering the UI's route is explicitly rejected as too
   risky. This is a manual hand-upload via UniFi Network → Settings →
   Routing → BGP, same discipline ADR-22 and the July migration already
   established for this file.
4. **Each of the 6 Talos VMs gets a VLAN 179 interface.** This is the one
   genuinely open technical question (§3) — every VM today has exactly one
   libvirt `network_interface` (`providers/kvm/modules/talos-vm/main.tf`),
   bridged to `br0` (VLAN 100, untagged/native). Two options:

   - **Option A (preferred, verify first): VLAN sub-interface, zero
     Terraform change.** Add a `vlans: [{vlanId: 179, dhcp: false}]` block
     under the existing single `deviceSelector: {physical: true}` interface
     in each node's Talos machine config (a one-line change to
     `.bin/create-controlplane-cluster.sh`'s `render_node()`, applied to
     all 6 nodes uniformly — no per-role branching needed, unlike the VIP
     block). This relies on `br0` being a plain, non-VLAN-filtering Linux
     bridge (confirmed: `taggedVlan: false` in its `XNetworkSegment` claim)
     transparently passing an 802.1Q-tagged frame the *guest* originates
     straight through to the trunk on `bond0` — standard Linux bridging
     behavior, but **not yet verified for this specific host/switch
     combination** in this repo. No `addresses:` needed for the VLAN
     sub-interface — omitting it accepts SLAAC/RA automatically, matching
     "no DHCP4, SLAAC for IPv6."
   - **Option B (fallback, real risk on a live cluster): second NIC.**
     Requires a new `br179` bridge (the `XNetworkSegment`'s own bridge, this
     time actually used for VM traffic, not just host-side reachability), a
     `talos-vm` module change to add a second `network_interface` block
     plus a second deterministic MAC per node (the current scheme is
     one-octet-per-node, already excludes `0x64`), a `deviceSelector`
     change from `physical: true` (ambiguous with two NICs) to a
     MAC-or-PCI-slot selector for *both* interfaces on *every* node, and a
     `tofu apply` against the live running cluster's VM definitions — risk
     of a reboot/recreate per node, unlike NAT64's destroy/recreate-friendly
     single appliance. Only pursued if Option A's live test (plan Task 3)
     fails.

## 3. Open question requiring live verification before committing to Option A vs B

Does a VM-originated 802.1Q-tagged (VLAN 179) frame, sent out the guest's
existing single NIC (attached to `br0`, VLAN 100's untagged bridge), reach
the physical switch with its tag intact and get treated as VLAN 179
traffic — or does the untagged bridge/bond path strip, drop, or
mis-classify it? This is answered empirically and cheaply: pilot the
change on a single node (`controlplane-cp-1`) first, entirely reversible
(a `talosctl` machine-config patch, no Terraform, no reboot expected), and
check whether it gets a `fd97:45c2:b3a1:179::/64` SLAAC address before
rolling out further. See plan Task 3.

## 4. Migration order (phased — both VLANs run in parallel until verified)

1. Create VLAN 179 (UniFi network + FRR listen-range addition, VLAN 100's
   ranges *not* removed yet).
2. Pilot Option A on `controlplane-cp-1` only; verify it gets a VLAN 179
   address. If it fails, fall back to Option B (re-scope as a separate,
   larger plan given the live-cluster risk — not detailed further here).
3. Pilot Calico's BGP source address for `cp-1` only (temporary, direct
   `kubectl` override on its Calico `Node` resource — not the fleet-wide
   Helm value yet), confirm the BGP session re-establishes over VLAN 179
   and that the original reproduction (§1) now succeeds when ECMP selects
   `cp-1`.
4. Roll Option A out to the remaining 5 nodes.
5. Flip the fleet-wide `nodeAddressAutodetectionV6` Helm value via a normal
   PR; remove the temporary per-node override.
6. Verify fleet-wide (all 6 sessions on VLAN 179, sustained repeated
   reproduction attempts all succeed).
7. Remove VLAN 100's two listen ranges from the gateway's `CALICO`
   peer-group — closing the loop.

## 5. Consequences

- Fixes the hairpin bug for BGP peering permanently and fleet-wide, not
  just for the Designate consumer that surfaced it — any future
  VLAN-100/101-resident client reaching a cluster LoadBalancer VIP benefits.
- A new manual-maintenance surface: `unifi-frr.conf`'s hand-upload
  discipline now also covers the peering-range lines, not just the VIP
  prefix-list (same file, same process, marginally more content to keep in
  sync).
- If Option A's live-bridging assumption turns out false, this becomes a
  materially larger, higher-risk change (Option B) against a live
  production cluster — the pilot-first sequencing in §4 exists specifically
  to surface that early and cheaply, before any fleet-wide commitment.
- `docs/runbooks/control-plane-cold-start.md`'s step 1 currently conflates
  "VLAN 100 up" with "BGP enabled" — becomes two separate line items
  post-migration (see plan's docs task).
- Does not touch: the LoadBalancer IP pools (already correctly routed,
  ADR-22 2026-07-15 amendment), the Talos apiserver VIP (deliberately not
  BGP-advertised per ADR-22's original decision), or the separate, still-open
  `externalTrafficPolicy: Local` ECMP-advertisement quirk (mitigated via
  Envoy anti-affinity, unrelated to this bug) or the separate, still-open
  pod-egress-GUA-routing bug (`docs/memory/pod-egress-gua-routing-broken.md`
  — different bug, same general Calico/BGP surface area, do not conflate
  during post-migration validation).
