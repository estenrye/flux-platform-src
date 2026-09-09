# Move controlplane cluster's Calico BGP peering to dedicated VLAN 179

> **For agentic workers:** this plan follows the Flux GitOps workflow
> (`flux reconcile source git flux-platform -n flux-system && flux
> reconcile kustomization flux-platform -n flux-system` after every merge
> to `applications/**`), the `op read "op://vault/item/field"` convention
> for credential resolution (never print resolved secrets), and the
> Crossplane-unreachable manual-fallback pattern established in
> [2026-09-06-migrate-nat64-appliance-to-vlan-64.md](2026-09-06-migrate-nat64-appliance-to-vlan-64.md).
> Read the spec first:
> [2026-09-08-calico-bgp-peering-vlan179-design.md](../specs/2026-09-08-calico-bgp-peering-vlan179-design.md).

**Goal:** Move the `controlplane` cluster's Calico↔UniFi BGP peering
session addresses off VLAN 100 onto a new, dedicated, client-free VLAN 179
(`10.179.0.0/16`, `fd97:45c2:b3a1:179::/64`, SLAAC, no DHCPv4), eliminating
a confirmed-live packet-hairpin bug at the UniFi gateway that silently
drops every non-SYN packet in any TCP flow from a VLAN-100-resident client
to a BGP-advertised LoadBalancer VIP.

**Architecture:** UniFi Dream Machine (gateway + FRR/BGP) ↔ 6 Talos Linux
VMs on a KVM/libvirt hypervisor (`mf-ms-a2-01`) ↔ Calico (BGP mode, AS
64513) ↔ Flux-managed `controlplane` cluster. VLAN/network objects are
normally Crossplane-managed (`XNetworkSegment` + `XUnifiNetwork` →
Terraform `filipowm/unifi` provider), but the Crossplane management
cluster is currently unreachable — same blocker the NAT64 migration hit —
so this plan uses the declarative-claim-as-record + standalone-`tofu
apply` fallback throughout.

**Tech stack:** UniFi Controller (network objects via Terraform
`filipowm/unifi` provider, BGP/FRR via UI-only manual upload — no API
surface exists), OpenTofu (`providers/kvm/`), Talos machine config
(`talosctl`, `.bin/create-controlplane-cluster.sh`), Calico (Helm values +
`BGPPeer`/`Node` CRDs via `kubectl`), Flux (Kustomize + Helm rendering),
1Password CLI for the UniFi API credential
(`op://controlplane/unifi-os-external-dns/credential`).

## Key Facts

- **Root cause, confirmed live 2026-09-08**: `tcpdump -i br100` on the
  gateway during a real connection attempt (Designate host → pdns4-shim
  LoadBalancer VIP) showed client→server packets only — replies bypass the
  gateway via direct L2, but the client's own packets must hairpin back out
  `br100` because the BGP next-hop (a Talos node) is on-link on the same
  VLAN. The SYN survives (slow path); every subsequent packet in the flow
  is silently dropped. Reproduced on 5 of 6 nodes.
- **Same bug class, third occurrence**: this is the identical hairpin
  mechanism as the 2026-07-15 ADR-22 amendment (VIP pools moved off VLAN
  100) and the 2026-09-06 NAT64 migration (ADR-23 amendment). This time
  it's the BGP peering session addresses themselves, not the VIP pool.
- **No Terraform/API path for BGP/FRR config, at all.**
  `docs/memory/unifi-bgp-automation-investigation.md` confirms
  `filipowm/terraform-provider-unifi` has zero BGP resources; reverse
  engineering the UI's internal route was explicitly rejected as too
  risky in that investigation. `providers/kvm/unifi-frr.conf` stays the
  git-tracked declarative record, but every actual change requires a
  manual hand-upload via UniFi Network → Settings → Routing → BGP.
