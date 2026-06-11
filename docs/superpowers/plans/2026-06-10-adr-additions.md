# ADR Additions for New Contributors — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ADR-8 through ADR-18 to `docs/adr/`, organized as a journey-ordered onboarding path covering how changes flow, how to extend the platform, and how to operate it.

**Architecture:** Each ADR is a standalone markdown file following the adr-tools format already established in `docs/adr/`. ADRs are written in journey order so the ADR index doubles as an onboarding reading list. No code changes required — documentation only.

**Tech Stack:** Markdown, adr-tools file naming convention (`NNNN-kebab-title.md`), existing ADR format from `docs/adr/0001-record-architecture-decisions.md`

---

## File Structure

Files to create (one per task):

- `docs/adr/0008-source-vs-rendered-repository-pattern.md`
- `docs/adr/0009-cicd-pipeline-architecture.md`
- `docs/adr/0010-gitops-layering-and-kustomize-composition-strategy.md`
- `docs/adr/0011-crossplane-composition-design-pattern.md`
- `docs/adr/0012-least-privilege-iam-role-isolation-for-crossplane-providers.md`
- `docs/adr/0013-helm-chart-hardening-via-kustomize-patches.md`
- `docs/adr/0014-workload-cluster-bootstrap-and-lifecycle.md`
- `docs/adr/0015-secret-and-certificate-rotation-strategy.md`
- `docs/adr/0016-spiffe-trust-domain-configuration-per-cluster.md`
- `docs/adr/0017-network-policy-default-deny-enforcement.md`
- `docs/adr/0018-backstage-catalog-as-platform-topology-source-of-truth.md`

---

## Layer 1 — Understanding How Changes Flow

### Task 1: ADR-8 — Source vs. Rendered Repository Pattern

**Files:**
- Create: `docs/adr/0008-source-vs-rendered-repository-pattern.md`

- [ ] **Step 1: Write the ADR file**

```markdown
# 8. Source vs. Rendered Repository Pattern

Date: 2026-06-10

## Status

Accepted

## Context

Flux CD reconciles Kubernetes manifests from a Git repository. The manifests in
this platform are authored using Kustomize overlays, SOPS-encrypted secrets, and
Helm values files — none of which Flux can apply directly without first rendering
them into plain Kubernetes YAML.

Additionally, we want a linting and security-scanning gate (kube-linter, checkov)
that runs before any change reaches a cluster. Running these gates in CI and pushing
only validated output gives us a clean separation between authoring and delivery.

Committing rendered output back into the same repository where it was authored would
mix two concerns with different audiences and change velocities, and would require
contributors to understand both the source structure and the rendered output.

## Decision

We maintain two repositories:

- **`estenrye/flux-platform-src`** (this repository) — the human-authored source of
  truth. Contains Kustomize bases and overlays, SOPS-encrypted secrets, Helm values,
  Crossplane compositions, and CI/CD tooling. Contributors work here exclusively.

- **`estenrye/flux-platform-rendered`** — the CI-generated delivery target. Contains
  fully rendered, lint-validated Kubernetes manifests. Flux watches this repository.
  No human edits are made directly here; all content is produced by CI.

The CI pipeline (see ADR-9) renders the source manifests, runs lint checks, and
creates a pull request to the rendered repository. On merge to `main` in the source
repository, the rendered PR is auto-merged, triggering Flux reconciliation on the
cluster.

Each cluster entry under `clusters/` has a `catalog.yaml` that declares which rendered
repository it maps to via the `github.com/project-slug` annotation. The
`render-discover-clusters.sh` script uses these annotations to build the CI job matrix.

## Consequences

- Contributors only work in `flux-platform-src`. They must never commit directly to
  the rendered repository.
- A change in `flux-platform-src` reaches the cluster only after CI passes. A broken
  pipeline blocks all deployments.
- The rendered repository contains plain Kubernetes YAML without SOPS encryption.
  Access to the rendered repository grants read access to decrypted manifest content
  (but not secret values, which are delivered at runtime by External Secrets Operator).
- Adding a new cluster target requires adding an entry under `clusters/` with the
  correct `catalog.yaml` annotations pointing to the rendered repository for that
  cluster.

## References

- [ADR-2: Bootstrapping a Flux-Enabled Kubernetes Cluster](0002-managing-a-consistent-development-environment.md)
- [ADR-3: Bootstrapping the Crossplane Controlplane Cluster](0003-bootstrapping-the-crossplane-controlplane-cluster.md)
- [ADR-9: CI/CD Pipeline Architecture](0009-cicd-pipeline-architecture.md)
- [FluxCD: GitRepository API](https://fluxcd.io/flux/components/source/gitrepositories/)
```

- [ ] **Step 2: Verify the file exists**

```bash
head -5 docs/adr/0008-source-vs-rendered-repository-pattern.md
```

Expected output:
```
# 8. Source vs. Rendered Repository Pattern

Date: 2026-06-10

## Status
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0008-source-vs-rendered-repository-pattern.md
git commit -m "docs(adr): add ADR-8 source vs rendered repository pattern"
```

---

### Task 2: ADR-9 — CI/CD Pipeline Architecture

**Files:**
- Create: `docs/adr/0009-cicd-pipeline-architecture.md`

- [ ] **Step 1: Write the ADR file**

