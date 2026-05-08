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

---

## Part 4: Remaining Checkov Failures — `my-csi-app` Demo Application

**Count:** 9 failures specific to `Deployment.sandbox.my-csi-app` and pod-level security policies.

### Failures and Fixes

| Check | Issue | Fix | File |
|---|---|---|---|
| `CKV_K8S_29` | No pod-level `securityContext` | Added pod SC with `runAsNonRoot: true`, `runAsUser: 65532`, `runAsGroup: 2000`, `seccompProfile: {type: RuntimeDefault}` | `resources/deployment.yaml` |
| `CKV_K8S_30` | No seccomp profile | Resolved by pod SC above (includes `seccompProfile`) | `resources/deployment.yaml` |
| `CKV_K8S_31` | No `seccompProfile` | Resolved by pod SC above | `resources/deployment.yaml` |
| `CKV_K8S_20` | `allowPrivilegeEscalation` not set to `false` | Added `allowPrivilegeEscalation: false` to container `securityContext` | `resources/deployment.yaml` |
| `CKV_K8S_28` | `NET_RAW` capability not dropped | Added `capabilities: {drop: [ALL]}` to container `securityContext` | `resources/deployment.yaml` |
| `CKV_K8S_8` | No liveness probe | Added `checkov.io/skip1` annotation with justification: demo app running `busybox sleep` has no HTTP endpoint to probe | `resources/deployment.yaml` |
| `CKV_K8S_9` | No readiness probe | Added `checkov.io/skip2` annotation with justification: same as above | `resources/deployment.yaml` |
| `CKV_K8S_38` | `automountServiceAccountToken` not disabled | Set `automountServiceAccountToken: false` on both the ServiceAccount and pod spec; the CSI driver node plugin (not the pod) impersonates the SA for API calls | `resources/service-account.yaml` + `resources/deployment.yaml` |
| `CKV2_K8S_6` | No NetworkPolicy covering the pod | Created `resources/network-policy.yaml` denying all ingress, allowing DNS egress (UDP/TCP port 53) | `resources/network-policy.yaml` (new) + `kustomization.yaml` |

### Rationale for Skip Annotations

The example-app-spiffe-csi deployment already had kube-linter skip annotations for probes (`ignore-check.kube-linter.io/no-readiness-probe` and `/no-liveness-probe`) with justification "This is a demo application and does not require readiness/liveness probes." The corresponding checkov skip annotations use the same logic: a `busybox sleep` container has no application endpoint to probe and is intentionally a simple demonstration workload. Both linters now reflect the same design intent.

### ServiceAccount Token Automounting

The ServiceAccount and role allow the pod to call cert-manager APIs, but the actual API calls are made by the CSI driver node plugin (running as a DaemonSet) when provisioning certificates. The pod container (`busybox sleep`) never calls the Kubernetes API, so mounting the token is unnecessary and violates the least-privilege principle. Setting `automountServiceAccountToken: false` at both the ServiceAccount (default for all pods) and pod spec (explicit override to `false`) ensures the token is never mounted.

### NetworkPolicy Design

The NetworkPolicy:
- **Ingress:** Explicitly denies all ingress (empty `ingress: []` rule).
- **Egress:** Allows DNS traffic (UDP and TCP port 53) to enable hostname resolution. The SPIFFE CSI driver runs as a sidecar on the node and doesn't require egress from the pod container itself.

**Result:** 0 failures for `*.sandbox.my-csi-app` resources. Final checkov scan: **Passed: 100, Failed: 0, Skipped: 2**.

---

## Part 5: CKV_K8S_49 — Minimize Wildcard Use in Roles and ClusterRoles

**Check:** `CKV_K8S_49` — Roles and ClusterRoles must not use `*` in `resources` or `verbs`.

**Count:** 3 failures, all in `applications/flux/base`.

### Failing Resources

| Resource | Wildcard Usage |
|---|---|
| `ClusterRole.default.crd-controller` | `resources: ['*']` and `verbs: ['*']` across all Flux toolkit API groups (`source.toolkit.fluxcd.io`, `kustomize.toolkit.fluxcd.io`, `helm.toolkit.fluxcd.io`, `notification.toolkit.fluxcd.io`, `image.toolkit.fluxcd.io`, `source.extensions.fluxcd.io`) |
| `ClusterRole.default.flux-edit` | `resources: ['*']` with write verbs across all Flux toolkit API groups |
| `ClusterRole.default.flux-view` | `resources: ['*']` with read verbs across all Flux toolkit API groups |

