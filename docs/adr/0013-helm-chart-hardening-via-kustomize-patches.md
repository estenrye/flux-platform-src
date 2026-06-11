# 13. Helm Chart Hardening via Kustomize Patches

Date: 2026-06-10

## Status

Accepted

## Context

Most platform components are available as upstream Helm charts. These charts
are maintained by their respective projects and reflect general-purpose defaults.
They do not include the platform-specific requirements we enforce:

- **Network policies**: The platform enforces default-deny networking
  (see ADR-17). Each component must declare its allowed traffic explicitly.
- **Health probe customization**: Some charts configure probes on ports or
  paths that are blocked by our network policies, or use startup timings
  unsuitable for resource-constrained environments.
- **RBAC augmentation**: Certain operators require additional ClusterRole
  bindings not included in their default charts (e.g., aggregated roles for
  custom resource access).
- **Image digest pinning**: We require all images to be referenced by digest
  for reproducible deployments and to prevent tag mutation attacks.

Forking upstream charts to add these configurations is a maintenance burden:
every upstream release requires a manual merge. Creating wrapper charts adds
a packaging step to every upgrade.

Kustomize's strategic-merge and JSON patches allow us to apply targeted changes
to Helm-rendered output without modifying the chart source.

## Decision

We deploy upstream Helm charts via FluxCD `HelmRelease` resources, then apply
Kustomize patches to harden the rendered output. Patches are co-located with
the application's `base/kustomization.yaml` in the `resources/` subdirectory
(or inline in `kustomization.yaml` for simple patches).

### Standard patch categories

**Network policy injection**

Every component must have a `NetworkPolicy` (and `CiliumNetworkPolicy` where
required by the provider variant) that explicitly permits:
- Ingress from the Kubernetes API server (for webhook controllers)
- Ingress from Prometheus scrapers (for metrics endpoints)
- Egress to the Kubernetes API server
- Egress to DNS (port 53)
- Any other egress the component requires (e.g., to cloud APIs)

Network policies live in `resources/` alongside other component manifests and
are referenced from `kustomization.yaml`.

**Health probe customization**

When an upstream chart configures probes on ports blocked by network policy,
or uses probe settings that cause false failures in the cluster environment,
a strategic-merge patch overrides the probe configuration. The patch is applied
to the specific `Deployment` or `DaemonSet` by name.

**RBAC augmentation**

When a component requires permissions beyond its default chart, a patch adds
additional `rules` to the existing `ClusterRole`, or adds a new `ClusterRole`
and `ClusterRoleBinding`. Patches must not remove existing rules.

**Image digest pinning**

All `images` entries in `kustomization.yaml` specify both `newTag` (the version)
and `digest` (the sha256 digest). Example:

```yaml
images:
  - name: quay.io/jetstack/cert-manager-controller
    newTag: v1.20.1
    digest: sha256:<digest>
```

Digests are updated when upgrading a chart version. The CI pipeline will fail
if a manifest references an image by tag only without a digest.

### Patch file naming convention

```
resources/patches/<resource-kind>-<resource-name>-<patch-type>.yaml
```

Examples:
- `resources/patches/deployment-cert-manager-network-policy.yaml`
- `resources/patches/clusterrole-cert-manager-rbac.yaml`

## Consequences

- Upgrading an upstream chart version requires reviewing whether existing patches
  still apply correctly. Patches that reference field paths that no longer exist
  in the new chart version will fail at render time.
- Network policies must be maintained as components evolve. If a new version of
  a component adds a new egress target, the network policy must be updated.
- Image digests must be updated with every chart upgrade. The CI pipeline
  validates that digests are present but does not automatically update them.
- All hardening is visible in the source repository as explicit patches, making
  the platform's security posture auditable without needing to inspect running
  cluster state.

## References

- [ADR-10: GitOps Layering and Kustomize Composition Strategy](0010-gitops-layering-and-kustomize-composition-strategy.md)
- [ADR-17: Network Policy Default-Deny Enforcement](0017-network-policy-default-deny-enforcement.md)
- [Kustomize: Strategic Merge Patch](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/patches/)
- [FluxCD: HelmRelease](https://fluxcd.io/flux/components/helm/helmreleases/)
