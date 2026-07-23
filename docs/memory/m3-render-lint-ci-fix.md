---
name: m3-render-lint-ci-fix
description: render-and-lint CI was silently broken for the entire M3 storage buildout (steps 1-4); root cause and fix in PR #100
metadata:
  type: project
---

Discovered and fixed 2026-07-23. `render-and-lint` (checkov + kube-linter)
had failed on **every single push and PR run** since M3 step 1 kicked off
(commit a0cedc0, 2026-07-21) through step 4 (ba37a67) — including plain
pushes to `main`. Because `push-cluster` `needs: render-and-lint`, this
silently skipped the job that syncs to `flux-platform-rendered-controlplane`
on nearly every run. The repo still ended up in sync because the
PR-triggered run occasionally succeeded before a later commit broke it
again, and PRs were merged/rendered-PRs manually merged despite the red X —
not because the pipeline was healthy.

**Root cause**: the checkov/kube-linter exemption annotations added for
democratic-csi's Deployments/DaemonSets (thorough, well-reasoned
annotations!) used kustomize `patches[].target.name` values that didn't
match the actual Helm-rendered resource names — e.g. target name
`democratic-csi-nfs` when the real resource is
`democratic-csi-nfs-controller` / `democratic-csi-nfs-node`. A kustomize
JSON6902 patch whose target matches zero resources fails **silently** (no
error, no warning) — so none of those annotations ever actually applied,
and checkov/kube-linter kept flagging the same ~345/~736 findings every
run.

**Fix** (PR #100, merged): corrected all 4 patch targets, fixed one wrong
check ID (`CKV_K8S_17` ShareHostPID vs. the actual hostNetwork check
`CKV_K8S_19`), added exemptions that were newly surfaced once patches
started applying, pinned a previously-unpinned busybox digest, fixed a
deprecated `serviceAccount` field, and added missing
`strategy`/`updateStrategy`/`restartPolicy`. `make lint-checkov` and
`make lint-kube-linter` both went from hundreds of failures to 0.

**How to apply**: when adding a kube-linter/checkov exemption annotation
via a kustomize patch on a Helm-rendered resource, always verify the
patch actually applied by grepping the **rendered output** for the
annotation — a clean `kustomize build` exit code proves nothing, since
target-match failures are silent. `kubectl apply --dry-run=server`
against the rendered file surfaces resource-shape errors but not
zero-match patches either.

See [[m3-step-tracker]] for what this CI breakage was masking (the step 4
WAL/restore gap).
