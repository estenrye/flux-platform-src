---
name: crossplane-bootstrap-phasing
description: Crossplane's self-installed CRDs race Flux's atomic dry-run on first install — solved permanently with 3 dependsOn-chained Flux Kustomizations
metadata:
  type: project
---

Crossplane does not ship any of its own CRDs in the Helm chart — verified
via `helm template crossplane-stable/crossplane --include-crds` (chart
version 2.2.0): zero `CustomResourceDefinition` objects, no `crds/`
directory in the chart at all. Both the core types
(`pkg.crossplane.io`: `Provider`, `Function`; `apiextensions.crossplane.io`:
`CompositeResourceDefinition`, `Composition`, `EnvironmentConfig`) and each
provider's own types (e.g. `aws.m.upbound.io`: `ClusterProviderConfig`) are
self-installed by the running operator/provider pod at startup.

Flux's kustomize-controller dry-runs an entire `Kustomization` atomically
before applying anything. On a cluster where Crossplane has never run, any
resource of those kinds fails dry-run (`no matches for kind "X" in version
"Y"`) — including `Provider`/`Function` resources themselves, not just
things that reference them — because the CRD server-side registration
that Crossplane would perform hasn't happened yet. With one flat root
Kustomization per cluster (the original ADR-10 default), this failed the
*whole* apply — 0 pods, 0 CRDs, nothing at all landed, not even the parts
that don't depend on Crossplane.

Hit this twice in a row on 2026-07-20 chasing it one resource at a time
(first the `delegated-hosted-zone-aws` XRD, then a provider's
`ClusterProviderConfig` once the XRD was removed) via manual 3-phase
commits before implementing the permanent fix below.

## Permanent fix: 3 dependsOn-chained Flux Kustomizations

ADR-10 amended (2026-07-20) to allow this as a documented exception to the
one-Kustomization-per-cluster default, specifically for components with
runtime-self-installed CRDs. Structure (see
`clusters/controlplane/{crossplane-core,crossplane-providers,
crossplane-resources}/` and `clusters/controlplane/resources/
flux.crossplane-*.kustomization.yaml`):

1. **`crossplane-core`** — `applications/crossplane/base` only. No
   `dependsOn`. `wait: true` (built-in Deployment health check is enough —
   Crossplane's init container installs its own CRDs before the main
   container reports Ready).
2. **`crossplane-providers`** — `dependsOn: [crossplane-core]`. All
   provider/function install directories, but with each provider's own
   `ClusterProviderConfig`/`ProviderConfig` excluded (moved to a
   `provider-config/` subdirectory instead — see below). `wait: true`,
   **no `healthCheckExprs`** — tried CEL health checks for
   `Provider`/`Function`'s `Installed`/`Healthy` conditions (every variant:
   `current`+`failed`, `current`-only, `current` with `has()` guards) and
   every one failed with `no such attribute(s): self.status[...]`, even
   though the CRD schema and live objects both have a well-formed
   `status.conditions` array, and even after restarting
   `kustomize-controller` to rule out a stale/cached CEL program. This
   looks like a genuine limitation in how this Flux version's CEL
   evaluation sees status on these CRDs, not a caching bug or a bad
   expression — not pursued further. `dependsOn` + default `wait: true`
   already solve the actual problem (the atomic dry-run race); losing the
   fine-grained "is the package actually running" gate just means
   `crossplane-resources` may need one extra automatic dependsOn retry
   cycle (self-healing) rather than the original all-or-nothing failure.
3. **`crossplane-resources`** — `dependsOn: [crossplane-providers]`. Each
   provider's `ClusterProviderConfig`/`ProviderConfig`, referenced from
   each provider's own `provider-config/` subdirectory.

**Kustomize file-reference gotcha hit along the way:** referencing a
single file across a `..`-traversal (e.g. `../../../applications/
crossplane-providers/provider-aws-iam/resources/cluster-provider-
config.yaml` directly in a `resources:` list) fails kustomize's default
load restrictor ("file is not in or below" the kustomization root) — it
only allows crossing into another tree via a *directory* that has its own
`kustomization.yaml`. Fixed by giving each provider-config file its own
tiny subdirectory (`<provider>/provider-config/kustomization.yaml` wrapping
just that one file) instead of referencing the bare file.

Each child Kustomization needs its own `catalog.yaml` too — the render
pipeline (`render-kustomize-base-and-patches.sh`) discovers and builds
*every* `kustomization.yaml` it finds under `clusters/`, independently,
and unconditionally copies `catalog.yaml` alongside each one.

The original 3-commit manual-phase workaround (superseded) is not needed
on any cluster using this structure — Flux's `dependsOn` + health checks
handle the ordering automatically on a from-scratch bootstrap.