- **Every Talos VM has exactly one NIC today**
  (`providers/kvm/modules/talos-vm/main.tf`), bridged untagged to `br0`
  (VLAN 100). Attaching VLAN 179 is either free (Option A: 802.1Q
  sub-interface in Talos machine config, relying on `br0` transparently
  passing tagged frames through to the trunk) or expensive and risky
  (Option B: second NIC, new bridge, Terraform module change, `tofu
  apply` against live running VMs). **Verify Option A on one node before
  committing to a fleet-wide approach — this is the plan's single
  highest-uncertainty step (Task 3).**
- **Crossplane management cluster is unreachable**
  (`~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml` — stale
  hostname, same blocker as the NAT64 migration). `XNetworkSegment`/
  `XUnifiNetwork` claim YAML gets written as the declarative record; actual
  UniFi network creation happens via a standalone `tofu apply` against the
  same HCL shape the Composition would generate.
- **UniFi requires an IPv4 subnet to claim router ownership of a
  network**, even though VLAN 179 is IPv6-only in practice — `10.179.0.0/16`
  is configured with DHCP disabled, no host ever gets a lease.
- **Phased, dual-VLAN cutover** (user-approved): VLAN 100 stays in the BGP
  peer-group's listen range throughout piloting and fleet rollout; only
  removed in the final task, after fleet-wide verification.
- **Reproduction/verification methodology already proven this session**:
  `curl` loop from the Designate host against `https://pdns4-shim.rye.ninja/healthz`,
  correlated with `tcpdump` on whichever Talos node ECMP selects (ephemeral
  `hostNetwork: true` `nicolaka/netshoot` pods in `calico-system`, which has
  `pod-security.kubernetes.io/enforce: privileged`), and `br100` capture on
  the gateway. Reuse this exact methodology for every verification step
  below instead of inventing a new one.

## File Map

| File | Action | Description |
|---|---|---|
| `applications/crossplane-resources/xnetworksegment/examples/vlan179-bgp.yaml` | Create | Declarative `XNetworkSegment` claim record (not applied — Crossplane unreachable) |
| `applications/crossplane-resources/xunifinetwork/examples/vlan179-bgp.yaml` | Create | Declarative `XUnifiNetwork` claim record (not applied — Crossplane unreachable) |
| `providers/kvm/network.yaml` | Modify | Add `vlan179:` block (subnets, gateway addresses) to the address-book |
| `providers/kvm/unifi-frr.conf` | Modify | Add `bgp listen range fd97:45c2:b3a1:179::/64 peer-group CALICO`; later remove the two VLAN 100 ranges |
| `.bin/create-controlplane-cluster.sh` | Modify | `render_node()`: add a `vlans:` sub-interface block (VLAN 179, no static address, `dhcp: false`) for all 6 nodes |
| `applications/calico/controlplane/values.yaml` | Modify | `nodeAddressAutodetectionV6`: `kubernetes: NodeInternalIP` → `cidrs: ["fd97:45c2:b3a1:179::/64"]` |
| `applications/calico/controlplane/resources/bgp-peer.yaml` | Modify | `peerIP`: `2607:3640:1064:270::1` → `fd97:45c2:b3a1:179::1` |
| `docs/adr/0022-unifi-bgp-load-balancer-vips.md` | Modify | New `## Amendment 2026-09-08 (BGP peering isolated to VLAN 179)` section |
| `docs/runbooks/control-plane-cold-start.md` | Modify | Split the "VLAN 100 up" step into separate VLAN-100 and VLAN-179/BGP steps |

## Task 1: Write declarative Crossplane claim records for VLAN 179

**Files:** `applications/crossplane-resources/xnetworksegment/examples/vlan179-bgp.yaml`, `applications/crossplane-resources/xunifinetwork/examples/vlan179-bgp.yaml`

- [ ] Model both claims directly on `vlan64-nat64.yaml` in each directory —
      same shape, `vlanId: 179`, no `taggedVlan`/`bondInterface`/`bridgeName`
      override (this is a brand-new dedicated segment, not an existing
      bridge repurpose), `dhcp4: false`, `dhcp6: false` (SLAAC via RA, not
      stateful DHCPv6), `routes: {}`.