```markdown
# 9. CI/CD Pipeline Architecture

Date: 2026-06-10

## Status

Accepted

## Context

Changes to `flux-platform-src` need to be rendered into Kubernetes manifests,
validated for correctness and security policy, and delivered to cluster-specific
rendered repositories before Flux can reconcile them. This pipeline must:

- Render Kustomize sources into plain YAML for all cluster targets
- Run security and correctness linting before any cluster is updated
- Authenticate to external services (GitHub, rendered repositories) without
  storing long-lived credentials in the repository
- Support multiple cluster targets in parallel
- Provide contributors with visibility into which rendered PRs correspond to
  which source PR

Storing pipeline secrets in GitHub repository secrets directly would require
secret rotation to be performed in two places (the secret store and GitHub).
Using a GitHub App for cross-repository write access avoids the use of personal
access tokens, which are tied to individual user accounts and break when those
accounts change.

## Decision

We use GitHub Actions with the following job structure:

```
discover → render-and-lint → push-cluster (matrix) → update-source-pr
```

### Job: discover

Runs `render-discover-clusters.sh`, which reads `clusters/*/catalog.yaml` files.
Each `catalog.yaml` must have:
- `rye.ninja/flux-source-repo: estenrye/flux-platform-src` — identifies it as
  belonging to this source repository
- `github.com/project-slug: <owner>/<rendered-repo>` — the target rendered
  repository for this cluster

The job outputs a JSON matrix of cluster objects used by `push-cluster`.

### Job: render-and-lint

Runs on every PR and push to `applications/**` or `clusters/**`:

1. `make render-deps` — installs kustomize, helm, and other render dependencies
2. `make render-manifests` — runs `kustomize build` for each cluster, producing
   rendered YAML under `.render/flux-platform-rendered/`
3. `make lint-checkov` — runs Checkov IaC security scanning against rendered output
4. `make lint-kube-linter` — runs kube-linter against rendered output
5. Uploads rendered output as a GitHub Actions artifact for use by `push-cluster`

The job must pass before `push-cluster` runs (`needs: [render-and-lint]`).

### Job: push-cluster (matrix)

Runs once per discovered cluster, in parallel. Per cluster:

1. **Loads 1Password secrets** via `1password/load-secrets-action@v2`. The
   `OP_SERVICE_ACCOUNT_TOKEN` is the only secret stored in GitHub. It resolves:
   - `RENDER_APP_PRIVATE_KEY` from `op://flux-platform-src/render-flux-platform-src-app/private-key`
   - `RENDER_APP_ID` from `op://flux-platform-src/render-flux-platform-src-app/app-id`

2. **Generates a GitHub App token** via `actions/create-github-app-token@v1`
   scoped to the rendered repository for that cluster. This avoids personal
   access tokens and ties write access to the GitHub App lifecycle.

3. **Clones the rendered repository**, creates a branch, copies the rendered
   manifests, commits, and creates or updates a pull request.

4. **On push to `main`** (`AUTO_MERGE=true`): the rendered PR is auto-merged,
   triggering immediate Flux reconciliation. On PR events, a draft PR is created
   for review.

### Job: update-source-pr

After all `push-cluster` jobs complete on a PR event, downloads the rendered PR
URL artifacts and posts links to each rendered PR as a comment on the source PR.
This gives contributors visibility into exactly which rendered changes correspond
to their source change.

## Consequences

- The only secret that must be rotated in GitHub is `OP_SERVICE_ACCOUNT_TOKEN`.
  All other credentials are fetched from 1Password at runtime.
- Adding a new cluster target requires creating a new environment in GitHub
  settings (for the `environment:` gate on `push-cluster`) and ensuring the
  `OP_SERVICE_ACCOUNT_TOKEN` in that environment resolves to a 1Password Service
  Account with access to the `flux-platform-src` vault.
- Lint failures in `render-and-lint` block all cluster pushes. Keeping
  `.kube-linter/config.yaml` and Checkov policy in sync with actual manifest
  content is a maintenance responsibility.
- The GitHub App (`render-flux-platform-src-app`) must have write access to all
  rendered repositories. Revoking or expiring the app breaks all pushes.

## References

- [ADR-8: Source vs. Rendered Repository Pattern](0008-source-vs-rendered-repository-pattern.md)
- [1Password Load Secrets Action](https://github.com/1Password/load-secrets-action)
- [actions/create-github-app-token](https://github.com/actions/create-github-app-token)
- [kube-linter](https://github.com/stackrox/kube-linter)
- [Checkov](https://github.com/bridgecrewio/checkov)
```

- [ ] **Step 2: Verify the file exists**

```bash
head -5 docs/adr/0009-cicd-pipeline-architecture.md
```

Expected output:
```
# 9. CI/CD Pipeline Architecture

Date: 2026-06-10

## Status
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0009-cicd-pipeline-architecture.md
git commit -m "docs(adr): add ADR-9 cicd pipeline architecture"
```

---

### Task 3: ADR-10 — GitOps Layering and Kustomize Composition Strategy

**Files:**
- Create: `docs/adr/0010-gitops-layering-and-kustomize-composition-strategy.md`

- [ ] **Step 1: Write the ADR file**

```markdown
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
```

Provider variants are peer directories to `base/`, not nested inside it. A
`base/` overlay applies everywhere; a provider variant applies only when
explicitly included by a cluster kustomization.

### Cluster entry point

`clusters/<cluster-name>/kustomization.yaml` is the single aggregation point.
It lists each component's `applications/<name>/base` (and any provider variants
appropriate to that cluster) as a resource. Flux reconciles this file as the
root `Kustomization` for the cluster.

### Naming conventions

| Item | Convention | Example |
|------|-----------|---------|
| Application directory | `kebab-case` | `cert-manager`, `external-dns` |
| Operator namespace | `{operator}-system` | `cert-manager-system`, `crossplane-system` |
| Crossplane XRD kind | `X{PascalCase}` | `XDelegatedHostedZoneAWS` |
| Crossplane provider packages | `provider-{vendor}-{service}` | `provider-aws-route53` |
| HelmRelease name | matches application directory name | `cert-manager` |

### Adding a new application

1. Create `applications/<name>/base/kustomization.yaml` listing all resources.
2. Add `applications/<name>/catalog.yaml` with required Backstage metadata
   (see ADR-18).
3. Add a network policy exception for the component (see ADR-17).
4. Add `- ../../../applications/<name>/base` to
   `clusters/<cluster-name>/kustomization.yaml` for each cluster that should
   run it.
5. Run `make render-manifests` locally and confirm `kustomize build` succeeds
   before opening a PR.

## Consequences

- Every component must have a `base/` directory with a `kustomization.yaml`.
  Components without one will be silently ignored by Kustomize.
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
```

- [ ] **Step 2: Verify the file exists**

```bash
head -5 docs/adr/0010-gitops-layering-and-kustomize-composition-strategy.md
```

Expected output:
```
# 10. GitOps Layering and Kustomize Composition Strategy

Date: 2026-06-10

## Status
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0010-gitops-layering-and-kustomize-composition-strategy.md
git commit -m "docs(adr): add ADR-10 gitops layering and kustomize composition strategy"
```

---

## Layer 2 — Extending the Platform

### Task 4: ADR-11 — Crossplane Composition Design Pattern

**Files:**
- Create: `docs/adr/0011-crossplane-composition-design-pattern.md`

- [ ] **Step 1: Write the ADR file**

```markdown
# 11. Crossplane Composition Design Pattern for Multi-Cloud Orchestration

Date: 2026-06-10

## Status

Accepted

## Context

The platform manages infrastructure across multiple cloud providers (AWS, Cloudflare,
GitHub, and others). Consumers of the platform — workload cluster operators and
application teams — should not need to understand the details of each provider API
to request infrastructure. They should interact with a single, consistent claim API
that hides provider-specific complexity.

We need a pattern for defining these abstractions that:

- Keeps provider-specific resources under Crossplane's reconciliation loop
- Derives all provider-specific inputs from a small set of consumer-facing inputs
  so that claims are simple to write
- Surfaces the outputs that downstream automation needs (ARNs, zone IDs, trust
  domains) in a discoverable, consistent location
- Handles multiple providers in a single claim lifecycle so that related resources
  are provisioned and deprovisioned atomically

## Decision

We use Crossplane Composite Resource Definitions (XRDs) and Compositions as the
abstraction layer. The canonical example is
`XDelegatedHostedZoneAWS` in
`applications/crossplane-resources/delegated-hosted-zone-aws/`.

### When to create a new XRD

Create a new XRD when:
- Multiple consumers will request the same type of infrastructure
- The infrastructure spans multiple Crossplane providers or requires
  non-trivial input derivation
- Lifecycle coupling is required (all resources must be created and destroyed
  as a unit)

Use a provider managed resource directly (without a composition) when:
- The resource is a one-off platform infrastructure component (not a consumer
  API)
- No input derivation or multi-provider orchestration is needed

### Composition function pipeline

Every composition uses a three-stage function pipeline:

1. **`function-environment-configs`** — injects platform-level defaults
   (e.g., shared trust anchor ARN, default zone name) from a Crossplane
   `EnvironmentConfig` into the composition context. This allows platform
   operators to set defaults once without requiring each claim to specify them.

2. **`function-go-templating`** — derives provider-specific resource specs
   from claim inputs and environment context. All resource names, labels,
   ARN templates, IAM policy documents, and cross-resource references are
   rendered here. This is the main composition logic.

3. **`function-auto-ready`** — marks the composite resource Ready=True when
   all composed resources are Ready. Without this, readiness must be managed
   manually in the `go-templating` step.

### Status outputs

Every composition must surface the values downstream automation needs in
`status` fields on the composite resource. For `XDelegatedHostedZoneAWS`:

```yaml
status:
  iamRoleArn: arn:aws:iam::123456789:role/crossplane-<subdomain>
  profileArn: arn:aws:rolesanywhere::123456789:profile/<uuid>
  trustAnchorArn: arn:aws:rolesanywhere::123456789:trust-anchor/<uuid>
  trustDomain: <subdomain>.<zoneName>
  zoneId: Z0123456789ABCDEFGHIJ
```

Downstream resources (ExternalDNS, cert-manager overlays) consume these values
via cross-resource references rather than requiring operators to look up and
copy ARNs manually.

### Input minimization

Composition inputs should derive as much as possible from the claim's primary
identifiers plus platform defaults. For `XDelegatedHostedZoneAWS`, the only
required input is `spec.subdomain`. All other values (zone name, trust anchor
ARN, provider configs) default from `EnvironmentConfig` and can be overridden
per-claim when needed.

## Consequences

- Every new XRD requires: an XRD YAML, a Composition YAML, and a ClusterRole
  granting claim access. Follow the structure in
  `applications/crossplane-resources/delegated-hosted-zone-aws/` as the
  reference implementation.
- Composition debugging requires the Crossplane CLI (`crossplane beta trace
  <claim-kind> <name>`) to inspect composed resource status.
- Environment defaults in `EnvironmentConfig` are cluster-wide. Changes to
  defaults affect all claims that rely on them. Test in a non-production
  environment before promoting.
- Status fields are only populated after the composition fully reconciles
  (all composed resources Ready). Downstream automation that reads status
  fields must handle the case where they are not yet set.

## References

- [ADR-7: Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere](0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md)
- [ADR-12: Least-Privilege IAM Role Isolation for Crossplane Providers](0012-least-privilege-iam-role-isolation-for-crossplane-providers.md)
- [Crossplane: Composite Resource Definitions](https://docs.crossplane.io/latest/concepts/composite-resource-definitions/)
- [Crossplane: Compositions](https://docs.crossplane.io/latest/concepts/compositions/)
- [function-go-templating](https://github.com/crossplane-contrib/function-go-templating)
- [Reference implementation: XDelegatedHostedZoneAWS](../../applications/crossplane-resources/delegated-hosted-zone-aws/)
```

- [ ] **Step 2: Verify the file exists**

```bash
head -5 docs/adr/0011-crossplane-composition-design-pattern.md
```

Expected output:
```
# 11. Crossplane Composition Design Pattern for Multi-Cloud Orchestration

Date: 2026-06-10

## Status
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0011-crossplane-composition-design-pattern.md
git commit -m "docs(adr): add ADR-11 crossplane composition design pattern"
```

---

### Task 5: ADR-12 — Least-Privilege IAM Role Isolation for Crossplane Providers

**Files:**
- Create: `docs/adr/0012-least-privilege-iam-role-isolation-for-crossplane-providers.md`

- [ ] **Step 1: Write the ADR file**

```markdown
# 12. Least-Privilege IAM Role Isolation for Crossplane Providers

Date: 2026-06-10

## Status

Accepted

## Context

Crossplane providers need cloud credentials to reconcile managed resources.
The platform uses multiple AWS providers (IAM, Route53, Roles Anywhere) that
each require different permission scopes. Using a single shared credential for
all providers would:

- Violate the principle of least privilege
- Increase the blast radius if a provider credential is compromised
- Make it difficult to audit which provider performed which action in CloudTrail

Each Crossplane provider uses a `ProviderConfig` that references a credential
source. Providers running with a shared service account and shared IAM role
cannot be distinguished in IAM policy conditions or audit logs.

## Decision

Each Crossplane provider gets its own isolated credential stack:

1. **A dedicated Kubernetes ServiceAccount** in the provider's runtime namespace
   (e.g., `crossplane-system`). This is configured via `DeploymentRuntimeConfig`.

2. **A dedicated IAM Role** scoped to the minimum permissions the provider
   needs. The role trust policy allows only the provider's ServiceAccount
   (via SPIFFE SVID + IAM Roles Anywhere) to assume it.

3. **A dedicated ProviderConfig** that references the IAM Role ARN and Roles
   Anywhere Profile ARN for that provider's credential stack.

### Current provider isolation

| Provider | ProviderConfig | IAM Role scope |
|----------|---------------|----------------|
| `provider-aws-route53` | `route53-dns-admin` | Route53 hosted zone management scoped to delegated zones |
| `provider-aws-iam` | `iam-admin` | IAM Role/Policy/Attachment management |
| `provider-aws-rolesanywhere` | `rolesanywhere-admin` | Roles Anywhere Profile management |

IAM and Roles Anywhere providers use a shared `platform-iam-rolesanywhere`
`EnvironmentConfig` to source their ProviderConfig references by default.
Per-composition overrides are available via `spec.iamProviderConfigRef` and
`spec.rolesAnywhereProviderConfigRef`.

### ABAC session tag enforcement

IAM role trust policies use `aws:PrincipalTag/x509SAN/URI` conditions to
restrict role assumption to a specific SPIFFE URI. This ensures that only the
intended provider's workload identity can assume the role, even if another
workload has a valid Roles Anywhere certificate.

Example trust policy condition:

```json
"Condition": {
  "StringEquals": {
    "aws:PrincipalTag/x509SAN/URI":
      "spiffe://<trustDomain>/ns/crossplane-system/sa/<provider-sa-name>"
  }
}
```

### Adding a new provider

1. Create a `DeploymentRuntimeConfig` in the provider's application directory
   specifying a new ServiceAccount name.
2. Bootstrap the IAM Role and Roles Anywhere Profile out-of-band (AWS CLI or
   Terraform) using the crossplane cluster's SPIFFE trust anchor certificate.
   See the bootstrap runbook in `docs/runbooks/`.
3. Create a `ProviderConfig` referencing the new IAM Role and Profile ARNs.
4. Reference the new `ProviderConfig` from composition steps that use this
   provider.

## Consequences

- Adding a new Crossplane provider requires an out-of-band bootstrap step
  to provision IAM credentials. This cannot be fully automated by Crossplane
  itself (bootstrapping problem: Crossplane needs credentials to provision
  the credentials it needs).
- The `OP_SERVICE_ACCOUNT_TOKEN` secret in 1Password must have access to the
  IAM Role ARNs so they can be injected into ProviderConfig resources via
  External Secrets Operator.
- Provider credential isolation means a bug in one provider cannot
  accidentally modify resources owned by another provider.

## References

- [ADR-5: Using cert-manager to issue SPIFFE X.509 SVID Certificates](0005-using-cert-manager-to-issue-spiffe-x-509-svid-certificates-for-iam-access-roles-anywhere.md)
- [ADR-7: Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere](0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md)
- [ADR-11: Crossplane Composition Design Pattern](0011-crossplane-composition-design-pattern.md)
- [AWS IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html)
- [Crossplane: DeploymentRuntimeConfig](https://docs.crossplane.io/latest/concepts/providers/#runtime-configuration)
```

- [ ] **Step 2: Verify the file exists**

```bash
head -5 docs/adr/0012-least-privilege-iam-role-isolation-for-crossplane-providers.md
```

Expected output:
```
# 12. Least-Privilege IAM Role Isolation for Crossplane Providers

Date: 2026-06-10

## Status
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0012-least-privilege-iam-role-isolation-for-crossplane-providers.md
git commit -m "docs(adr): add ADR-12 least-privilege iam role isolation for crossplane providers"
```

---

### Task 6: ADR-13 — Helm Chart Hardening via Kustomize Patches

**Files:**
- Create: `docs/adr/0013-helm-chart-hardening-via-kustomize-patches.md`

- [ ] **Step 1: Write the ADR file**

```markdown
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

Kustomize's `HelmChartInflationGenerator` (via FluxCD's `HelmRelease`) allows
us to apply strategic-merge and JSON patches to Helm-rendered output without
modifying the chart source.

## Decision

We deploy upstream Helm charts via FluxCD `HelmRelease` resources, then apply
Kustomize patches to harden the rendered output. Patches are co-located with
the application's `base/kustomization.yaml` in the `resources/patches/`
subdirectory (or inline in `kustomization.yaml` for simple patches).

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
```

- [ ] **Step 2: Verify the file exists**

```bash
head -5 docs/adr/0013-helm-chart-hardening-via-kustomize-patches.md
```

Expected output:
```
# 13. Helm Chart Hardening via Kustomize Patches

Date: 2026-06-10

## Status
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0013-helm-chart-hardening-via-kustomize-patches.md
git commit -m "docs(adr): add ADR-13 helm chart hardening via kustomize patches"
```

---

### Task 7: ADR-14 — Workload Cluster Bootstrap and Lifecycle

**Files:**
- Create: `docs/adr/0014-workload-cluster-bootstrap-and-lifecycle.md`

- [ ] **Step 1: Write the ADR file**

```markdown
# 14. Workload Cluster Bootstrap and Lifecycle

Date: 2026-06-10

## Status

Accepted

## Context

The Crossplane control plane cluster (see ADR-3) manages infrastructure for
workload clusters, but workload clusters themselves need Flux installed and
configured to receive application manifests from the rendered repository.
Each workload cluster also requires:

- A unique SPIFFE trust domain for workload identity isolation (see ADR-16)
- Registration with the Crossplane control plane so that its infrastructure
  claims can be reconciled
- Network policies, priority classes, and other platform baseline components
  that must be present before application workloads are deployed

The bootstrap sequence is distinct from the control plane bootstrap (ADR-3)
because workload clusters do not run Crossplane — they consume platform
infrastructure provisioned by the control plane cluster.

## Decision

We bootstrap workload clusters using a defined sequence executed via scripts
in the `.bin/` directory. The sequence is:

### Phase 1: Cluster provisioning

Provision the Kubernetes cluster using the appropriate provider tooling
(e.g., `spotctl` for Rackspace Spot, `eksctl` for AWS EKS, `talosctl` for
Talos Linux). The cluster must be reachable via `kubectl` before proceeding.

Key scripts:
- `.bin/bootstrap-cluster.sh` — interactive bootstrap wizard
- `.bin/deploy-cluster.sh` — non-interactive deployment for known cluster configs

### Phase 2: SOPS key delivery

Each cluster needs the age private key to decrypt SOPS-encrypted secrets
committed to the rendered repository:

```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/path/to/age.key
```

This secret must exist before Flux can reconcile any SOPS-encrypted manifest.

### Phase 3: Flux bootstrap

Install Flux and point it at the rendered repository for this cluster:

```bash
flux bootstrap github \
  --owner=<rendered_repo_owner> \
  --repository=<rendered_repo_name> \
  --branch=main \
  --path=clusters/<cluster-name>
```

Flux creates a deploy key on the rendered repository and begins reconciling.
At this point, Flux will attempt to reconcile all components listed in
`clusters/<cluster-name>/kustomization.yaml`.

### Phase 4: SPIFFE trust domain configuration

Before cert-manager-spiffe-csi-driver is deployed, configure the cluster's
unique trust domain. See ADR-16 for requirements and the exact configuration
steps. The trust domain must match the `status.trustDomain` of the cluster's
`XDelegatedHostedZoneAWS` claim on the Crossplane control plane.

### Phase 5: Control plane registration

Create the `XDelegatedHostedZoneAWS` claim on the Crossplane control plane
cluster to provision the cluster's delegated DNS zone, IAM role, and Roles
Anywhere profile. This step requires the Crossplane control plane to be
healthy and the `csi-driver-spiffe-ca` trust anchor to be registered with
AWS IAM Roles Anywhere (see ADR-7 Phase 2).

### Decommissioning

To decommission a workload cluster:
1. Delete the `XDelegatedHostedZoneAWS` claim — this removes IAM and DNS
   resources via Crossplane.
2. Delete the cluster entry from `clusters/` in this repository and from the
   rendered repository.
3. Destroy the cluster using the provider tooling.
4. Remove the deploy key from the rendered repository.
5. Revoke the intermediate CA certificate on step-ca (if Pattern D is in use).

## Consequences

- Workload cluster bootstrap is a multi-step manual process. It cannot be
  fully automated yet because Flux bootstrap requires interactive credential
  handling and the SPIFFE trust domain must be configured before cert-manager
  deploys.
- The SOPS age key must be securely transferred to the cluster out-of-band.
  It must never be committed to any repository.
- A cluster that loses its SOPS secret will fail to reconcile SOPS-encrypted
  manifests until the secret is restored.
- Cluster lifecycle (provisioning and decommissioning) must be coordinated
  with the Crossplane control plane to avoid orphaned AWS resources.

## References

- [ADR-2: Bootstrapping a Flux-Enabled Kubernetes Cluster](0002-managing-a-consistent-development-environment.md)
- [ADR-3: Bootstrapping the Crossplane Controlplane Cluster](0003-bootstrapping-the-crossplane-controlplane-cluster.md)
- [ADR-7: Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere](0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md)
- [ADR-16: SPIFFE Trust Domain Configuration per Cluster](0016-spiffe-trust-domain-configuration-per-cluster.md)
- [FluxCD: Bootstrap](https://fluxcd.io/flux/installation/bootstrap/)
```

- [ ] **Step 2: Verify the file exists**

```bash
head -5 docs/adr/0014-workload-cluster-bootstrap-and-lifecycle.md
```

Expected output:
```
# 14. Workload Cluster Bootstrap and Lifecycle

Date: 2026-06-10

## Status
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0014-workload-cluster-bootstrap-and-lifecycle.md
git commit -m "docs(adr): add ADR-14 workload cluster bootstrap and lifecycle"
```

---

## Layer 3 — Operating the Platform

### Task 8: ADR-15 — Secret and Certificate Rotation Strategy

**Files:**
- Create: `docs/adr/0015-secret-and-certificate-rotation-strategy.md`

- [ ] **Step 1: Write the ADR file**

```markdown
# 15. Secret and Certificate Rotation Strategy

Date: 2026-06-10

## Status

Accepted

## Context

The platform manages several categories of secrets and certificates with
different owners, rotation mechanisms, and failure modes:

- **SPIFFE CA certificates** — issued by cert-manager, used as the root of
  trust for IAM Roles Anywhere
- **SOPS age keys** — asymmetric keypairs used to encrypt secrets committed to
  the repository
- **External Secrets** — runtime secrets fetched from 1Password by External
  Secrets Operator
- **Deploy keys** — SSH keys used by Flux to pull from rendered repositories
- **GitHub App credentials** — used by CI to push to rendered repositories

Each category has a different rotation mechanism. Treating them the same leads
to either under-rotation (security risk) or over-rotation (operational burden
without proportional security benefit).

## Decision

We define rotation cadence and mechanism per secret category:

### SPIFFE CA certificates (`csi-driver-spiffe-ca`)

- **Rotation cadence**: 90 days (automated by cert-manager)
- **Mechanism**: cert-manager renews the certificate ~30 days before expiry.
  The rotation cascade (TrustAnchor bundle update → step-ca restart →
  intermediate CA re-issue → SVID re-issue) must complete within the renewal
  window.
- **Key rotation**: `privateKey.rotationPolicy: Always` — the private key
  rotates on every renewal once Phase 2 TrustAnchor bundle overlap automation
  is in place (see ADR-7 Phase 1).
- **Runbooks**:
  - Scheduled rotation: `docs/runbooks/csi-driver-spiffe-ca-scheduled-rotation.md`
  - Emergency rollover: `docs/runbooks/csi-driver-spiffe-ca-emergency-rollover.md`
  - Trust anchor bootstrap: `docs/runbooks/csi-driver-spiffe-ca-trustanchor-bootstrap.md`

### SOPS age keys

- **Rotation cadence**: On-demand (when key compromise is suspected, or annually
  as a hygiene measure)
- **Mechanism**: Manual.
  1. Generate a new age keypair: `age-keygen -o new-key.txt`
  2. Re-encrypt all SOPS-encrypted files in the repository using both the old
     and new public keys (so the new key can decrypt, while in-flight CI runs
     using the old key still succeed):
     ```bash
     find . -name "*.sops.yaml" -exec sops updatekeys {} \;
     ```
  3. Update `.sops.yaml` to list only the new public key.
  4. Update the `sops-age` Kubernetes secret on all clusters:
     ```bash
     kubectl create secret generic sops-age \
       --namespace=flux-system \
       --from-file=age.agekey=new-key.txt \
       --dry-run=client -o yaml | kubectl apply -f -
     ```
  5. Remove the old public key from `.sops.yaml` and re-encrypt all files
     using only the new key.
- **Failure mode**: If the age secret is lost and the old key is unavailable,
  SOPS-encrypted secrets in the rendered repository cannot be decrypted and
  Flux reconciliation will fail for any component using those secrets.

### External Secrets (1Password via External Secrets Operator)

- **Rotation cadence**: No action required. ESO re-fetches secrets from
  1Password on every reconciliation cycle (default: every 1 hour).
- **Mechanism**: Update the secret value in 1Password. ESO will pick up the
  new value on the next sync. No Kubernetes secret needs to be manually updated.
- **Exception**: The `OP_SERVICE_ACCOUNT_TOKEN` GitHub secret (used by CI) must
  be rotated in both 1Password and the GitHub repository secrets when a new
  service account token is issued.

### Flux deploy keys (SSH)

- **Rotation cadence**: On-demand (when key compromise is suspected, or when
  access needs to be revoked)
- **Mechanism**:
  1. Generate a new SSH keypair: `ssh-keygen -t ed25519 -f new-deploy-key`
  2. Add the new public key to the rendered repository's deploy keys via `gh`:
     ```bash
     gh repo deploy-key add new-deploy-key.pub \
       --repo <owner>/<rendered-repo> \
       --title "flux-$(date +%Y%m%d)"
     ```
  3. Update the Flux `GitRepository` secret on the cluster with the new private key.
  4. Remove the old deploy key from the rendered repository.

### GitHub App credentials (render-flux-platform-src-app)

- **Rotation cadence**: Annually, or immediately on suspected compromise
- **Mechanism**: Rotate the private key in the GitHub App settings and update
  the `private-key` item in the `flux-platform-src` 1Password vault. The new
  key is picked up by CI on the next run via the `load-secrets-action`.

## Consequences

- SOPS age key rotation is the most operationally complex rotation in this list.
  Key loss without a backup is unrecoverable — the repository would need to be
  re-encrypted from scratch using plaintext values sourced from 1Password.
  Back up age private keys in a secure location (e.g., the 1Password vault)
  separately from the repository.
- Automated SPIFFE CA rotation requires the TrustAnchor bundle overlap controller
  described in ADR-7 Phase 1 to be in place before enabling
  `privateKey.rotationPolicy: Always`. Enabling key rotation without the
  overlap controller causes an immediate IAM Roles Anywhere outage.
- External Secrets rotation is transparent to operators — the only action is
  updating the value in 1Password.

## References

- [ADR-5: Using cert-manager to issue SPIFFE X.509 SVID Certificates](0005-using-cert-manager-to-issue-spiffe-x-509-svid-certificates-for-iam-access-roles-anywhere.md)
- [ADR-7: Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere](0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md)
- [Runbook: Scheduled SPIFFE CA rotation](../runbooks/csi-driver-spiffe-ca-scheduled-rotation.md)
- [Runbook: Emergency SPIFFE CA rollover](../runbooks/csi-driver-spiffe-ca-emergency-rollover.md)
- [Runbook: Trust anchor bootstrap](../runbooks/csi-driver-spiffe-ca-trustanchor-bootstrap.md)
- [Mozilla SOPS](https://github.com/getsops/sops)
- [age encryption](https://github.com/FiloSottile/age)
```

- [ ] **Step 2: Verify the file exists**

```bash
head -5 docs/adr/0015-secret-and-certificate-rotation-strategy.md
```

Expected output:
```
# 15. Secret and Certificate Rotation Strategy

Date: 2026-06-10

## Status
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0015-secret-and-certificate-rotation-strategy.md
git commit -m "docs(adr): add ADR-15 secret and certificate rotation strategy"
```

---

### Task 9: ADR-16 — SPIFFE Trust Domain Configuration per Cluster

**Files:**
- Create: `docs/adr/0016-spiffe-trust-domain-configuration-per-cluster.md`

- [ ] **Step 1: Write the ADR file**

```markdown
# 16. SPIFFE Trust Domain Configuration per Cluster

Date: 2026-06-10

## Status

Accepted

## Context

ADR-7 Decision 6 requires that every cluster using a shared IAM Roles Anywhere
trust anchor must be configured with a unique SPIFFE trust domain. This ADR
documents the implementation details for that requirement.

The default SPIFFE trust domain for Kubernetes workloads is `cluster.local`.
When multiple clusters share a trust anchor (Patterns B, C, D in ADR-7), all
clusters using `cluster.local` produce identical SPIFFE URIs — for example,
`spiffe://cluster.local/ns/external-dns/sa/external-dns`. IAM Roles Anywhere
validates only that a certificate chains to the trusted root CA; it does not
identify which cluster's intermediate CA signed it. This means a workload on
any cluster could impersonate a workload on any other cluster in the fleet.

## Decision

Every cluster must be configured with a unique SPIFFE trust domain before
cert-manager-spiffe-csi-driver is deployed. The trust domain is derived from
the cluster's `XDelegatedHostedZoneAWS` claim:

```
trustDomain = <spec.subdomain>.<resolvedZoneName>
```

For example, a claim with `spec.subdomain: crossplane` and resolved zone name
`rye.ninja` produces `trustDomain: crossplane.rye.ninja`.

This value is surfaced in `XDelegatedHostedZoneAWS.status.trustDomain` after
the claim reconciles.

### Configuring the trust domain

Set the trust domain on `cert-manager-spiffe-csi-driver` via its Helm values:

```yaml
# In the HelmRelease values for cert-manager-spiffe-csi-driver:
app:
  trustDomain: crossplane.rye.ninja  # must match XDelegatedHostedZoneAWS.status.trustDomain
```

This value must be set before or at the same time as `cert-manager-spiffe-csi-driver`
is first deployed. Changing it after deployment requires restarting all pods
that have a SPIFFE SVID mounted, because the CSI driver re-issues all
certificates with the new trust domain on restart.

### Verification

After configuring, verify that SVIDs issued to pods use the correct trust domain:

```bash
# On the workload cluster, inspect a mounted SPIFFE certificate
kubectl exec -n <namespace> <pod-name> -- \
  openssl x509 -in /var/run/secrets/spiffe.io/tls.crt -text -noout \
  | grep URI
```

Expected output:
```
URI:spiffe://crossplane.rye.ninja/ns/<namespace>/sa/<service-account>
```

Verify that the trust domain in the certificate matches the URIs in the IAM
role trust policy:

```bash
aws iam get-role --role-name <role-name> \
  --query 'Role.AssumeRolePolicyDocument' \
  | jq '.Statement[].Condition.StringEquals["aws:PrincipalTag/x509SAN/URI"]'
```

Both values must match exactly.

### Prohibited configuration

The value `cluster.local` is prohibited for any cluster participating in a
shared trust anchor design (Patterns B, C, or D in ADR-7). CI linting does
not currently enforce this automatically — it is a manual review requirement
for new cluster additions.

## Consequences

- Every new workload cluster requires a corresponding `XDelegatedHostedZoneAWS`
  claim to exist and be Ready before the SPIFFE trust domain can be derived.
  This creates a dependency: Crossplane must reconcile the claim before
  cert-manager-spiffe-csi-driver is fully configured.
- If the trust domain is changed after initial deployment, all workloads must
  be restarted to receive new certificates. This is a brief, rolling operation
  but requires coordination with ExternalDNS and cert-manager to avoid DNS
  or certificate issuance gaps.
- The trust domain value is implicitly tied to the cluster's DNS subdomain.
  Renaming the cluster's subdomain requires a trust domain migration, which
  also requires updating IAM role trust policies.

## References

- [ADR-5: Using cert-manager to issue SPIFFE X.509 SVID Certificates](0005-using-cert-manager-to-issue-spiffe-x-509-svid-certificates-for-iam-access-roles-anywhere.md)
- [ADR-7: Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere — Decision 6](0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md#decision)
- [ADR-14: Workload Cluster Bootstrap and Lifecycle](0014-workload-cluster-bootstrap-and-lifecycle.md)
- [cert-manager SPIFFE CSI Driver: trust domain configuration](https://cert-manager.io/docs/usage/csi-driver-spiffe/)
- [SPIFFE specification: Trust Domain](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/#trust-domain)
```

- [ ] **Step 2: Verify the file exists**

```bash
head -5 docs/adr/0016-spiffe-trust-domain-configuration-per-cluster.md
```

Expected output:
```
# 16. SPIFFE Trust Domain Configuration per Cluster

Date: 2026-06-10

## Status
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0016-spiffe-trust-domain-configuration-per-cluster.md
git commit -m "docs(adr): add ADR-16 spiffe trust domain configuration per cluster"
```

---

### Task 10: ADR-17 — Network Policy Default-Deny Enforcement

**Files:**
- Create: `docs/adr/0017-network-policy-default-deny-enforcement.md`

- [ ] **Step 1: Write the ADR file**

```markdown
# 17. Network Policy Default-Deny Enforcement

Date: 2026-06-10

## Status

Accepted

## Context

Kubernetes does not restrict pod-to-pod or pod-to-external traffic by default.
Without network policies, a compromised workload can freely communicate with
any other pod or external endpoint in the cluster.

The platform enforces a zero-trust network posture as a defense-in-depth
measure. Even if a workload is compromised, the blast radius is limited to
the traffic it has been explicitly granted.

Different Kubernetes CNI providers implement network policies differently.
The platform currently runs on Rackspace Spot, which uses Cilium as the CNI.
Cilium supports both standard Kubernetes `NetworkPolicy` and its own extended
`CiliumNetworkPolicy` resource with additional capabilities (e.g., DNS-based
egress rules, L7 policy).

## Decision

We enforce a global default-deny policy on all clusters and require every
application to declare its required traffic explicitly.

### Global default-deny policy

The `global-network-policy-default-deny` application deploys a default-deny
policy to all namespaces. Provider-specific variants exist:

- `applications/global-network-policy-default-deny/rackspace-spot/` — uses
  `CiliumNetworkPolicy` for Cilium-based clusters

The default-deny policy denies all ingress and egress for all pods in all
namespaces. It must be applied before any workloads are deployed.

### Per-application network policy requirements

Every application in `applications/` must include a network policy that grants
only the traffic it needs. Common patterns:

**Operator webhook server** (ingress from API server):
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: <component>-webhook
  namespace: <component>-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: <component>
  ingress:
    - ports:
        - port: 9443
          protocol: TCP
```

**Metrics scrape** (ingress from Prometheus):
```yaml
  ingress:
    - ports:
        - port: 9090
          protocol: TCP
      from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
```

**DNS egress** (required by almost all workloads):
```yaml
  egress:
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

**Kubernetes API server egress**:
```yaml
  egress:
    - ports:
        - port: 6443
          protocol: TCP
```

### Adding network policy for a new application

1. Identify what traffic the application needs:
   - What ports does it expose (webhooks, metrics, health probes)?
   - What does it call out to (Kubernetes API, cloud APIs, DNS)?
   - Does it need to be reachable from other namespaces?
2. Write a `NetworkPolicy` in `applications/<name>/resources/network-policy.yaml`.
3. Add it to `applications/<name>/base/kustomization.yaml` as a resource.
4. If the cluster uses Cilium, add a `CiliumNetworkPolicy` in the provider
   variant directory (`applications/<name>/rackspace-spot/`).

### Debugging network policy issues

If a component fails to start or behaves unexpectedly after deployment, check
for network policy blocks:

```bash
# On Cilium clusters, inspect policy verdicts
kubectl exec -n kube-system ds/cilium -- \
  cilium monitor --type drop 2>/dev/null | head -50
```

A `DROP` verdict with the component's pod IP as source or destination indicates
a missing network policy exception.

## Consequences

- Every new application deployment requires network policy authoring before
  the application can function. Missing network policies cause silent connection
  failures that can be difficult to diagnose without CNI-specific tooling.
- Health probes from the kubelet must be explicitly permitted. The kubelet IP
  is typically in the node's CIDR and may require a `namespaceSelector` or
  IP block exception depending on the CNI version.
- Provider-specific CiliumNetworkPolicy resources must be maintained in
  parallel with standard NetworkPolicy resources. If the platform migrates
  to a different CNI, Cilium-specific policies must be replaced.
- The `kube-linter` configuration (`.kube-linter/config.yaml`) enforces that
  all Deployments have a corresponding NetworkPolicy. PRs that add a Deployment
  without a NetworkPolicy will fail CI.

## References

- [ADR-10: GitOps Layering and Kustomize Composition Strategy](0010-gitops-layering-and-kustomize-composition-strategy.md)
- [ADR-13: Helm Chart Hardening via Kustomize Patches](0013-helm-chart-hardening-via-kustomize-patches.md)
- [Kubernetes: Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Cilium: Network Policy](https://docs.cilium.io/en/stable/security/policy/)
```

- [ ] **Step 2: Verify the file exists**

```bash
head -5 docs/adr/0017-network-policy-default-deny-enforcement.md
```

Expected output:
```
# 17. Network Policy Default-Deny Enforcement

Date: 2026-06-10

## Status
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0017-network-policy-default-deny-enforcement.md
git commit -m "docs(adr): add ADR-17 network policy default-deny enforcement"
```

---

### Task 11: ADR-18 — Backstage Catalog as Platform Topology Source of Truth

**Files:**
- Create: `docs/adr/0018-backstage-catalog-as-platform-topology-source-of-truth.md`

- [ ] **Step 1: Write the ADR file**

```markdown
# 18. Backstage Catalog as Platform Topology Source of Truth

Date: 2026-06-10

## Status

Accepted

## Context

The platform is composed of many independently deployed components spread
across `applications/` and `clusters/`. Without a registry of what the platform
provides, new contributors and application teams must read the entire directory
tree to discover available capabilities.

Backstage is a developer portal that provides a service catalog. We already
use Backstage at the organization level. Requiring each component to self-register
via a co-located `catalog.yaml` means the catalog is always in sync with the
deployed components — no separate registration step is needed.

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
| `networking` | Network policy or traffic management |
| `secrets` | Secret management or delivery |
| `flux` | Flux CD component |
| `crossplane` | Crossplane or Crossplane provider |
| `spiffe` | SPIFFE/SVID related |
| `csi` | CSI driver |

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
```

- [ ] **Step 2: Verify the file exists**

```bash
head -5 docs/adr/0018-backstage-catalog-as-platform-topology-source-of-truth.md
```

Expected output:
```
# 18. Backstage Catalog as Platform Topology Source of Truth

Date: 2026-06-10

## Status
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0018-backstage-catalog-as-platform-topology-source-of-truth.md
git commit -m "docs(adr): add ADR-18 backstage catalog as platform topology source of truth"
```
