# ADR Additions for New Contributors — Design Spec

**Date:** 2026-06-10
**Status:** Approved

## Goal

Add 11 Architecture Decision Records (ADR-8 through ADR-18) to `docs/adr/` that document architectural decisions already implemented in code but not yet recorded. Organized as a journey-ordered onboarding path serving both platform engineers and application teams.

## Approach

ADRs are written in journey order so the index doubles as a learning path:

1. **Layer 1 — Understanding**: How changes flow through the system (both audiences)
2. **Layer 2 — Extending**: How to add new capabilities to the platform (platform engineers)
3. **Layer 3 — Operating**: Day-two operational decisions (both audiences)

Each ADR uses the existing `adr-tools` template format (found in `docs/adr/`).

---

## Layer 1 — Understanding How Changes Flow

### ADR-8: Source vs. Rendered Repository Pattern

- **Audience:** Both
- **Core decision:** The platform uses two repositories — `flux-platform-src` (human-authored Kustomize source) and `flux-platform-rendered` (CI-generated, Flux-reconciled manifests). Flux watches the rendered repo only.
- **Key points to capture:**
  - Why the split exists (separation of authoring from reconciliation; linting gate before cluster delivery)
  - What belongs in each repo
  - How a change travels from a PR in src to a running pod in a cluster
  - Never commit hand-edited manifests directly to the rendered repo

### ADR-9: CI/CD Pipeline Architecture

- **Audience:** Both
- **Core decision:** GitHub Actions drives the render → lint → push pipeline. 1Password Service Account provides all pipeline secrets at runtime. Automated PRs are created to the rendered repo; merges are gated on kube-linter and checkov passing.
- **Key points to capture:**
  - Pipeline stages: discover → render (kustomize build) → lint (kube-linter + checkov) → push to rendered repo
  - 1Password Service Account as the single secret-injection mechanism for CI
  - GitHub App token generation for rendered-repo PRs
  - What triggers the pipeline (PRs to src, merges to main)

### ADR-10: GitOps Layering and Kustomize Composition Strategy

- **Audience:** Platform engineers
- **Core decision:** All applications follow a `base/` + provider-overlay structure. `clusters/crossplane/kustomization.yaml` is the single aggregation point. New applications must provide a `base/` kustomization and register there.
- **Key points to capture:**
  - Directory conventions: `applications/<name>/base/`, provider-specific overlays adjacent
  - How to add a new application (the minimal required files)
  - Naming conventions: kebab-case dirs, `{operator}-system` namespaces, `X{PascalCase}` XRDs
  - Why Kustomize patches are preferred over forking Helm values

---

## Layer 2 — Extending the Platform

### ADR-11: Crossplane Composition Design Pattern for Multi-Cloud Orchestration

- **Audience:** Platform engineers
- **Core decision:** Business-level infrastructure claims (`XDelegatedHostedZoneAWS`) abstract multi-provider complexity behind a single Crossplane XRD. Compositions use a function pipeline (environment-configs → go-templating → auto-ready). Outputs (ARNs, zone IDs, trust domains) are surfaced to claims for downstream consumption.
- **Key points to capture:**
  - When to create a new XRD vs. use a provider resource directly
  - Function pipeline structure and ordering
  - Status output propagation pattern
  - Reference: `XDelegatedHostedZoneAWS` as the canonical example

### ADR-12: Least-Privilege IAM Role Isolation for Crossplane Providers

- **Audience:** Platform engineers
- **Core decision:** Each Crossplane provider gets its own ProviderConfig, runtime service account, and IAM role scoped to the minimum required permissions. ABAC session tags (`x509SAN/URI`) are used to restrict which workloads can assume roles.
- **Key points to capture:**
  - One ProviderConfig per provider (not shared)
  - Separate runtime configs for IAM vs. Roles Anywhere providers
  - How to wire a new provider: service account → IAM role → ProviderConfig
  - ABAC policy structure for session tag conditions

### ADR-13: Helm Chart Hardening via Kustomize Patches

- **Audience:** Platform engineers
- **Core decision:** Upstream Helm charts are deployed via FluxCD HelmRelease and then hardened with Kustomize strategic-merge and JSON patches. Network policies, RBAC augmentations, and health probe customizations are injected post-render rather than forked into the chart.
- **Key points to capture:**
  - Why patching is preferred over forking (upstream upgrades stay clean)
  - Standard patch categories: network policy injection, health probe customization, RBAC augmentation
  - Digest pinning for all images (reproducibility)
  - Where patches live relative to the `base/` kustomization