- [ ] `XUnifiNetwork` claim: `vlanId: 179`, `infraSubnet:
      "fd97:45c2:b3a1:179::/64"`, `ipv4Subnet: "10.179.0.1/16"`, IPv6 mode
      set to static ULA prefix with Router Advertisement/SLAAC enabled, no
      GUA.
- [ ] Add a short README note (matching the `xnetworksegment`/`xunifinetwork`
      example directories' existing `README.md` convention) stating these
      claims are records-only pending Crossplane cluster reachability, per
      the NAT64 precedent.
- [ ] Verify: `kubectl --dry-run=client apply -f <file>` against the
      `xnetworksegment`/`xunifinetwork` XRD schema (using any locally
      cached CRD, or `kubeconform` against the vendored XRD OpenAPI) to
      catch schema errors before they're needed for real.

## Task 2: Create the VLAN 179 network object in UniFi (manual `tofu apply`)

**Files:** none tracked (standalone apply, not part of the Flux-managed tree)

- [ ] Resolve the UniFi API credential:
      `op read "op://controlplane/unifi-os-external-dns/credential"`,
      pipe directly into the Terraform provider's auth (never echo it).
- [ ] Write a small standalone `.tf` (scratch, not committed — or commit
      under `providers/kvm/` only if this repo's convention tracks
      standalone UniFi resources outside Crossplane; check
      `providers/kvm/*.tf` for an existing precedent first) using
      `filipowm/unifi`'s `unifi_network` resource: VLAN 179, purpose
      `corporate` (matching VLAN 64/100's own purpose value — check via
      `terraform show`/UniFi UI on an existing network first), IPv4 subnet
      `10.179.0.0/16` with DHCP disabled, IPv6 static ULA
      `fd97:45c2:b3a1:179::/64` with RA enabled in SLAAC-only mode.
- [ ] `tofu apply`, confirm in the UniFi UI: network appears, no DHCP4
      range configured, IPv6 shows "SLAAC" (not DHCPv6), gateway addresses
      auto-assigned (`10.179.0.1`, `fd97:45c2:b3a1:179::1`).
- [ ] Update `providers/kvm/network.yaml` with the resulting `vlan179:`
      block (mirroring the existing `vlan64:`/`vlan100:` block shape) as
      the declarative record of what now exists, even though it was
      created out-of-band.

## Task 3: Verify Option A — VLAN 179 sub-interface over the existing single NIC (pilot: cp-1 only)

**Files:** none yet (temporary `talosctl patch`, not committed)

- [ ] `talosctl -n <cp-1 ip> get machineconfig` to confirm the current
      single-interface shape (expected: one `deviceSelector: {physical:
      true}` interface, static VLAN 100 address, no existing `vlans:`
      block).
- [ ] `talosctl patch machineconfig` (or `talosctl edit mc`) on `cp-1`
      only, adding under that same interface:
      ```yaml
      vlans:
        - vlanId: 179
          dhcp: false
      ```
      No `addresses:` for the VLAN sub-interface — SLAAC/RA applies
      automatically.
- [ ] Verify: `talosctl -n <cp-1 ip> get addresses` shows a new
      `fd97:45c2:b3a1:179::/64` address. **This is the gate**: if it
      does not appear within a normal RA interval, `br0`'s handling of
      guest-originated 802.1Q tags is the blocker — stop here, do not
      proceed to Task 4-9, and re-scope Option B as a separate plan
      given its live-cluster risk profile (new bridge, Terraform module
      change, second NIC + MAC per node, `tofu apply` against running
      VMs).
- [ ] If confirmed: revert this to a clean baseline mentally (it stays in
      place — Task 6 makes it permanent for cp-1 specifically, then
      extends to the rest).

## Task 4: Add the VLAN 179 BGP listen-range on the UniFi gateway (manual)

**Files:** `providers/kvm/unifi-frr.conf`

- [ ] Add a line to the tracked file (declarative record first, per this
      repo's established discipline for this specific file):
      ```
      bgp listen range fd97:45c2:b3a1:179::/64 peer-group CALICO
      ```
      Do not remove the two existing VLAN 100 ranges yet.
- [ ] Manually apply via UniFi Network → Settings → Routing → BGP (no
      API/Terraform path exists — confirmed dead end in
      `docs/memory/unifi-bgp-automation-investigation.md`).
- [ ] Verify: `ssh root@fd97:45c2:b3a1:100::1 'vtysh -c "show running-config"'`
      (read-only SSH use, per established convention — config changes go
      through the UI) shows the new listen range alongside the two
      existing VLAN 100 ones.

## Task 5: Pilot Calico's BGP address on VLAN 179 for cp-1 only (temporary, direct kubectl)

**Files:** none committed yet (temporary overrides, superseded by Task 7)

- [ ] Temporarily override `cp-1`'s Calico `Node` resource
      (`spec.bgp.ipv6Address`) to its new `fd97:45c2:b3a1:179::/64`
      address via `kubectl patch`/`calicoctl`.
- [ ] Temporarily patch the `BGPPeer` resource's `peerIP` from
      `2607:3640:1064:270::1` to `fd97:45c2:b3a1:179::1` — this affects
      the whole peer-group, so expect the other 5 nodes' sessions to drop
      and re-establish against the new peer IP too; if their own source
      address hasn't moved yet, confirm they still reach the gateway (same
      subnet reachability, VLAN 100 → gateway is not the hairpin path,
      only VLAN-100-client → VIP is).
- [ ] Verify BGP session: `vtysh -c 'show bgp ipv6 unicast summary'` on
      the gateway shows `cp-1`'s session sourced from
      `fd97:45c2:b3a1:179::/64`.
- [ ] Re-run the proven reproduction: repeated `curl` from the Designate
      host against `https://pdns4-shim.rye.ninja/healthz`, correlated via
      `tcpdump` on whichever node ECMP selects — confirm that attempts
      landing on `cp-1` now complete the full TLS handshake and return
      `200`, not just a SYN. Also re-check `br100` on the gateway during
      one of these attempts — no hairpin should be visible for the
      VLAN-179-sourced flow.
- [ ] **Gate**: only proceed to Task 6 once this pilot shows a sustained
      (5+ consecutive attempts landing on cp-1) 100% success rate,
      matching the pre-fix reproduction's own consistency (near-100%
      failure) as a fair comparison.

