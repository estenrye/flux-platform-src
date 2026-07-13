---
name: rendered-repo-automerge-milestone
description: Auto-merge is intentionally disabled on the rendered repos until a CI/CD-checks milestone; renders soft-warn and leave PRs for manual merge
metadata:
  type: project
---

The render pipeline (`.github/workflows/render-flux-repository.yml`) pushes each
cluster's rendered manifests to a target repo (`flux-platform-rendered`,
`flux-platform-rendered-controlplane`) as a PR and, on `main` pushes, calls
`gh pr merge --auto` (see `.bin/render/render-put-target-repository-pr.sh`).

**Auto-merge is deliberately OFF (`allow_auto_merge=false`) on both rendered
repos.** It will not be enabled until a **separate milestone adds required
status checks (CI/CD) to the rendered repos** — enabling auto-merge without
checks would let unvalidated renders self-merge into what Flux applies.

**Why:** decided 2026-07-13 while closing out the crossplane SOPS-key rotation.
The render kept failing at the auto-merge step (`Auto merge is not allowed for
this repository`), which had to be worked around by manually merging the
rendered PRs.

**How to apply:**
- Until the milestone lands, `main` renders will **not** auto-merge. The
  rendered PRs are still created — merge them by hand (e.g.
  `gh pr merge <n> --repo estenrye/flux-platform-rendered --squash`) so Flux
  picks up the new revision.
- The PR-merge step degrades gracefully: when the repo disallows auto-merge it
  emits a `::warning::` and leaves the PR open instead of failing the job. Any
  *other* merge error still fails the render. So a red render at the merge step
  now means a real problem, not the known auto-merge gap.
- Do **not** just flip `allow_auto_merge=true` — the required-checks milestone
  is the prerequisite. See [[cluster-kubeconfig-lookup]] for reaching the
  clusters and [[crossplane-credential-rotation]] for the rotation context.