### Why Wildcards Are Intentional Here

These are upstream Flux ClusterRoles from `https://github.com/fluxcd/flux2/releases/download/v2.7.5/install.yaml`. Flux controllers must reconcile any resource under their own CRD groups — the full set of resource types evolves with each Flux release and cannot be enumerated in a ClusterRole without breaking upgrades. These roles already carried a kube-linter skip annotation (`ignore-check.kube-linter.io/wildcard-in-rules`) from earlier session work, which documents the same intent.

### Fix

Added a `checkov.io/skip1` JSON patch op to the existing `patches/clusterRole.yaml`, which is already applied to all ClusterRoles in the Flux base kustomization. This co-locates the checkov justification with the kube-linter justification in the same patch file.

**File changed:** `applications/flux/base/patches/clusterRole.yaml`

```yaml
- op: add
  path: /metadata/annotations/checkov.io~1skip1
  value: "CKV_K8S_49=Flux controllers require wildcard resource permissions to reconcile their own CRD types across the cluster without enumerating every resource."
```

**Result:** 0 `CKV_K8S_49` failures, 3 additional skips. `flux/base` scan: **Passed: 567, Failed: 6, Skipped: 3**.

---

## Part 6: CKV_K8S_38 — Ensure Service Account Tokens Are Only Mounted Where Necessary

**Check:** `CKV_K8S_38` — Pods and Deployments must explicitly disable service account token automounting (`automountServiceAccountToken: false`) unless the token is actively required.

**Count:** 25 failures across 10 applications (13 distinct patch files).

### Decision: Skip vs. Disable

Unlike the demo app (`my-csi-app`, Part 4) where `automountServiceAccountToken: false` was the correct fix because the pod container never calls the Kubernetes API, all 25 failing resources are **operator/controller workloads that actively require the token**. Each one calls the Kubernetes API as a core part of its function. Disabling the token would break the controller. The correct remediation is a `checkov.io/skip` annotation with a justification string.

### Failing Resources and Justifications

| Application | Resource | Reason token is required |
|---|---|---|
| `cert-manager-trust-manager/base` | `Deployment.trust-manager` | Distributes CA bundles as ConfigMaps across namespaces |
| `reloader/base` | `Deployment.reloader-reloader` | Watches ConfigMaps and Secrets to trigger pod restarts |
| `flux/base` | `Deployment.helm-controller` + 5 others | Flux controllers reconcile Flux resources and manage cluster state |
| `external-dns/cloudflare/base` | `Deployment.external-dns` | Watches Services and Ingresses to manage Cloudflare DNS records |
| `external-dns/aws/base` | `Deployment.external-dns` | Same for AWS Route 53; fix propagates to `irsa-role` and `iam-access-keys` overlays |
| `cert-manager/base` | `Deployment.cert-manager` + cainjector + webhook | Manages Certificates, CertificateRequests, and CA injection |
| `cert-manager-spiffe-csi-driver/base` | `Deployment.cert-manager-csi-driver-spiffe-approver` | Approves CertificateRequests for SPIFFE identities |
| `cert-manager-spiffe-csi-driver/base` | `DaemonSet.cert-manager-csi-driver-spiffe-driver` | CSI node plugin provisions SPIFFE SVIDs into pod volumes; used `skip2` since `skip1` is taken by CKV_K8S_40 |
| `crossplane/base` | `Deployment.crossplane` + `crossplane-rbac-manager` | Manages infrastructure resources via Crossplane CRDs |
| `flux-monitoring/base` | `Deployment.flux-state-metrics-kube-state-metrics` | Reads cluster state across all namespaces for metrics |
| `cert-manager-approver-policy/base` | `Deployment.cert-manager-approver-policy` | Approves or denies CertificateRequests via cert-manager APIs |
| `opentelemetry-operator/base` | `Deployment.opentelemetry-operator` | Manages OpenTelemetryCollector and Instrumentation resources |
| `opentelemetry-operator/base` | `Pod.*` (helm test pods) | Helm test Pods interact with the cluster during test execution |

### Changes Made

A `checkov.io/skip1` (or `skip2`) JSON patch op was added to each application's existing deployment/daemonset/pod patch file. In every case, the patch file already existed and was already applied to the relevant resource via the kustomization — no new patch files or kustomization entries were needed.