## Task 6: Roll Option A out to the remaining 5 nodes, make it permanent

**Files:** `.bin/create-controlplane-cluster.sh`

- [ ] Update `render_node()` to add the same `vlans:` block (VLAN 179, no
      static address, `dhcp: false`) uniformly for all 6 nodes — no
      per-role branching needed, unlike VIP-related blocks.
- [ ] Apply to `wk-1`, `wk-2`, `wk-3`, `cp-2`, `cp-3` via `talosctl patch
      machineconfig` per node (same shape as Task 3's pilot, now expected
      low-risk given the pilot succeeded).
- [ ] Verify: `talosctl -n <ip> get addresses` on each of the 5 shows a
      `fd97:45c2:b3a1:179::/64` address.

## Task 7: Flip Calico's fleet-wide node-address autodetection via Flux

**Files:** `applications/calico/controlplane/values.yaml`, `applications/calico/controlplane/resources/bgp-peer.yaml`

- [ ] `values.yaml`: change
      ```yaml
      nodeAddressAutodetectionV6:
        kubernetes: NodeInternalIP
      ```
      to
      ```yaml
      nodeAddressAutodetectionV6:
        cidrs: ["fd97:45c2:b3a1:179::/64"]
      ```
- [ ] `resources/bgp-peer.yaml`: confirm `peerIP` is
      `fd97:45c2:b3a1:179::1` (already patched live in Task 5 — this
      commits it as the permanent record).
- [ ] Open a PR, merge, then `flux reconcile source git flux-platform -n
      flux-system && flux reconcile kustomization flux-platform -n
      flux-system` (same flow used for the NetworkPolicy fix earlier this
      investigation).
- [ ] Remove the Task 5 temporary per-node `Node` resource override for
      `cp-1` now that the fleet-wide Helm value supersedes it.
- [ ] Verify: `kubectl get bgppeer -o yaml`, `calicoctl node status` (or
      equivalent) on all 6 nodes shows VLAN 179 addressing.

