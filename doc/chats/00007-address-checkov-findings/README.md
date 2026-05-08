# Addressing Checkov Lint Findings

**Date:** May 8, 2026
**Chat ID:** 00007
**Context:** Installing checkov and remediating `CKV_K8S_43` and `CKV_K8S_40` lint failures across all platform applications

## Overview

This session covered the full lifecycle of integrating checkov into the `make lint` pipeline, from initial installation through systematic remediation of two categories of findings. The work resulted in a net reduction of lint failures from 133 (initial baseline) to 65.

---

## Part 1: Installing Checkov

### Initial Approach — GitHub Binary (Abandoned)

Following the patterns in `.bin/install-*.sh`, an initial script was created to download the standalone checkov binary from GitHub releases. This revealed two bugs:

1. **Wrong binary path**: The binary inside the release zip is at `dist/checkov`, not the zip root. Fixed with `mv ${TMP_DIR}/dist/checkov`.
2. **Absolute path bug in standalone binary**: The GitHub-released binary silently skipped all files when the scan directory was specified as an absolute path containing hidden directories (e.g. `.render/`). `make lint` returned no output while direct invocation returned 133 failures. This was a non-obvious regression in the standalone binary build.

### Final Approach — pip in Isolated venv

Switched to `pip install checkov` to avoid the binary bugs and dependency conflicts (checkov's botocore requirements conflict with the shared `.venv` awscli install).

**Architecture:**
- `.venv-checkov/` — isolated Python venv with checkov 3.2.527
- `.venv/bin/checkov` — wrapper script that delegates to `.venv-checkov/bin/checkov`

**SSL Certificate Fix:**
The wrapper auto-detects the certifi CA bundle from the isolated venv and sets `SSL_CERT_FILE` to resolve Prisma Cloud API SSL verification failures on macOS:

```bash
SSL_CERT_FILE=$("${CHECKOV_VENV_DIR}/bin/python3" -c "import certifi; print(certifi.where())" 2>/dev/null)
```

**`kustomize` framework limitation:**
checkov's `--framework kustomize` silently skips kustomizations that use `helmCharts` entries. The workaround is to pre-render with `make render` (kustomize + helm) and then scan the rendered output with `--framework kubernetes`. `.bin/lint.sh` was updated accordingly.

### Files Created/Modified

- `.bin/install-checkov.sh` — pip-based installer with isolated venv and wrapper
- `.bin/lint.sh` — updated to run `--framework kubernetes` against `.render/`

---

## Part 2: CKV_K8S_43 — Image Should Use Digest

**Check:** `CKV_K8S_43` — all container images must reference a specific `@sha256:...` digest rather than a mutable tag.

**Count:** 26 failures across 12 applications.

### Approach

Per the Helm values decision matrix (user memory), Helm `image.digest` fields were checked first. No chart in this codebase exposed a `digest` parameter cleanly enough to use values. The kustomize `images:` block with `digest:` key was used universally — it is semantics-preserving: the tag is retained in the manifest for readability, and kustomize appends the digest.

### Digests Resolved

Digests were resolved using `docker buildx imagetools inspect <image> --format '{{json .Manifest.Digest}}'` against each registry.

### Changes Made

`images:` blocks were added to the kustomization.yaml for each application:

| Application | Images Pinned |
|---|---|
| `cert-manager/base` | cert-manager-controller, cainjector, webhook |
| `cert-manager-trust-manager/base` | trust-manager, trust-pkg-debian-bookworm |
| `cert-manager-approver-policy/base` | approver-policy, kube-rbac-proxy |
| `cert-manager-spiffe-csi-driver/base` | csi-driver-spiffe, spiffe-approver, csi-node-driver-registrar, livenessprobe |
| `reloader/base` | reloader |
| `flux-monitoring/base` | kube-state-metrics |
| `crossplane/base` | crossplane |
| `external-dns/cloudflare/base` | external-dns |
| `external-dns/aws/base` | external-dns |
| `flux/base` | helm-controller, image-automation-controller, image-reflector-controller, kustomize-controller, notification-controller, source-controller |
| `opentelemetry-operator/base` | opentelemetry-operator, kube-rbac-proxy, busybox |
| `example-app-spiffe-csi` (deployment.yaml) | busybox pinned inline as `busybox:1.37.0@sha256:...` |

**Result:** 0 `CKV_K8S_43` failures. Total failures: 133 → 80.

---

## Part 3: CKV_K8S_40 — Containers Should Run as a High UID

**Check:** `CKV_K8S_40` — `runAsUser` must be `>= 10000` to avoid conflicts with host UIDs. UID `65532` (the standard distroless non-root user) was chosen as the target.

**Count:** 13 failures across 7 applications.

### Findings and Approach

| Resource | Root Cause | Fix |
|---|---|---|
| `cert-manager` (controller, cainjector, webhook) | `runAsUser: 999` set in values.yaml | Changed to `65532` in values.yaml (Helm values) |
| `cert-manager-approver-policy` | `runAsUser: 999` in values.yaml | Changed to `65532` in values.yaml (Helm values) |
| `cert-manager-trust-manager` | No `runAsUser` set at all; chart doesn't expose it as a value | Added pod SC + per-container `runAsUser: 65532` via JSON patch in `patches/deployment.trust-manager.yaml` |
| `cert-manager-csi-driver-spiffe-approver` | No `runAsUser`; chart doesn't expose it | Added pod SC + container `runAsUser: 65532` via JSON patch in `patches/deployment.yaml` |
| `cert-manager-csi-driver-spiffe-driver` (DaemonSet) | Runs as root (`runAsUser: 0`) — intentional; CSI spec requires it for mount operations | Added `checkov.io/skip1` annotation via `patches/daemonset.yaml` with justification |
| Flux controllers (6 deployments) | No `runAsUser` in upstream install.yaml | Added pod SC + container `runAsUser: 65532` to generic `patches/deployment.yaml` (applies to all 6 controllers) |
| `my-csi-app` (example app) | `runAsUser: 2000` | Changed to `65532` directly in `resources/deployment.yaml` |

### Why the CSI DaemonSet Is Skipped

The `cert-manager-csi-driver-spiffe-driver` DaemonSet must run all containers as UID 0. It requires:
- `CAP_SYS_ADMIN` for bind-mount operations (certificate provisioning into pod volumes)
- Bidirectional mount propagation to `/var/lib/kubelet/pods` (requires `privileged: true`)
- Write access to kubelet plugin registry (`/var/lib/kubelet/plugins_registry`)

This is a CSI specification requirement and cannot be changed. The skip annotation includes a justification string.

### Changes Made

```
applications/cert-manager/base/values.yaml                           runAsUser: 999 → 65532 (8 occurrences)
applications/cert-manager-approver-policy/base/values.yaml          runAsUser: 999 → 65532 (2 occurrences)
applications/cert-manager-trust-manager/base/patches/deployment.trust-manager.yaml  added securityContext ops
applications/cert-manager-spiffe-csi-driver/base/patches/deployment.yaml            added securityContext ops
applications/cert-manager-spiffe-csi-driver/base/patches/daemonset.yaml             added checkov skip annotation
applications/flux/base/patches/deployment.yaml                       added securityContext ops
applications/example-app-spiffe-csi/resources/deployment.yaml       runAsUser: 2000 → 65532
```

**Result:** 0 `CKV_K8S_40` failures, 1 intentional skip. Total failures: 80 → 65.

---

## Final State

| Check | Before | After |
|---|---|---|
| `CKV_K8S_43` (image digest) | 26 | 0 |
| `CKV_K8S_40` (high UID) | 13 | 0 (1 skip) |
| All other checks | ~94 | 65 |
| **Total failures** | **133** | **65** |
| Skipped | 0 | 1 |

## Key Decisions

1. **pip over standalone binary** — The GitHub-released checkov standalone binary has a path-handling bug that silently skips files when the scan path is absolute and contains hidden directories. The pip install is more reliable.

2. **Isolated venv for checkov** — checkov's botocore/s3transfer pin conflicts with awscli in the shared `.venv`. Isolation avoids dependency hell on every future `pip install --upgrade`.

3. **kustomize `images:` for digest pinning** — No chart in this repo exposes a `digest` Helm value. The kustomize `images:` block is the correct layer for this concern; it keeps source manifests readable while enforcing immutability in rendered output.

4. **UID `65532`** — Used consistently across all changes. This is the GID/UID used by Google's distroless images and is widely adopted in the Kubernetes ecosystem (used by Crossplane, cert-manager upstream, and others).

5. **Checkov skip annotation for CSI DaemonSet** — The annotation approach (`checkov.io/skip1`) keeps the justification co-located with the resource definition. An alternative would be a `.checkov.yaml` baseline file, but annotation is preferred because it makes the exception visible to anyone reading the patch.
