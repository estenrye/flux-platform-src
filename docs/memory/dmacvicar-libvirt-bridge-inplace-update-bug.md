---
name: dmacvicar-libvirt-bridge-inplace-update-bug
description: dmacvicar/libvirt's network_interface changes (bridge change, or adding a whole new block) on an already-running domain report Terraform success but never touch the real libvirt XML (persistent or live) -- confirmed via plain tofu apply, not Crossplane-specific; research task, evaluate Ansible or an alternative provider
metadata:
  type: project
---

Found live 2026-08-05 debugging why `observability`'s nodes were unreachable
even after every UniFi/network-layer fix (VLAN purpose, IPv4 subnet, RA all
confirmed correct and working end-to-end via `rdisc6` from the KVM host
itself). Root cause was several layers below all of that: the VMs were
never actually attached to `br200` at all.

**What happened:** `cluster-talos-kvm-composition.yaml`'s `create-workspace`
step picked up `observability`'s new dedicated bridge (via `XNetworkSegment`
and `vlanRef`) and passed `bridge: "br200"` into the `talos-cluster`
Terraform module's `hosts` varmap. The `Workspace` (`tf.m.upbound.io`)
reconciled to `SYNCED=True, READY=True` with no errors, and its rendered
module varmap correctly showed `"bridge": "br200"`.

**But it was never actually applied.** `virsh domiflist observability-cp-1`
showed the live interface still on `br0`. `virsh dumpxml --inactive` (the
persistent, on-disk domain definition) showed `br0` too -- not just a
live/hotplug gap, the change never even reached the saved XML. Terraform
reported success on a change it silently never made.

**Working theory, not confirmed against dmacvicar/libvirt's own source:**
`network_interface.bridge` is likely a `ForceNew` (replace-on-change)
attribute for an existing `libvirt_domain`, and something in how
provider-terraform/Crossplane's `Workspace` drives the underlying `tofu`
run doesn't correctly surface that as a real diff -- possibly because each
Workspace reconcile is closer to a fresh `apply` against persisted state
than an interactive `plan`+`apply` cycle a human would notice drift in.

**Workaround applied (M4, not a real fix):** deleted the `observability`
`Workspace` entirely (`deletionPolicy: Delete`, so this ran a real `tofu
destroy` of the pool/ISO/all three domains+volumes), letting
`XKubernetesCluster`'s Composition recreate it fresh -- a clean `tofu
apply` from empty state applies `bridge: "br200"` correctly from the start,
since there's no in-place update path being silently skipped. Acceptable
here only because the cluster had never successfully bootstrapped, so there
was no real state to lose.

**Second, unrelated blocker hit executing that same workaround:** the
`tofu destroy` this triggered stalled for ~30 minutes retrying
`cannot destroy 'vmpool/vms/observability-cp-N-system': volume has
children` -- the KVM host's nightly ZFS replication-to-TrueNAS job
(`providers/kvm/scripts/zfs-replicate-vms.*`) leaves `@weekly-*`/
`@nightly-*` snapshots on every node volume, and libvirt's own ZFS storage
backend driver shells out to a bare `zfs destroy` (no `-r`) -- unrelated to
the bridge bug above, but hits the identical taint-and-recreate path,
documented as its own runbook step in
[talos-node-replace.md](../runbooks/talos-node-replace.md#before-you-taintdestroy-clear-zfs-snapshots-first)
rather than automated here (see the research task below, item 3).

## Second confirmed occurrence, 2026-09-08 (rules out the Workspace theory)

Found again rolling out `controlplane`'s VLAN 179 second NIC
([2026-09-08-calico-bgp-peering-vlan179-design.md](../superpowers/specs/2026-09-08-calico-bgp-peering-vlan179-design.md)):
adding a brand-new `network_interface` block (not changing `.bridge` on an
existing one) to all 6 already-running `controlplane` domains via a
**plain, direct `tofu apply`** — no Crossplane, no `Workspace`, no
`provider-terraform` in the path at all. Same exact symptom: `Modifications
complete after 0s`, state correctly showed both `network_interface` blocks
afterward, but `virsh domiflist`/`dumpxml` (live and persistent) on the KVM
host showed only the original interface on every node.

This **rules out** the original working theory that Crossplane's
`Workspace` reconcile loop was suppressing a force-replacement diff — the
exact same silent no-op happens with a bare `tofu apply` in an interactive
terminal. This is squarely a `dmacvicar/libvirt` provider bug (confirmed
version: whatever `~> 0.8` resolved to for `providers/kvm/controlplane` as
of this date), not an artifact of how Crossplane drives `tofu`.

**Lower-risk workaround this time** (the domains already held real,
non-disposable state — an etcd quorum, unlike `observability`'s
never-bootstrapped case above): `virsh attach-device <domain> <iface.xml>
--live --config` per node, hand-authoring the interface XML to match what
Terraform's own state already recorded. No reboot, no destroy/recreate,
one node at a time with etcd-health verification between each. State and
reality matched afterward with no further Terraform involvement needed —
future `tofu plan`s against these domains show no drift, exactly the trap
that makes this bug dangerous (state already says "done" the moment the
buggy apply "succeeds").

## Research task for later

This is a real gap worth investigating properly, not living with
indefinitely -- a future in-place network change on ANY talos-kvm cluster
(not just this one) would hit the identical silent-no-op:

1. **Confirm the actual root cause** against `dmacvicar/libvirt`'s source
   (is `network_interface.bridge` really `ForceNew`? does Crossplane's
   `Workspace`/provider-terraform correctly run `plan` before `apply`, or
   does something about its reconcile loop suppress force-replacement
   diffs?).
2. **Evaluate replacing `dmacvicar/libvirt` with a different Terraform
   libvirt provider** that handles this correctly, if one exists and is
   actively maintained (mirrors the `paultyng/unifi` archival lesson from
   the same milestone -- confirm current maintenance status before
   committing, don't assume the incumbent is still the right choice).
3. **Evaluate moving KVM VM lifecycle management to Ansible instead of
   Terraform** (the `provider-ansible` install and bridge-creation pattern
   from this same milestone, `applications/crossplane-providers/
   provider-ansible/`, is already available and proven -- would extending
   that pattern to VM provisioning avoid this whole class of bug, or just
   trade it for a different one?). Any concrete plan here inherits the
   Remote-vs-Inline and monorepo-subdirectory constraints already
   documented for `provider-ansible` -- see the `AnsibleRun` role-source
   limitation this same milestone hit (`providers/kvm/ansible/roles/
   bridge/` is a reference copy, not git-sourced, for exactly this reason).
   Would also be the natural place to fix the ZFS-snapshot-blocks-destroy
   issue above with a real pre-destroy cleanup task, instead of the manual
   runbook step it's documented as for now.

Not scheduled against a specific milestone step yet -- flagged here so it
isn't lost, not because it's blocking anything today.
