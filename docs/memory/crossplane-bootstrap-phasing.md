---
name: crossplane-bootstrap-phasing
description: Crossplane's first-ever install must land in 3 separate commits/reconciles — core, then providers/functions, then provider-configs/XRDs
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
that Crossplane would perform hasn't happened yet. Since this repo's
convention (ADR-10) is one flat root Kustomization per cluster (`clusters/
<name>/kustomization.yaml`, no `dependsOn`-chained sub-Kustomizations),
this fails the *whole* apply — 0 pods, 0 CRDs, nothing at all lands, not
even the parts that don't depend on Crossplane.

Hit this twice in a row on 2026-07-20 chasing it one resource at a time
(first the `delegated-hosted-zone-aws` XRD, then a provider's
`ClusterProviderConfig` once the XRD was removed) before recognizing the
pattern and stripping `clusters/controlplane/kustomization.yaml` down to
`applications/crossplane/base` alone.

**Required sequencing for a first-ever Crossplane install on any cluster:**
1. **Core only** (`applications/crossplane/base`) — plain Deployments/RBAC/
   NetworkPolicies, no CRD-dependent kinds. Merge, reconcile, confirm the
   `crossplane` and `crossplane-rbac-manager` Deployments are `Available`
   and `kubectl get providers.pkg.crossplane.io` no longer errors
   ("doesn't have a resource type" → the CRD is now registered).
2. **Providers + functions** (`crossplane-providers/*`, `crossplane-
   functions/*`) — but each provider directory's `kustomization.yaml`
   bundles the `Provider`/`ProviderConfig` resource together with its
   `ClusterProviderConfig`/`ProviderConfig` CR in the same file list; the
   latter needs the *provider's own* CRDs, registered only after that
   specific provider pod starts. If this phase still fails dry-run on the
   ProviderConfig, split provider install from provider-config within each
   directory too, same principle one level down.
3. **Provider-configs / EnvironmentConfig / XRDs / Compositions /
   claims** — anything that assumes both Crossplane core and the specific
   provider are already `Healthy`.

Each phase needs its own commit → render → merge → Flux reconcile → verify
cycle before adding the next. This is a one-time bootstrap cost — once
everything is registered, further changes to existing types apply
normally in a single Kustomization.
