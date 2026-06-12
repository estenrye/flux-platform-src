# 18. Backstage Catalog as Platform Topology Source of Truth

Date: 2026-06-11

## Status

Accepted

## Context

The platform is composed of many independently deployed components spread
across `applications/` and `clusters/`. Without a registry of what the platform
provides, new contributors and application teams must read the entire directory
tree to discover available capabilities.

Backstage is a developer portal that provides a service catalog. Requiring each
component to self-register via a co-located `catalog.yaml` means the catalog is
always in sync with the deployed components — no separate registration step is
needed.

## Decision

Every directory under `applications/` must include a `catalog.yaml` declaring
a Backstage `Component` entity. Every directory under `clusters/` must include
a `catalog.yaml` declaring a Backstage `System` entity.

### Required fields for application `catalog.yaml`

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: <component-name>           # matches the applications/ directory name
  description: |-
    <one or two sentences describing what this component does and why it exists>
  tags:
    - <tag1>
    - <tag2>
spec:
  type: service
  lifecycle: production
  owner: platform-engineering
```

### Required fields for cluster `catalog.yaml`

```yaml
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: <cluster-name>
  annotations:
    github.com/project-slug: <owner>/<rendered-repo>
    rye.ninja/flux-source-repo: estenrye/flux-platform-src
    rye.ninja/kubeconfig: <path-to-kubeconfig>
  description: <one sentence describing the cluster's role>
spec:
  owner: platform-engineering
  domain: <domain>
```

The cluster `catalog.yaml` is also consumed by `render-discover-clusters.sh`
(see ADR-9). The `github.com/project-slug` and `rye.ninja/flux-source-repo`
annotations are required for the CI pipeline to discover the cluster.

### Tag vocabulary

Use tags from this list to categorize components. Multiple tags are expected.

| Tag | Meaning |
|-----|---------|
| `platform` | Core platform infrastructure |
| `operators` | A Kubernetes operator (controller managing CRDs) |
| `crds` | Provides Custom Resource Definitions |
| `infrastructure` | Manages cloud or cluster infrastructure |
| `certificates` | Involved in certificate issuance or management |
| `workload-identity` | Involved in SPIFFE/workload identity |
| `dns` | Manages DNS records |
| `scheduling` | Affects pod scheduling |
| `cicd` | Part of CI/CD tooling |
| `monitoring` | Observability or monitoring related |
| `network` | Network policy or traffic management |
| `secrets` | Secret management or delivery |
| `flux` | Flux CD component |
| `crossplane` | Crossplane or Crossplane provider |
| `spiffe` | SPIFFE/SVID related |
| `csi` | CSI driver |
| `aws` | AWS-related components or providers |
| `cloudflare` | Cloudflare-related components or providers |
| `github` | GitHub-related components or providers |
| `iam` | IAM role or policy management |
| `rolesanywhere` | AWS IAM Roles Anywhere related |
| `route53` | AWS Route53 DNS provider |
| `kubernetes` | Kubernetes-specific tooling or providers |
| `gateway-api` | Kubernetes Gateway API related |
| `composition` | Crossplane composition related |
| `environment-configs` | Crossplane environment configs |
| `crossplane-function` | Crossplane function implementation |
| `crossplane-provider` | Crossplane provider implementation |
| `auto-ready` | Auto-ready composition function |
| `go-templating` | Go templating composition function |
| `examples` | Example or demonstration components |
| `crossplane-examples` | Crossplane example compositions |
| `documentation` | Documentation or runbook components |
| `pipeline` | CI/CD pipeline components |
| `security` | Security-related tooling |

### Finding platform capabilities

Application teams can query the Backstage catalog to find what the platform
provides:
- Search by tag (e.g., `dns` to find DNS management components)
- Browse the `platform-engineering` owner for all platform components
- Use the `System` view for a cluster to see all components deployed to it

## Consequences

- Every new component added to `applications/` requires a `catalog.yaml`. PRs
  that add a new directory without one should be flagged in review.
- The tag vocabulary is a convention, not enforced by tooling. Tags outside the
  defined vocabulary will appear in the catalog but won't be discoverable by
  application teams using the standard tag filters.
- The cluster `catalog.yaml` is load-bearing for CI. Missing or incorrectly
  annotated cluster `catalog.yaml` files cause that cluster to be silently
  excluded from the CI render matrix (see ADR-9).
- Backstage must be operational for catalog queries to work. The catalog files
  in this repository are the source data; they have no effect if Backstage is
  not ingesting them.

## References

- [ADR-9: CI/CD Pipeline Architecture](0009-cicd-pipeline-architecture.md)
- [Backstage: Descriptor Format](https://backstage.io/docs/features/software-catalog/descriptor-format)
- [Backstage: Well-known Annotations](https://backstage.io/docs/features/software-catalog/well-known-annotations)