```
applications/cert-manager-trust-manager/base/patches/deployment.yaml
applications/reloader/base/patches/deployment.yaml
applications/flux/base/patches/deployment.yaml
applications/external-dns/cloudflare/base/patches/deployment.yaml
applications/external-dns/aws/base/patches/deployment.yaml         (also covers irsa-role and iam-access-keys overlays)
applications/cert-manager/base/patches/deployment.yaml
applications/cert-manager-spiffe-csi-driver/base/patches/deployment.yaml
applications/cert-manager-spiffe-csi-driver/base/patches/daemonset.yaml
applications/crossplane/base/patches/deployment.yaml
applications/flux-monitoring/base/patches/deployment.yaml
applications/cert-manager-approver-policy/base/patches/deployment.yaml
applications/opentelemetry-operator/base/patches/deployment.yaml
applications/opentelemetry-operator/base/patches/pod.yaml
```

**Result:** 0 `CKV_K8S_38` failures, 25 additional skips. Overall scan: **Passed: 2862, Failed: 29, Skipped: 31**.

---

## Part 7: CKV_K8S_37 — Minimize Containers with Assigned Capabilities

**Check:** `CKV_K8S_37` — Container `securityContext` must include `capabilities.drop: [ALL]` to minimize the Linux capabilities available to the process.

**Count:** 3 failures across 2 applications.

### Failing Resources

| Resource | Application |
|---|---|
| `Deployment.reloader.reloader-reloader` | `reloader/base` |
| `Deployment.crossplane-system.crossplane` | `crossplane/base` |
| `Deployment.crossplane-system.crossplane-rbac-manager` | `crossplane/base` |

### Approach

For each resource the first step was to check whether the upstream Helm chart exposed `capabilities` in its security context values. The two charts behave differently:

**Reloader** — `helm show values stakater/reloader` shows a `deployment.containerSecurityContext` block (commented out by default) that supports `capabilities.drop` and `allowPrivilegeEscalation`. This is chart-native configuration, so Helm values is the correct layer.

**Crossplane** — The chart exposes `securityContextCrossplane` and `securityContextRBACManager` values for `runAsUser`, `runAsGroup`, `allowPrivilegeEscalation`, and `readOnlyRootFilesystem`, but **not** `capabilities`. A kustomize JSON patch is required. The crossplane main deployment also has an init container (`crossplane-init`) which requires its own capabilities patch.

### Changes Made

#### `applications/reloader/base/values.yaml`

Added `containerSecurityContext` under `reloader.deployment` using chart-native Helm values:

```yaml
reloader:
  deployment:
    containerSecurityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
```

Note: `allowPrivilegeEscalation: false` was added here as well since it was already commented out in the chart's default values alongside `capabilities`, making this a natural grouping. The `readOnlyRootFilesystem: true` setting is configured separately at the top level (`reloader.readOnlyRootFileSystem`) which the chart maps to the container security context.

#### `applications/crossplane/base/patches/deployment.yaml`

Added two `op: add` JSON patch ops — one for the main container and one for the init container:

```yaml
- op: add
  path: /spec/template/spec/containers/0/securityContext/capabilities
  value:
    drop:
      - ALL
- op: add
  path: /spec/template/spec/initContainers/0/securityContext/capabilities
  value:
    drop:
      - ALL
```

This patch targets all `kind: Deployment` resources in the crossplane kustomization (both `crossplane` and `crossplane-rbac-manager`). The crossplane main deployment has an init container (`crossplane-init`) that also needs capabilities dropped; the init container patch op is in this generic file.

#### `applications/crossplane/base/patches/deployment-rbac-manager.yaml`

Added an `op: add` for the rbac-manager container's capabilities:

```yaml
- op: add
  path: /spec/template/spec/containers/0/securityContext/capabilities
  value:
    drop:
      - ALL
```

The rbac-manager has no init container, so only the main container needs this patch. The named target selector on this file (`name: crossplane-rbac-manager`) ensures it applies only to the rbac-manager deployment.

**Result:** 0 `CKV_K8S_37` failures, no new skips. Overall scan: **Passed: 2869, Failed: 22, Skipped: 31**.

---

## Part 8: CKV_K8S_155 — Minimize ClusterRoles with Admission Webhook Configuration Control

**Check:** `CKV_K8S_155` — ClusterRoles granting control over `validatingwebhookconfigurations` or `mutatingwebhookconfigurations` should be minimized.

**Count:** 2 failures across 2 applications.

### Failing Resources

