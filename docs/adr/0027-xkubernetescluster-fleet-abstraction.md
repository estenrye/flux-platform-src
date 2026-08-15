# 27. XKubernetesCluster Fleet Abstraction

Date: 2026-08-11

## Status

Accepted

## Context

ADR-14 documented workload-cluster bootstrap as a multi-step manual process
run by hand via `.bin/` scripts, and its Consequences section states this
"cannot be fully automated yet because Flux bootstrap requires interactive
credential handling and the SPIFFE trust domain must be configured before
cert-manager deploys." Closing that gap was M4's stated job (Full design:
[2026-07-26-m4-cluster-lifecycle-design.md](../superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md)).

`observability` is the proving ground: the second real workload cluster
this fleet has ever provisioned, and the first provisioned via a
declarative claim rather than a hand-run script sequence.

## Decision

`XKubernetesCluster` (`apiextensions.crossplane.io/v2`, applied directly as
a namespaced XR — no separate claim kind, matching this repo's existing
`XDelegatedHostedZoneAWS` convention) + the `cluster-talos-kvm` Composition
(`applications/crossplane-resources/xkubernetescluster/`) collapse ADR-14's
phases 1 (provisioning), 5 (SPIFFE trust domain), and 6 (control-plane
registration / DNS delegation) into one `kubectl apply` of a claim:

- **VM creation** via a `provider-terraform` `Workspace` (embedded
  Terraform, `source: Inline`), reusing a generalized
  `providers/kvm/modules/talos-cluster` module.
- **Talos bootstrap** (schematic lookup, machine secrets, machine-config
  apply, etcd bootstrap, kubeconfig fetch) via a composed `Job`
  (`talos-cluster-bootstrap` image) — the genuinely imperative half of
  bootstrap, deliberately not forced into Terraform.
- **DNS delegation + SPIFFE trust domain** via a composed
  `XDelegatedHostedZoneAWS` (reused as-is, no changes needed).
- **The connection secret** (ADR-14's "cluster must be reachable via
  `kubectl` before proceeding" requirement) — `{name}-kubeconfig`/
  `{name}-talosconfig` Secrets on `controlplane`.
- **Usage guards** (M4 step 6) protecting those connection Secrets from
  accidental deletion while the claim exists, since they're written
  imperatively by the bootstrap Job and were never Crossplane-owned.

Network allocation (subnet/VIP/ASN/node-ULAs) stays hand-curated in a
`platform-kvm-network` `EnvironmentConfig`, not derived — a claim whose name
has no entry fails fast with a readable `ClaimConditions` message rather
than guessing (verified live via
[tests/xkubernetescluster-validation](../../tests/xkubernetescluster-validation/)).

### What this does NOT change — an honest amendment, not a "fully solved" claim

ADR-14's phases 2-4 (SOPS key delivery, rendered-repo bootstrap, deploy-key
creation — i.e. getting Flux itself running on the *new* cluster) are
**still manual**, run via the pre-existing `.bin/bootstrap-cluster-*.sh`
chain (built for `controlplane`, itself script-bootstrapped and outside
this XRD's scope per the M4 design's stated exception). This chain was run
end-to-end for the first time against a second cluster
(`observability`) as part of M4, surfacing three real bugs — see
[[bootstrap-cluster-generic-chain]] in `docs/memory/`. The
originally-envisioned fully-automated version of this step (a
`provider-kubernetes` `ProviderConfig` with `credentials.source: Secret`
pointed at the new cluster, plus `provider-github` deploy-key automation)
was never built; the scripted chain was used instead. This is the real
remaining gap in ADR-14's "manual, can't be automated" consequence — closing
it further is not scoped here.

The public JWKS/OIDC mirror (originally step 3c) was deferred at the same
time and never started — not required for any workload this cluster
currently hosts, flagged for whenever a workload needs external OIDC
federation to it.

## Consequences

- **The single-KVM-host capacity ceiling (M4 design D1) is now the fleet's
  real growth constraint, not tooling.** `XKubernetesCluster` makes
  requesting a new cluster trivial; it does nothing to add KVM capacity.
  `observability`'s provisioning already required a mid-flight fix
  (`allowSchedulingOnControlPlanes` for 0-worker clusters) precisely because
  small footprints are the norm on this host, not the exception.
- **`platform-kvm-hosts`/`platform-kvm-network` remain hand-curated, not
  self-service.** A human must add a network-allocation entry (subnet, VIP,
  disjoint node-ULA octets to avoid MAC collisions — a real incident class
  this fleet has already hit once, see `platform-kvm-network`'s own
  in-repo comments) before any new claim can provision. This is a
  deliberate, documented tradeoff (M4 design), not an oversight, but it
  means "one `kubectl apply`" is only true after that one-time human step.
- **The embedded-vs-real Terraform module drift risk is now standing tech
  debt for every future claimed cluster**, not just `observability`'s. The
  Composition's `Workspace` embeds `providers/kvm/modules/talos-cluster`'s
  `.tf` content directly (`source: Inline`) rather than referencing it
  (`source: Remote`) — flagged, not resolved, in
  `docs/memory/m4-step-tracker.md`.
- **The kubeconfig/talosconfig connection Secrets are still not
  Crossplane-owned.** M4 step 6's Usage guards protect them from *accidental*
  deletion while a claim is alive, but deleting the claim does not clean
  them up either way — a real, documented gap (see
  [tests/xkubernetescluster-lifecycle](../../tests/xkubernetescluster-lifecycle/)'s
  README) for a future step to close at the bootstrap-Job level.
- Every later substrate (EKS/GKE/AKS/OKE, M6+) is expected to reuse this
  same `XKubernetesCluster` XRD contract with a different Composition —
  this ADR's decisions (v2 XR, no separate claim kind, hand-curated network
  allocation, Usage-guarded connection secrets) are the pattern those
  substrates inherit, not just this one.

## References

- [ADR-14: Workload Cluster Bootstrap and Lifecycle](0014-workload-cluster-bootstrap-and-lifecycle.md) (amended by this ADR)
- [ADR-16: SPIFFE Trust Domain Configuration per Cluster](0016-spiffe-trust-domain-configuration-per-cluster.md)
- [ADR-18: Backstage Catalog as Platform Topology Source of Truth](0018-backstage-catalog-as-platform-topology-source-of-truth.md) (amended for claimed clusters, M4 step 7)
- [2026-07-26-m4-cluster-lifecycle-design.md](../superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md) — full M4 design, decisions D1-D4
- `docs/memory/m4-step-tracker.md` — live execution status
- `docs/memory/bootstrap-cluster-generic-chain.md` — the still-manual Flux bootstrap chain
