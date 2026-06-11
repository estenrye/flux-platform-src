# 10. GitOps Layering and Kustomize Composition Strategy

Date: 2026-06-10

## Status

Accepted

## Context

The platform delivers many components (operators, CRDs, Crossplane providers,
monitoring, networking, etc.) to one or more Kubernetes clusters. We need a
consistent structure that:

- Makes it clear where to add a new application
- Separates reusable base configuration from environment- or provider-specific
  variants
- Allows the cluster entry point (`clusters/<name>/kustomization.yaml`) to
  aggregate all components without per-component knowledge of each cluster
- Follows Kustomize conventions that CI tooling (kustomize build, kube-linter,
  checkov) can process without special configuration

## Decision

### Directory structure

Every application follows this layout:

```
applications/
  <component-name>/
    base/
      kustomization.yaml     # required — lists all resources in this component
      helmrelease.yaml       # if Helm-based
      namespace.yaml         # if the component owns its namespace
      resources/             # additional manifests
    <provider-variant>/      # optional — e.g. aws/, cloudflare/, rackspace-spot/
      base/
        kustomization.yaml   # patches or additions specific to that provider
    catalog.yaml             # required — Backstage component metadata (see ADR-18)
                             # Place at the application root, or in base/ if the
                             # application uses no provider variants
```

Provider variants are peer directories to `base/`, not nested inside it. A
`base/` overlay applies everywhere; a provider variant applies only when
explicitly included by a cluster kustomization.

Simple applications with no provider variants may omit `base/` and place
`kustomization.yaml` directly in the application root (e.g., `priority-classes/`).
Use `base/` when the application has provider-specific variants or multiple
overlay targets.

### Cluster entry point

`clusters/<cluster-name>/kustomization.yaml` is the single aggregation point.
It lists each component's `applications/<name>/base` (and any provider variants
appropriate to that cluster) as a resource. Flux reconciles this file as the
root `Kustomization` for the cluster.

### Grouping related providers

When multiple tightly related components share the same configuration pattern
(e.g., Crossplane provider packages), they may be grouped under a single parent
directory without a top-level `base/`. Each sub-component has its own
`kustomization.yaml` at its root. Example:

```
applications/
  crossplane-providers/
    provider-aws-route53/
      kustomization.yaml
      resources/
    provider-aws-iam/
      kustomization.yaml
      resources/
```

The parent directory (`crossplane-providers/`) does not need its own
`kustomization.yaml`; the cluster kustomization references each sub-component
directly.

### Naming conventions

| Item | Convention | Example |
|------|-----------|---------|
| Application directory | `kebab-case` | `cert-manager`, `external-dns` |
| Operator namespace | `{operator}-system` | `cert-manager-system`, `crossplane-system` |
| Crossplane XRD kind | `X{PascalCase}` | `XDelegatedHostedZoneAWS` |
| Crossplane provider packages | `provider-{vendor}-{service}` | `provider-aws-route53` |
| HelmRelease name | matches application directory name | `cert-manager` |

### Adding a new application

1. Create `applications/<name>/base/kustomization.yaml` listing all resources,
   or `applications/<name>/kustomization.yaml` for simple single-variant applications.
2. Add `applications/<name>/catalog.yaml` with required Backstage metadata
   (see ADR-18).
3. Add a network policy exception for the component (see ADR-17).
4. Add `- ../../../applications/<name>/base` to
   `clusters/<cluster-name>/kustomization.yaml` for each cluster that should
   run it.
5. Run `make render-manifests` locally and confirm `kustomize build` succeeds
   before opening a PR.

## Consequences

- Every component must have a `kustomization.yaml` — either at `base/kustomization.yaml` for multi-variant applications or at the application root for simple single-variant applications. Components without one will be silently ignored by Kustomize.
- A component added to `applications/` but not listed in any
  `clusters/*/kustomization.yaml` is never deployed. This is intentional for
  components that are work-in-progress.
- Provider-specific behavior (e.g., Cilium network policies on Rackspace Spot)
  must live in a provider variant directory, not in `base/`, so that `base/`
  remains portable across environments.
- `clusters/<cluster-name>/kustomization.yaml` is the most frequently modified
  file when adding applications. PRs that add a new application and wire it to
  a cluster should be reviewed with this file as the primary diff.

## References

- [ADR-8: Source vs. Rendered Repository Pattern](0008-source-vs-rendered-repository-pattern.md)
- [ADR-9: CI/CD Pipeline Architecture](0009-cicd-pipeline-architecture.md)
- [Kustomize documentation](https://kustomize.io/)
- [FluxCD: Kustomization API](https://fluxcd.io/flux/components/kustomize/kustomizations/)
