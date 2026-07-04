# Get Cloudspace Kubeconfigs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `make get-cloudspace-kubeconfigs` target that fetches Rackspace Spot kubeconfigs for all clusters defined in the repo and writes them to `~/.kube/spot/<org>/<cloudspace-name>.yaml`.

**Architecture:** Catalog-driven — each `clusters/*/catalog.yaml` carries `rye.ninja/spot-org` and `rye.ninja/spot-cloudspace-name` annotations. A shell script iterates all catalogs, reads those annotations via `yq`, and calls `spotctl cloudspaces get-config` per cluster. A reference skill at `.claude/skills/get-cloudspace-kubeconfigs.md` tells Claude how to use the target and resolve the right `KUBECONFIG` path for a cluster.

**Tech Stack:** bash, yq (`.venv/bin/yq`), spotctl (`.venv/bin/spotctl`), GNU Make

**Spec:** [docs/superpowers/specs/2026-06-12-get-cloudspace-kubeconfigs-design.md](../specs/2026-06-12-get-cloudspace-kubeconfigs-design.md)

---

### Task 1: Add catalog annotations to clusters/crossplane/catalog.yaml

**Files:**
- Modify: `clusters/crossplane/catalog.yaml`

- [ ] **Step 1: Update catalog.yaml**

Replace the file contents with:

```yaml
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: crossplane
  annotations:
    github.com/project-slug: estenrye/flux-platform-rendered
    rye.ninja/flux-source-repo: estenrye/flux-platform-src
    rye.ninja/kubeconfig: ~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
    rye.ninja/spot-org: ryezone-labs
    rye.ninja/spot-cloudspace-name: crossplane-controlplane-cluster
  description: Crossplane system for managing cloud resources
spec:
  owner: platform-engineering
  domain: controlplane
```

- [ ] **Step 2: Verify annotations are readable**

Run:
```bash
yq e '.metadata.annotations["rye.ninja/spot-org"]' clusters/crossplane/catalog.yaml
yq e '.metadata.annotations["rye.ninja/spot-cloudspace-name"]' clusters/crossplane/catalog.yaml
yq e '.metadata.annotations["rye.ninja/kubeconfig"]' clusters/crossplane/catalog.yaml
```

Expected output:
```
ryezone-labs
crossplane-controlplane-cluster
~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
```

- [ ] **Step 3: Commit**

```bash
git add clusters/crossplane/catalog.yaml
git commit -m "feat: add spot-org and spot-cloudspace-name annotations to crossplane catalog"
```

---

### Task 2: Create .bin/get-cloudspace-kubeconfigs.sh

**Files:**
- Create: `.bin/get-cloudspace-kubeconfigs.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/prompt-color.sh"

for catalog in "${REPO_ROOT}"/clusters/*/catalog.yaml; do
  org=$(yq e '.metadata.annotations["rye.ninja/spot-org"]' "${catalog}")
  name=$(yq e '.metadata.annotations["rye.ninja/spot-cloudspace-name"]' "${catalog}")

  if [ "${org}" = "null" ] || [ "${name}" = "null" ]; then
    warn "Skipping ${catalog}: missing spot-org or spot-cloudspace-name annotation"
    continue
  fi

  out="${HOME}/.kube/spot/${org}/${name}.yaml"
  mkdir -p "$(dirname "${out}")"

  info "Fetching kubeconfig for ${name} (org: ${org}) → ${out}"
  "${SCRIPT_DIR}/../.venv/bin/spotctl" cloudspaces get-config \
    --name "${name}" \
    --org "${org}" \
    --file "${out}"
  success "Saved ${out}"
done
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x .bin/get-cloudspace-kubeconfigs.sh
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n .bin/get-cloudspace-kubeconfigs.sh
```

Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
git add .bin/get-cloudspace-kubeconfigs.sh
git commit -m "feat: add get-cloudspace-kubeconfigs script"
```

---

### Task 3: Update Makefile — replace oci-kubeconfig target

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Replace the oci-kubeconfig target**

Find this block in `Makefile`:

```makefile
oci-kubeconfig:
	@.bin/oci-kubeconfig.sh
```

Replace it with:

```makefile
get-cloudspace-kubeconfigs:
	@.bin/get-cloudspace-kubeconfigs.sh
```

- [ ] **Step 2: Verify the target is parseable**

```bash
make -n get-cloudspace-kubeconfigs
```

Expected output:
```
.bin/get-cloudspace-kubeconfigs.sh
```

- [ ] **Step 3: Verify oci-kubeconfig is gone**

```bash
grep -n "oci-kubeconfig" Makefile
```

Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "feat: replace oci-kubeconfig with get-cloudspace-kubeconfigs make target"
```

---

### Task 4: Create .claude/skills/get-cloudspace-kubeconfigs.md

**Files:**
- Create: `.claude/skills/get-cloudspace-kubeconfigs.md`

- [ ] **Step 1: Create the skills directory**

```bash
mkdir -p .claude/skills
```

- [ ] **Step 2: Create the skill file**

```markdown
---
name: get-cloudspace-kubeconfigs
description: Use when kubectl context is needed for a Rackspace Spot cluster and kubeconfigs may be missing or stale.
---

# Get Cloudspace Kubeconfigs

## How to fetch kubeconfigs

Run from the repo root:

    make get-cloudspace-kubeconfigs

This iterates every cluster under `clusters/*/catalog.yaml`, reads the
`rye.ninja/spot-org` and `rye.ninja/spot-cloudspace-name` annotations, and writes
kubeconfigs to `~/.kube/spot/<org>/<cloudspace-name>.yaml`.

Requires `spotctl` to be authenticated. If the command fails with an auth error, the
user needs to run `spotctl configure` first.

## Finding the right KUBECONFIG path for a cluster

Read the `rye.ninja/kubeconfig` annotation from the cluster's catalog:

    yq e '.metadata.annotations["rye.ninja/kubeconfig"]' clusters/<name>/catalog.yaml

Set KUBECONFIG to that path (expanding `~` to `$HOME`) before running kubectl or flux
commands against the cluster.
```

- [ ] **Step 3: Verify frontmatter fields are present**

```bash
grep -E "^name:|^description:" .claude/skills/get-cloudspace-kubeconfigs.md
```

Expected:
```
name: get-cloudspace-kubeconfigs
description: Use when kubectl context is needed for a Rackspace Spot cluster and kubeconfigs may be missing or stale.
```

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/get-cloudspace-kubeconfigs.md
git commit -m "feat: add get-cloudspace-kubeconfigs reference skill"
```
