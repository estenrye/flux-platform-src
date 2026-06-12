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
  belonging to this source repository (clusters missing this annotation are skipped)
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

The `push-cluster` job only runs after `render-and-lint` passes.

### Job: push-cluster (matrix)

Runs once per discovered cluster, in parallel (`fail-fast: false`). Per cluster:

1. **Loads 1Password secrets** via `1password/load-secrets-action@v2`. The
   `OP_SERVICE_ACCOUNT_TOKEN` is the only secret stored in GitHub. It resolves:
   - `RENDER_APP_PRIVATE_KEY` from `op://flux-platform-src/render-flux-platform-src-app/private-key`
   - `RENDER_APP_ID` from `op://flux-platform-src/render-flux-platform-src-app/app-id`

2. **Generates a GitHub App token** via `actions/create-github-app-token@v1`
   scoped to the rendered repository for that cluster. This avoids personal
   access tokens and ties write access to the GitHub App lifecycle.

3. **Clones the rendered repository**, creates a branch, copies the rendered
   manifests, commits, and creates or updates a pull request.

4. **On push to `main`** (detected via `AUTO_MERGE=true`): the rendered PR is
   auto-merged immediately, triggering Flux reconciliation. On pull request
   events, a draft PR is created for review before merge.

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
