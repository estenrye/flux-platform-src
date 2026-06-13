# Design: Get Cloudspace Kubeconfigs

Date: 2026-06-12

## Context

Rackspace Spot clusters are managed via `spotctl cloudspaces get-config`. Kubeconfigs need
to be fetched locally before running `kubectl` or `flux` commands against a cluster. The
existing `oci-kubeconfig` Make target references a script that was never written. This spec
replaces it with a working implementation.

## Output Path Convention

Kubeconfigs are written to `~/.kube/spot/<org>/<cloudspace-name>.yaml`. This keeps Spot
kubeconfigs isolated from other kubeconfigs under `~/.kube/` and groups them by org.

## Catalog Annotations

Each `clusters/<name>/catalog.yaml` carries two new annotations that the script reads:

```yaml
metadata:
  annotations:
    rye.ninja/spot-org: ryezone-labs
    rye.ninja/spot-cloudspace-name: crossplane-controlplane-cluster
```

The existing `rye.ninja/kubeconfig` annotation is updated to match the new path convention:

```yaml
rye.ninja/kubeconfig: ~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
```

`prompt-kubeconfig.sh` already expands `~` to `$HOME`, so no lib changes are needed.

Clusters that lack these annotations are silently skipped — safe for future clusters added
before they are annotated.

## Script: `.bin/get-cloudspace-kubeconfigs.sh`

Iterates `clusters/*/catalog.yaml`. For each catalog:

1. Reads `rye.ninja/spot-org` and `rye.ninja/spot-cloudspace-name` via `yq`.
2. Skips if either annotation is `null`.
3. Creates `~/.kube/spot/<org>/` if it does not exist.
4. Calls `spotctl cloudspaces get-config --name <name> --org <org> --file <out>`.

Uses `.venv/bin/spotctl` and `.venv/bin/yq` (both already present). Sources
`.bin/lib/prompt-color.sh` for `info`/`success` output helpers.

## Make Target

Replaces the dead `oci-kubeconfig` target (which referenced a non-existent script):

```makefile
get-cloudspace-kubeconfigs:
	@.bin/get-cloudspace-kubeconfigs.sh
```

The `@` suppresses echoing the command line, consistent with other bootstrap targets.

## Skill: `.claude/skills/get-cloudspace-kubeconfigs.md`

A reference skill Claude consults when it needs kubectl context for a Rackspace Spot
cluster. Tells Claude to run `make get-cloudspace-kubeconfigs` and how to resolve the
correct `KUBECONFIG` path for a specific cluster from the catalog annotation.

## Files Changed

| File | Change |
|---|---|
| `clusters/crossplane/catalog.yaml` | Add `spot-org`, `spot-cloudspace-name` annotations; update `kubeconfig` annotation path |
| `.bin/get-cloudspace-kubeconfigs.sh` | New script |
| `Makefile` | Replace `oci-kubeconfig` with `get-cloudspace-kubeconfigs` |
| `.claude/skills/get-cloudspace-kubeconfigs.md` | New reference skill |