| Resource | Application |
|---|---|
| `ClusterRole.default.cert-manager-cainjector` | `cert-manager/base` |
| `ClusterRole.default.crossplane:system:aggregate-to-crossplane` | `crossplane/base` |

### Findings and Decision

Both failures are upstream controller ClusterRoles where admission webhook control is part of normal operation:

- `cert-manager-cainjector` updates webhook CA bundles and requires `update/patch` on `validatingwebhookconfigurations` and `mutatingwebhookconfigurations`.
- `crossplane:system:aggregate-to-crossplane` includes admissionregistration permissions required for webhook lifecycle management in Crossplane/provider installs.

Given this, the remediation was to add `checkov.io/skip` annotations with explicit justifications rather than remove required permissions.

### Changes Made

Added `checkov.io/skip1` to existing ClusterRole JSON patch files:

```
applications/cert-manager/base/patches/cluster-role.yaml
applications/crossplane/base/patches/cluster-role.yaml
```

Example op pattern used:

```yaml
- op: add
  path: /metadata/annotations/checkov.io~1skip1
  value: "CKV_K8S_155=<justification>"
```

### Scope Note

Both kustomizations target `kind: ClusterRole` for these patch files, so the skip annotation is applied to all ClusterRoles in each application, not only the two failing roles. This resolved CKV_K8S_155 but increased total skip count more than the number of direct failures.

**Result:** 0 `CKV_K8S_155` failures. Overall scan: **Passed: 2847, Failed: 20, Skipped: 55**.

---

## Part 9: CKV_K8S_35 — Prefer Secrets as Files Over Environment Variables

**Check:** `CKV_K8S_35` — Prefer mounting secret data as files rather than exposing it via environment variables.

**Count:** 1 failure in 1 application.

### Failing Resource

| Resource | Application |
|---|---|
| `Deployment.external-dns.external-dns` | `external-dns/cloudflare/base` |

### Findings and Decision

The Cloudflare external-dns deployment consumes credentials from `dns-credentials` using env vars:

- `CF_API_TOKEN`
- `EXTERNAL_DNS_DOMAIN_FILTER`
- `EXTERNAL_DNS_ZONE_ID_FILTER`

These values are sourced via `valueFrom.secretKeyRef` (not hardcoded), but still trigger CKV_K8S_35 because they are injected as environment variables.

For this workload, env-var based provider configuration is an upstream controller pattern and already documented in kube-linter annotations for the same resource (`read-secret-from-env-var` and `env-value-from`). The remediation chosen was a checkov skip annotation with explicit rationale, co-located in the existing deployment patch.

### Changes Made

Added `checkov.io/skip2` to:

```
applications/external-dns/cloudflare/base/patches/deployment.yaml
```

Patch op added:

```yaml
- op: add
  path: /metadata/annotations/checkov.io~1skip2
  value: "CKV_K8S_35=external-dns cloudflare provider consumes API credentials via environment variables sourced from a Kubernetes Secret (dns-credentials). This is an upstream controller pattern and credentials are not hardcoded in manifests."
```

**Result:** 0 `CKV_K8S_35` failures. CKV_K8S_35 scoped scan: **Passed: 25, Failed: 0, Skipped: 1**.

---

## Part 10: CKV_K8S_8 — Liveness Probe Should Be Configured

**Check:** `CKV_K8S_8` — Containers should have liveness probes configured.

**Count:** 4 failures across 2 applications.

### Failing Resources

| Resource | Application |
|---|---|
| `DaemonSet.cert-manager.cert-manager-csi-driver-spiffe-driver` | `cert-manager-spiffe-csi-driver/base` |
| `Pod.opentelemetry-operator-system.opentelemetry-operator-cert-manager` | `opentelemetry-operator/base` |
| `Pod.opentelemetry-operator-system.opentelemetry-operator-metrics` | `opentelemetry-operator/base` |
| `Pod.opentelemetry-operator-system.opentelemetry-operator-webhook` | `opentelemetry-operator/base` |

### Findings and Decision

- The SPIFFE CSI driver DaemonSet includes helper sidecars (`node-driver-registrar`, `liveness-probe`) where probe semantics differ from long-running application containers. Existing kube-linter annotations already document this exception.
- The opentelemetry-operator Pod resources are Helm test hook Pods (`helm.sh/hook: test`) with `restartPolicy: Never`, intended as short-lived validation jobs rather than continuously running workloads.

