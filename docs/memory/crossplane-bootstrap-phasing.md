---
name: crossplane-bootstrap-phasing
description: Crossplane's self-installed CRDs race Flux's atomic dry-run on first install — solved permanently with 4 dependsOn-chained Flux Kustomizations
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

## Permanent fix: 4 dependsOn-chained Flux Kustomizations

ADR-10 amended (2026-07-20) to allow this as a documented exception to the
one-Kustomization-per-cluster default, specifically for components with
runtime-self-installed CRDs. Structure (see
`clusters/controlplane/{crossplane-core,crossplane-providers,
crossplane-xrds,crossplane-resources}/` and `clusters/controlplane/
resources/flux.crossplane-*.kustomization.yaml`):

1. **`crossplane-core`** — `applications/crossplane/base` only. No
   `dependsOn`. `wait: true` (built-in Deployment health check is enough —
   Crossplane's init container installs its own CRDs before the main
   container reports Ready).
2. **`crossplane-providers`** — `dependsOn: [crossplane-core]`. All
   provider/function install directories, but with each provider's own
   `ClusterProviderConfig`/`ProviderConfig` excluded (moved to a
   `provider-config/` subdirectory instead — see below). **No `wait`, no
   `healthCheckExprs`.** Tried both, in order, before giving up on
   fine-grained health gating for this Kustomization:
   - CEL health checks for `Provider`/`Function`'s `Installed`/`Healthy`
     conditions (every variant: `current`+`failed`, `current`-only,
     `current` with `has()` guards) failed with `no such attribute(s):
     self.status[...]`, even though the CRD schema and live objects both
     have a well-formed `status.conditions` array, and even after
     restarting `kustomize-controller` to rule out a stale/cached CEL
     program.
   - `wait: true` with no custom `healthCheckExprs` (kstatus's generic
     default check) sat "Reconciliation in progress" for 8+ minutes past
     its own 5m `timeout`, despite every Provider/Function already
     showing `Installed=True`/`Healthy=True` in `kubectl` — kstatus's
     default handling of these conditions appears to hit the same
     underlying issue as the CEL path.
   - Genuine limitation in this Flux version for these CRDs, not a
     caching or config bug. Not pursued further. Without any waiting,
     this Kustomization reports Ready as soon as apply succeeds.
     `dependsOn` alone still solves the actual problem (the atomic
     dry-run race); losing the fine-grained "is the package actually
     running" gate just means `crossplane-resources` may need one extra
     automatic dependsOn retry cycle (self-healing) rather than the
     original all-or-nothing failure.
3. **`crossplane-xrds`** — `dependsOn: [crossplane-providers]`.
   `CompositeResourceDefinition`/`Composition` pairs only (e.g.
   `delegated-hosted-zone-aws`). Same self-installed-CRD race as
   Provider/Function: Crossplane registers an XRD's CRD asynchronously
   after the XRD object lands, so a claim of that XRD's kind applied in
   the *same* atomic dry-run as the XRD itself can fail on first
   bootstrap (added 2026-07-20, M2 step 7, once a second XRD/claim pair
   was added beyond the original `crossplane.rye.ninja` one that had been
   hand-migrated).
4. **`crossplane-resources`** — `dependsOn: [crossplane-xrds]`. Each
   provider's `ClusterProviderConfig`/`ProviderConfig` (referenced from
   each provider's own `provider-config/` subdirectory), platform
   `EnvironmentConfig`s, and XR/claim instances of the XRDs defined in
   `crossplane-xrds`.

**`postBuild.substituteFrom` + `${...}`-braced doc strings don't mix:**
hit this shipping the `controlplane.rye.ninja` claim (M2 step 7,
2026-07-20). `crossplane-resources` needs `postBuild.substituteFrom` (the
`platform-iam-rolesanywhere` EnvironmentConfig's `trustAnchorArn` is
cluster-specific, same `roles-anywhere-arns` ConfigMap as
`crossplane-providers`). Flux's substitution only expands *braced*
`${VAR}` tokens (bare `$var` — e.g. the Go template variables inside
`delegated-hosted-zone-aws`'s `Composition` pipeline — is left alone by
design, confirmed against the Flux docs). But the `delegated-hosted-zone-
aws` XRD's own OpenAPI `description` field used `${spec.subdomain}.
${zoneName}` as illustrative text; once `substituteFrom` was enabled on
the Kustomization that rendered it, envsubst tried to expand that
literal doc string too and failed ("missing closing brace" — dots aren't
valid in an env var name), blocking the whole Kustomization. Fixed by
rewording the XRD description to prose instead of `${...}` notation, and
by moving the XRD/Composition itself out to `crossplane-xrds` (which has
no `substituteFrom`) so this class of collision can't recur for it
specifically — but any future doc string with `${...}` syntax in a
Kustomization that *does* have `substituteFrom` will hit the same thing.

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
on any cluster using this structure — Flux's `dependsOn` alone handles
the ordering automatically on a from-scratch bootstrap (fine-grained
health-check gating didn't pan out for these CRDs, see above).
