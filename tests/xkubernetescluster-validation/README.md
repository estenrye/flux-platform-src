# XKubernetesCluster Validation Suite (M4 step 6, Tier A)

Fast, cheap chainsaw coverage for the `XKubernetesCluster` fail-fast path:
proves that a claim whose name has no `platform-kvm-network` entry surfaces
`ClaimConditions: NetworkAllocationResolved=False/MissingNetworkAllocation`
and never provisions a `Workspace` (VM) or `talos-cluster-bootstrap` Job.

See [docs/superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md](../../docs/superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md)
§8 step 6 and [applications/crossplane-resources/xkubernetescluster/](../../applications/crossplane-resources/xkubernetescluster/).

## Running

```bash
.bin/run-xkubernetescluster-validation-test.sh
```

Runs against `controlplane` (where `XKubernetesCluster` claims live), same
kubeconfig-resolution convention as `.bin/run-platform-baseline.sh`.

## Real infra cost (read before running)

`create-dns-delegation` (`composition.yaml`) is **not gated** on
`validate-network-allocation` passing — it composes an
`XDelegatedHostedZoneAWS` unconditionally, on every claim, valid or not. This
suite's claim therefore creates a real, short-lived AWS Route53 hosted zone
+ Cloudflare NS records (`chainsaw-validate-xkc.rye.ninja`) before failing
validation, torn down again when the suite deletes the claim. Cheap
(Route53's ~$0.50/mo hosted-zone charge is prorated to the few minutes this
exists) and near-instant — **not** the real VM/Talos cost of
`tests/xkubernetescluster-lifecycle` (Tier B). Safe to run repeatedly, no
KVM host impact.

## What this suite does NOT cover

Deep garbage-collection verification — confirming the real Route53 zone is
actually gone from AWS, no orphaned VM/zvol, no dangling connection Secret —
is `tests/xkubernetescluster-lifecycle`'s job (Tier B, manual-only, real end-
to-end provision + teardown). This suite only proves the fail-fast path
halts before touching VM/Talos provisioning; it doesn't exercise a real
`Ready` claim's teardown at all.

## Not wired into CI

Zero KVM/Terraform/Talos cost, but still touches real AWS/Cloudflare state
— left as manual-only for now (same posture as `tests/platform-baseline`),
not auto-run on every PR. Revisit if/when CI wiring for chainsaw suites is
scoped as its own decision.