## Task 8: Verify fleet-wide

**Files:** none (verification only)

- [ ] `vtysh -c 'show bgp ipv6 unicast summary'` on the gateway: all 6
      sessions sourced from `fd97:45c2:b3a1:179::/64`.
- [ ] Repeated (10+) back-to-back `curl` attempts from the Designate host
      against both `pdns4-shim.rye.ninja` and at least one other
      LoadBalancer-fronted service (e.g. `id.rye.ninja`, per the original
      reproduction's own cross-check) — all succeed regardless of which
      node ECMP selects.
- [ ] `br100` capture on the gateway during a live attempt shows the flow
      never touches `br100` at all (neither end is VLAN-100-resident for
      this path anymore).
- [ ] Confirm Designate's own automatic retry loop (running throughout
      this whole investigation) successfully creates the pending
      `usmnblm01.rye.ninja` zone without manual intervention — the
      original goal that started this entire investigation.

## Task 9: Remove VLAN 100 from the BGP peer-group (final cutover)

**Files:** `providers/kvm/unifi-frr.conf`

**DONE 2026-09-09.** Was blocked on
[docs/memory/node-gua-onlink-reply-unreliable.md](../../memory/node-gua-onlink-reply-unreliable.md)
(ADR-28) until that was resolved the same day.

- [x] Remove both VLAN 100 listen-range lines
      (`fd97:45c2:b3a1:100::/64` and `2607:3640:1064:270::/64`) from the
      tracked file. (PR #200)
- [x] Manually apply via UniFi UI (same no-API constraint as Task 4).
      Applied by Esten on the UDM-SE.
- [x] Verify: `vtysh -c 'show bgp ipv6 unicast summary'` shows only VLAN
      179-sourced sessions; re-run one final reproduction pass to confirm
      nothing regressed. **Confirmed**: all 6 sessions re-established
      cleanly on VLAN 179 within seconds of the config reload (same
      route counts recovered, 18 received/1 sent each), running-config
      shows only the VLAN 179 listen range. `pdns4-shim.rye.ninja` still
      reachable (`HTTP 200`, ~84ms) from a VLAN-100 client. Full cluster
      health clean: all 6 nodes `Ready`, no non-`Running` pods.

**Migration complete.** Both the peering-address move (this plan) and the
underlying on-link reply-drop bug that blocked its final step (ADR-28,
`applications/vlan100-onlink-routing-fix/`) are resolved.

## Task 10: Documentation updates

**Files:** `docs/adr/0022-unifi-bgp-load-balancer-vips.md`, `docs/runbooks/control-plane-cold-start.md`

- [ ] Add `## Amendment 2026-09-08 (BGP peering isolated to VLAN 179)` to
      ADR-22, in the same dated-subsection prose style as the existing
      2026-07-15 amendment — state the hairpin recurrence at the peering
      layer, the fix, and a pointer to this plan and its spec.
- [ ] Split `control-plane-cold-start.md`'s step that currently conflates
      "VLAN 100 up" with "BGP enabled" into two separate line items
      (VLAN 100 connectivity vs. VLAN 179 BGP peering).
- [ ] Capture a closing OpenBrain thought summarizing root cause → fix →
      verification, cross-linked to the two prior same-bug-class
      incidents already in the knowledge graph.

## Automatable vs. manual summary

| Step | Automatable | Manual |
|---|---|---|
| Crossplane claim records | Yes (git commit) | — (not applied — cluster unreachable) |
| VLAN 179 network object in UniFi | Partial (`tofu apply` against provider directly) | Confirmation via UniFi UI |
| BGP listen-range add/remove | No | UniFi UI hand-upload (no API/Terraform surface exists) |
| Talos VLAN 179 sub-interface | Yes (`talosctl patch`, scripted) | — |
| Calico node-address/BGPPeer config | Yes (Flux PR + reconcile) | — |
| Verification (curl/tcpdump/BGP summary) | Partial (scriptable) | Judgment calls on "is this a clean pass" |
| ADR/runbook updates | Yes (git commit) | — |