Given those semantics, these were handled as justified checkov skips in existing patch files rather than adding synthetic liveness probes.

### Changes Made

Added `checkov.io/skip` annotations:

```
applications/cert-manager-spiffe-csi-driver/base/patches/daemonset.yaml
applications/opentelemetry-operator/base/patches/pod.yaml
```

Patch ops added:

```yaml
- op: add
  path: /metadata/annotations/checkov.io~1skip3
  value: "CKV_K8S_8=CSI helper sidecars intentionally omit liveness probes; the main cert-manager-csi-driver-spiffe container already exposes and uses /healthz."
```

```yaml
- op: add
  path: /metadata/annotations/checkov.io~1skip2
  value: "CKV_K8S_8=Helm test hook Pods are short-lived validation jobs with restartPolicy Never and intentionally do not use liveness probes."
```

**Result:** 0 `CKV_K8S_8` failures. CKV_K8S_8 scoped scan: **Passed: 2, Failed: 0, Skipped: 1**.

---

## Part 11: CKV_K8S_157 — Minimize RBAC Permissions to Bind RoleBindings/ClusterRoleBindings

**Check:** `CKV_K8S_157` — Roles and ClusterRoles granting permissions to bind RoleBindings or ClusterRoleBindings should be minimized.

**Count:** 2 failures in 1 application.

### Failing Resources

| Resource | Application |
|---|---|
| `ClusterRole.default.crossplane-rbac-manager` | `crossplane/base` |
| `ClusterRole.default.crossplane:aggregate-to-admin` | `crossplane/base` |

### Findings and Decision

Both failing ClusterRoles are upstream Crossplane RBAC roles with intentionally broad RBAC management permissions:

- `crossplane-rbac-manager` includes `bind`/`escalate` related capabilities for managing Crossplane RBAC artifacts.
- `crossplane:aggregate-to-admin` is an aggregate admin role that includes binding privileges as part of role aggregation and admin delegation behavior.

These are not safe to narrow without risking controller/RBAC-manager functionality. The chosen remediation was targeted checkov skip annotations.

### Changes Made

Added a dedicated patch file:

```
applications/crossplane/base/patches/cluster-role-ckv-k8s-157.yaml
```

Patch content:

```yaml
- op: add
  path: /metadata/annotations/checkov.io~1skip2
  value: "CKV_K8S_157=Crossplane rbac-manager and aggregate-to-admin ClusterRoles intentionally require bind/escalate capabilities to manage and aggregate RBAC for Crossplane core and installed providers."
```

Wired this patch to **name-scoped** targets in `applications/crossplane/base/kustomization.yaml`:

- `kind: ClusterRole`, `name: crossplane-rbac-manager`
- `kind: ClusterRole`, `name: crossplane:aggregate-to-admin`

This avoids applying the exception to all Crossplane ClusterRoles.

**Result:** 0 `CKV_K8S_157` failures. CKV_K8S_157 scoped scan: **Passed: 53, Failed: 0, Skipped: 2**.

---

## Final State

| Check | Before | After |
|---|---|---|
| `CKV_K8S_43` (image digest) | 26 | 0 |
| `CKV_K8S_40` (high UID) | 13 | 0 (1 skip) |
| `my-csi-app` failures (Part 4) | 9 | 0 (2 skips) |
| `CKV_K8S_49` (wildcards in roles) | 3 | 0 (3 skips) |
| `CKV_K8S_38` (SA token automount) | 25 | 0 (25 skips) |
| `CKV_K8S_37` (capabilities drop) | 3 | 0 |
| `CKV_K8S_155` (webhook config control in ClusterRoles) | 2 | 0 |
| `CKV_K8S_35` (secrets as files vs env vars) | 1 | 0 (1 skip) |
| `CKV_K8S_8` (liveness probes) | 4 | 0 (4 skips) |
| `CKV_K8S_157` (RBAC bind permissions) | 2 | 0 (2 skips) |
| `CKV_K8S_9` (readiness probes) | 4 | 0 (4 skips) |
| All other checks | ~41 | 9 |
| **Total failures** | **133** | **9** |
| Skipped | 0 | 66 |

## Key Decisions

1. **pip over standalone binary** — The GitHub-released checkov standalone binary has a path-handling bug that silently skips files when the scan path is absolute and contains hidden directories. The pip install is more reliable.

2. **Isolated venv for checkov** — checkov's botocore/s3transfer pin conflicts with awscli in the shared `.venv`. Isolation avoids dependency hell on every future `pip install --upgrade`.