### ADR-14: Workload Cluster Bootstrap and Lifecycle

- **Audience:** Platform engineers
- **Core decision:** Workload clusters are provisioned separately from the Crossplane control plane cluster. Each workload cluster is bootstrapped with Flux pointing at the rendered repo, registered with the control plane, and assigned its own SPIFFE trust domain.
- **Key points to capture:**
  - Bootstrap sequence: provision cluster → install Flux → point at rendered repo → register with control plane
  - Role of `.bin/bootstrap-cluster*.sh` and `.bin/deploy-cluster.sh`
  - How the cluster gets a unique SPIFFE trust domain (see ADR-16)
  - Relationship to ADR-3 (control plane bootstrap) and ADR-2 (Flux bootstrap)

---

## Layer 3 — Operating the Platform

### ADR-15: Secret and Certificate Rotation Strategy

- **Audience:** Both
- **Core decision:** Secrets and certificates have distinct rotation mechanisms. SPIFFE CA certificates rotate on a 90-day scheduled cadence with emergency rollover capability. SOPS age keys rotate manually. External Secrets pull fresh values from 1Password on each reconciliation cycle.
- **Key points to capture:**
  - SPIFFE CA: 90-day scheduled rotation (runbook exists) vs. emergency rollover (runbook exists)
  - SOPS age key rotation: manual process, requires re-encrypting all secrets in-repo
  - External Secrets: no rotation action needed — ESO re-fetches from 1Password on reconcile
  - Deploy keys and GitHub App tokens: rotation triggers pipeline re-configuration
  - Reference existing runbooks in `docs/runbooks/`

### ADR-16: SPIFFE Trust Domain Configuration per Cluster

- **Audience:** Platform engineers
- **Core decision:** Every cluster must be configured with a unique SPIFFE trust domain (not the default `cluster.local`). Sharing trust domains between clusters breaks the ABAC isolation guarantees required by IAM Roles Anywhere (per ADR-7 Pattern D).
- **Key points to capture:**
  - Why `cluster.local` is unsafe in a shared-trust-anchor setup
  - How to set a unique trust domain for a new cluster
  - Relationship to ADR-7 (which mandates uniqueness but doesn't document the implementation)
  - Verification steps after configuration

### ADR-17: Network Policy Default-Deny Enforcement

- **Audience:** Both
- **Core decision:** A global default-deny NetworkPolicy is enforced on all clusters. Every application must explicitly declare the ingress/egress it needs. Provider-specific variants exist (e.g., Rackspace Spot uses CiliumNetworkPolicy in addition to standard NetworkPolicy).
- **Key points to capture:**
  - Why default-deny (blast radius reduction, zero-trust posture)
  - How to add a network policy exception for a new application
  - Standard policy structure for common patterns (operator webhook, metrics scrape, DNS egress)
  - Provider-specific variants and when to use each

### ADR-18: Backstage Catalog as Platform Topology Source of Truth

- **Audience:** Both
- **Core decision:** Every application in `applications/` includes a `catalog.yaml` with Backstage Component metadata. Tags follow a defined vocabulary. The catalog is the canonical way to discover what the platform provides and who owns it.
- **Key points to capture:**
  - Required fields: `metadata.name`, `metadata.tags`, `spec.type`, `spec.owner`
  - Tag vocabulary (platform, operators, infrastructure, etc.)
  - How to register a new component
  - How app teams query the catalog to find platform capabilities

---

## File Naming Convention

ADRs follow the existing `adr-tools` format in `docs/adr/`:

```
NNNN-<kebab-case-title>.md
```

Each file uses the standard header:
```
# N. Title

Date: YYYY-MM-DD

## Status

Accepted

## Context
## Decision
## Consequences
```

---

## Out of Scope

- ADR-4 (Netflix Dispatch) and ADR-6 (Cross-cloud showback) remain as-is — both are active proposals for future implementation.
- No changes to existing ADRs (ADR-1 through ADR-7).
- Operational runbooks in `docs/runbooks/` are referenced by ADRs but not modified.
