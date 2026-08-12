# XKubernetesCluster Lifecycle Suite (M4 step 6, Tier B)

Real, end-to-end chainsaw coverage for `XKubernetesCluster`: provisions an
actual minimal cluster (1 control-plane node, 0 workers) and proves that
deleting the claim garbage-collects every composed resource with no orphans
-- the same class of bug this fleet has already hit once in production
([provider-ansible delete-cleanup bug](../../docs/memory/provider-ansible-delete-cleanup-broken.md)).

See [docs/superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md](../../docs/superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md)
§8 step 6 and [applications/crossplane-resources/xkubernetescluster/](../../applications/crossplane-resources/xkubernetescluster/).

## Real infra cost (read before running)

Unlike [tests/xkubernetescluster-validation](../xkubernetescluster-validation/)
(Tier A), this suite provisions for real:

- A real KVM VM via `provider-terraform` (Talos, ~1 CP node) on the fleet's
  single, already-capacity-tight KVM host (M4 design D1).
- A real Talos bootstrap (schematic lookup, machine secrets, machine-config
  apply, etcd bootstrap) via the `talos-cluster-bootstrap` Job.
- A real AWS Route53 hosted zone + Cloudflare NS records
  (`xkc-lifecycle-test.rye.ninja`), via the composed DNS delegation.

Expect **~10-20 minutes** end to end (provision + teardown). Not free, not
instant -- run deliberately, not casually, and get explicit sign-off before
the first live run on a given day (matches this milestone's diligence for
every other real-infra step).

## One-time prerequisite: platform-kvm-network fixture entry

`validate-network-allocation` requires a `platform-kvm-network` entry named
`xkc-lifecycle-test` before the claim can provision (same requirement as any
real claim -- this suite deliberately does **not** bypass that check). Add
this entry to
`clusters/controlplane/crossplane-resources/crossplane.environment-config.kvm-network.yaml`'s
`data.clusters` map (disjoint node-ULA octets from `controlplane`
[`0x10-13`/`0x21-23`], `observability` [`0x30-33`], and NAT64 [`0x64`] --
same MAC-collision reasoning documented in that file's own comments; `0x40`
range is the next free block):

```yaml
    xkc-lifecycle-test:
      apiserverVip: "fd97:45c2:b3a1:100::40"
      infraSubnet: "fd97:45c2:b3a1:100::/64"
      podCidr: "fd97:45c2:b3a1:1300::/56"
      serviceCidr: "fd97:45c2:b3a1:2200::/112"
      bgpAsn: 64515
      controlPlaneNodeUlas:
        xkc-lifecycle-test-cp-1: "fd97:45c2:b3a1:100::41"
      workerNodeUlas: {}
```

This is a real, git-tracked fleet config change (same review path as any
other) -- add it via a normal PR, merged and synced before running this
suite, not hand-patched onto the live cluster. Leave the entry in place
between runs (it costs nothing when no claim references it); this suite's
own claim is the only thing that ever provisions against it.

## Running

```bash
.bin/run-xkubernetescluster-lifecycle-test.sh
```

Runs against `controlplane`. Fails fast with a clear message if the
`platform-kvm-network` fixture above hasn't been added yet.

## What it proves

1. The claim reaches real `status.phase: Ready` (VM + Talos + DNS all
   resolved) within a generous timeout.
2. The composed `Workspace`, bootstrap `Object`, both connection Secrets,
   and both `Usage` guards (M4 step 6) are all present and `Ready`.
3. The `Usage` guards actually deny a real delete attempt on this claim's
   own kubeconfig Secret (not just `observability`'s, already confirmed
   separately -- see `docs/memory/m4-step-tracker.md`).
4. Deleting the claim cleans up every Crossplane-owned composed resource:
   `Workspace` (real VM teardown), bootstrap `Object`, `XDelegatedHostedZoneAWS`
   (real Route53 zone + Cloudflare NS records), both `Usage` guards.
5. **Known, pre-existing, unfixed gap, asserted explicitly rather than
   ignored**: the kubeconfig/talosconfig Secrets are written imperatively by
   the bootstrap Job, not Crossplane-owned -- deleting the claim does **not**
   clean them up, Usage guard or not (the guard only blocks *accidental*
   deletion while the claim is alive; it doesn't wire up cleanup on
   intentional teardown, since nothing ever composed/owned these Secrets in
   the first place). This suite deletes them itself as part of its own
   cleanup and logs that it's doing so -- don't be alarmed seeing that in
   the output, and don't try to "fix" it as part of this suite; it's a
   composition-level gap for a future step to close (imperative Secret
   writes were a step 2/3 decision, D2 in the design doc, out of scope
   here).
6. No orphaned libvirt domain/image pool left on the real KVM host
   (`mf-ms-a2-01`, via SSH -- requires your own SSH access per
   `docs/runbooks/kvm-host-prep.md`, not provisioned by this suite).

## Not wired into CI

Real KVM/AWS/Cloudflare cost and ~10-20 minute runtime -- manual-only,
same posture as `tests/platform-baseline` and Tier A.