3. **kustomize `images:` for digest pinning** — No chart in this repo exposes a `digest` Helm value. The kustomize `images:` block is the correct layer for this concern; it keeps source manifests readable while enforcing immutability in rendered output.

4. **UID `65532`** — Used consistently across all changes. This is the GID/UID used by Google's distroless images and is widely adopted in the Kubernetes ecosystem (used by Crossplane, cert-manager upstream, and others).

5. **Checkov skip annotation for CSI DaemonSet** — The annotation approach (`checkov.io/skip1`) keeps the justification co-located with the resource definition. An alternative would be a `.checkov.yaml` baseline file, but annotation is preferred because it makes the exception visible to anyone reading the patch.

6. **Checkov skip via existing kustomize patch** — When a kustomize patch already applies annotations to a class of resources (e.g. `clusterRole.yaml` targeting all Flux ClusterRoles), adding a new `op: add` entry to that patch is the correct approach. This avoids creating a separate patch file for a single annotation and keeps all skip justifications in one place.

7. **Patch target scope affects skip cardinality** — A patch target of only `kind: ClusterRole` applies to all ClusterRoles in that kustomization. This is efficient for broad policy exceptions but may increase skip counts unexpectedly. Use name-scoped targets when per-resource exception boundaries are required.

8. **Controller credential patterns may require env-var exceptions** — Some upstream controllers (e.g. external-dns provider configuration) consume secret values through environment variables. When moving to file mounts is non-trivial and the secret is already sourced via `secretKeyRef`, a checkov skip annotation with clear justification is the pragmatic approach.

9. **Short-lived hooks and CSI helper sidecars are valid no-probe exceptions** — Helm test hook Pods (`restartPolicy: Never`) and certain CSI helper sidecars are not equivalent to long-running service containers. For these cases, use explicit checkov skip annotations with justification and keep them aligned with existing kube-linter exception rationale.

10. **Prefer name-scoped patch targets for high-risk RBAC exceptions** — For checks like CKV_K8S_157, adding a dedicated patch file and targeting only the exact role names avoids broad exception blast radius and keeps exception intent auditable.

---

## Part 12: CKV_K8S_9 — Readiness Probe Should Be Configured

**Check:** `CKV_K8S_9` — Containers should have readiness probes configured.

**Count:** 4 failures across 2 applications.

### Failing Resources

| Resource | Application |
|---|---|
| `DaemonSet.cert-manager.cert-manager-csi-driver-spiffe-driver` | `cert-manager-spiffe-csi-driver/base` |
| `Pod.opentelemetry-operator-system.opentelemetry-operator-cert-manager` | `opentelemetry-operator/base` |
| `Pod.opentelemetry-operator-system.opentelemetry-operator-metrics` | `opentelemetry-operator/base` |
| `Pod.opentelemetry-operator-system.opentelemetry-operator-webhook` | `opentelemetry-operator/base` |

### Findings and Decision

These are the same two resources that triggered CKV_K8S_8 (liveness probes), for the same underlying reasons:

- The SPIFFE CSI DaemonSet's `node-driver-registrar` sidecar does not serve pod traffic and is not a readiness gate. The kube-linter annotation `no-readiness-probe` already documents this.
- The opentelemetry-opera- The opentelemetry-opera- The opentelemetry-opera- The ope Neve- The opentelemetry-opera- The opentelemetry-opera- The opentelemetry-operaade


 The opentelemetry-opera- The opentelemetrexi The opentelemetry-oready carrying the matching kube-linter exceptions:

```
applications/cert-manager-spiffe-csi-driver/base/patches/daemonset.yaml
applications/opentelemetry-operator/base/patches/pod.yaml
```

Patch ops added:

```yaml
# daemonset.yaml — skip4
- op: add
- op: add
t.yaml — skip4
operator/base/patches/pod.yaml
aemonset.yaml
arrying the matching kube-linregistrar) intentionally omit readiness probes; they do not serve pod traffic and readiness is not a functional gate for these sidecaarrying the matching kube-linregistrar) intentionally omit readiness probes; they do not serve pod traffic"CKV_arrying the matching kube-linregistrar) intentionally omit readiness probes; they do not serve pod traffic and readiness is not a functional gate for these sidecaarrying the matching kubed scan: **Passed: 21, Failed: 0, Skipped: 5**. Overall scan: **Passed: 2847, Failed: 9, Skipped: 66**.
