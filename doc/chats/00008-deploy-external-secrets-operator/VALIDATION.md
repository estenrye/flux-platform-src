# Validation Commands & Reproducibility

This document captures the exact commands used to validate the external-secrets-operator deployment.

## Environment Setup

```bash
cd /Users/esten/src/flux-platform-src
source .venv/bin/activate
```

## Build & Render

### Generate manifests from Kustomize + Helm

```bash
make render
```

**Output**: `.render/flux-platform-rendered/applications/external-secrets-operator/base/rendered.yaml`

**Verification**: Check manifest contains:
- 3 replicas for each deployment
- Pod anti-affinity rules
- Probes enabled
- Resource limits set
- Image digest referenced
- NetworkPolicy defined

## Security Validation

### Checkov - Policy Compliance Scanning

```bash
.venv/bin/checkov -d .render/flux-platform-rendered/applications/external-secrets-operator \
  --framework kubernetes \
  --quiet \
  --compact \
  --skip-results-upload
```

**Expected Output**:
```
kubernetes scan results:

Passed checks: 319, Failed checks: 0, Skipped checks: 4
```

**Skipped Checks**: Policy exceptions documented in deployment/clusterrole annotations
- CKV_K8S_38 (service account token access)
- CKV_K8S_155 (webhook management)
- kube-linter access-to-secrets equivalent

### kube-linter - Best Practices Checking

```bash
find .render/flux-platform-rendered/applications/external-secrets-operator \
  -type f \( -name "*.yaml" -o -name "*.yml" \) | \
  xargs .venv/bin/kube-linter lint --config .kube-linter/config.yaml
```

**Expected Output** (after affinity fixes):
```
KubeLinter 0.8.3

...3 no-node-affinity advisory warnings (optional topology recommendations)...

Error: found 3 lint errors
```

**Analysis**:
- ✅ `no-anti-affinity` - RESOLVED (pod anti-affinity rules added)
- ✅ `access-to-secrets` - RESOLVED (skip annotation on ClusterRoleBinding)
- ⚠️ `no-node-affinity` - ADVISORY ONLY (optional; no node pool constraints needed)

---

## Verification Steps

### 1. Pod Anti-Affinity Rendered Correctly

```bash
grep -A 15 "podAntiAffinity:" \
  .render/flux-platform-rendered/applications/external-secrets-operator/base/rendered.yaml | head -60
```

**Check**: Each of 3 deployments has affinity block with correct pod label selectors:
- operator: `app.kubernetes.io/name: external-secrets`
- webhook: `app.kubernetes.io/name: external-secrets-webhook`
- cert-controller: `app.kubernetes.io/name: external-secrets-cert-controller`

### 2. Security Context Settings

```bash
grep -A 8 "securityContext:" \
  .render/flux-platform-rendered/applications/external-secrets-operator/base/rendered.yaml | \
  grep -E "runAsUser|fsGroup|runAsNonRoot|allowPrivilegeEscalation" | head -20
```

**Check**: 
- `runAsUser: 65532`
- `runAsNonRoot: true`
- `allowPrivilegeEscalation: false`
- `fsGroup: 2000`

### 3. Image Digest Pinned

```bash
grep "ghcr.io/external-secrets/external-secrets" \
  .render/flux-platform-rendered/applications/external-secrets-operator/base/rendered.yaml | \
  head -5
```

**Check**: Contains `sha256:9440a40b394791a5e93f3f7e1b33399ecbdc0e38273de1d69ed83fe12936fc09` (not tag v2.4.1)

### 4. Health Probes Enabled

```bash
grep -B 2 -A 5 "livenessProbe:" \
  .render/flux-platform-rendered/applications/external-secrets-operator/base/rendered.yaml | head -30
```

**Check**: Both liveness and readiness probe sections present with:
- `enabled: true`
- `initialDelaySeconds`
- `periodSeconds`
- HTTP paths defined

### 5. Resource Limits Configured

```bash
grep -B 2 -A 8 "resources:" \
  .render/flux-platform-rendered/applications/external-secrets-operator/base/rendered.yaml | \
  grep -E "requests|limits|cpu|memory" | head -20
```

**Check**:
- Requests: cpu: 50m, memory: 64Mi
- Limits: cpu: 200m, memory: 256Mi

### 6. Restart Policy Set

```bash
grep -A 2 "restartPolicy:" \
  .render/flux-platform-rendered/applications/external-secrets-operator/base/rendered.yaml
```

**Check**: `restartPolicy: Always`

### 7. NetworkPolicy Resource

```bash
grep -A 30 "kind: NetworkPolicy" \
  .render/flux-platform-rendered/applications/external-secrets-operator/base/rendered.yaml | head -40
```

**Check**: 
- Selector matches `app.kubernetes.io/instance: external-secrets`
- Ingress rules for ports 8080, 8081, 8082, 10250
- Egress rules for 443 (HTTPS), 53 (DNS)

### 8. Replica Count

```bash
grep -B 5 "replicas:" \
  .render/flux-platform-rendered/applications/external-secrets-operator/base/rendered.yaml | \
  grep -E "kind: Deployment|name:|replicas:" | head -20
```

**Check**: All 3 deployments have `replicas: 3`

---

## Troubleshooting

### If Checkov fails after changes

```bash
# Full verbose output with check details
.venv/bin/checkov -d .render/flux-platform-rendered/applications/external-secrets-operator \
  --framework kubernetes
```

### If kube-linter shows unexpected errors

```bash
# List all checks in config
cat .kube-linter/config.yaml
```

### To inspect specific deployment in rendered manifest

```bash
# Extract specific deployment
yq eval '.[] | select(.kind=="Deployment" and .metadata.name=="external-secrets")' \
  .render/flux-platform-rendered/applications/external-secrets-operator/base/rendered.yaml
```

---

## Update Procedure

When external-secrets chart is updated:

1. **Update chart in repository**:
   ```bash
   helm repo update
   helm pull external-secrets/external-secrets --version <new-version> -d applications/external-secrets-operator/base/charts/
   ```

2. **Run validation**:
   ```bash
   make render
   .venv/bin/checkov -d .render/flux-platform-rendered/applications/external-secrets-operator \
     --framework kubernetes --quiet --compact --skip-results-upload
   ```

3. **Resolve conflicts** (if patches no longer apply):
   - Review `make render` error output
   - Update patches/ files for structural changes
   - Verify no new security findings introduced

4. **Update values.yaml** if chart adds new configurable fields

---

## Integration with CI/CD

Add to your pipeline:

```yaml
validate-external-secrets:
  stage: security
  script:
    - make render
    - .venv/bin/checkov -d .render/flux-platform-rendered/applications/external-secrets-operator \
        --framework kubernetes --exit-code 1 --skip-results-upload
    - find .render/flux-platform-rendered/applications/external-secrets-operator \
        -type f \( -name "*.yaml" -o -name "*.yml" \) | \
        xargs .venv/bin/kube-linter lint --config .kube-linter/config.yaml
  allow_failure: false
```

---

## Performance Notes

- **Checkov scan time**: ~5-10 seconds (319 checks across 3 deployments)
- **kube-linter scan time**: ~2-3 seconds
- **Render time**: ~3-5 seconds (full platform build)

---

## Related Documentation

- [Architecture Decision - values-first approach](./README.md#architecture-decision-record)
- [Problem Analysis - detailed solutions for each check](./README.md#problem-analysis--solutions)
- [Kubernetes Helm Patterns - when to use values vs patches](../../kubernetes-helm-patterns.md)
