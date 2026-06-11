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
