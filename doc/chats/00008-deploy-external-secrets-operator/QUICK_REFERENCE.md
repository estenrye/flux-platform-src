# Quick Reference: External Secrets Operator Deployment

## Key Metrics

| Metric | Status |
|--------|--------|
| Checkov Security Checks | ✅ 319/319 passed |
| kube-linter Critical Checks | ✅ All passing |
| Replicas | 3 (HA) |
| Image Digest | sha256:9440a40b394791a5e93f3f7e1b33399ecbdc0e38273de1d69ed83fe12936fc09 |
| Container UID | 65532 (distroless standard) |
| Pod Security Context | fsGroup: 2000, runAsNonRoot: true |
| Resource Limits | CPU: 200m, Memory: 256Mi |

## Configuration Locations

| Component | Location | Purpose |
|-----------|----------|---------|
| Helm Values | `base/values.yaml` | PRIMARY: All hardening config |
| Deployment Patches | `base/patches/deployment.yaml` | Restart policy + CKV_K8S_38 skip |
| RBAC Patches | `base/patches/cluster-*.yaml` | Webhook/secret access exceptions |
| Network Policy | `base/resources/network-policy.yaml` | Ingress/egress rules |
| Build Orchestration | `base/kustomization.yaml` | Image digest + patch/resource inclusion |

## What Was Changed From Defaults

### values.yaml Modifications

```yaml
# Probes
livenessProbe.enabled: true                    # ← Was: false
readinessProbe.enabled: true                   # ← Was: false

# HA & Updates
replicaCount: 3                                # ← Was: 1
image.pullPolicy: Always                       # ← Was: IfNotPresent
strategy.type: RollingUpdate                   # ← Was: not set

# Security
securityContext.runAsUser: 65532               # ← Was: 1000
podSecurityContext.enabled: true               # ← Was: commented

# Resources
resources.requests.cpu: 50m                    # ← Was: empty
resources.requests.memory: 64Mi                # ← Was: empty
resources.limits.cpu: 200m                     # ← Was: empty
resources.limits.memory: 256Mi                 # ← Was: empty

# Availability
affinity.podAntiAffinity.*                     # ← Was: empty
```

### Files Added (New)

```
base/patches/deployment.yaml
base/patches/cluster-role.yaml
base/patches/cluster-role-binding.yaml
base/resources/network-policy.yaml
```

## Validation Commands (One-Liners)

```bash
# Full validation
make render && \
  .venv/bin/checkov -d .render/flux-platform-rendered/applications/external-secrets-operator \
    --framework kubernetes --quiet --compact --skip-results-upload && \
  find .render/flux-platform-rendered/applications/external-secrets-operator \
    -type f \( -name "*.yaml" -o -name "*.yml" \) | \
    xargs .venv/bin/kube-linter lint --config .kube-linter/config.yaml

# Just Checkov
make render && .venv/bin/checkov -d .render/flux-platform-rendered/applications/external-secrets-operator \
  --framework kubernetes --quiet --compact --skip-results-upload

# Just kube-linter  
make render && find .render/flux-platform-rendered/applications/external-secrets-operator \
  -type f \( -name "*.yaml" -o -name "*.yml" \) | \
  xargs .venv/bin/kube-linter lint --config .kube-linter/config.yaml
```

## Policy Exceptions Explained

| Check | Reason | Annotation |
|-------|--------|-----------|
| CKV_K8S_38 | Must access Kubernetes secrets | `checkov.io/skip1` on Deployment |
| CKV_K8S_155 | Must manage webhook configurations | `checkov.io/skip2` on cert-controller ClusterRole |
| access-to-secrets | Functional requirement | `ignore-check.kube-linter.io/access-to-secrets` on ClusterRoleBinding |

**Policy**: Only use exceptions for unavoidable functional requirements, documented with rationale.

## Common Updates

### Change replica count
```yaml
# values.yaml
replicaCount: 3  # Change this number
```

### Adjust resource limits
```yaml
# values.yaml
resources:
  requests:
    cpu: 100m        # Increase request
    memory: 128Mi
  limits:
    cpu: 500m        # Increase limit
    memory: 512Mi
```

### Add node affinity (optional)
```yaml
# values.yaml - add to main affinity block
affinity:
  podAntiAffinity: ...
  nodeAffinity:      # Add this
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: node-role.kubernetes.io/worker
          operator: In
          values:
          - "true"
```

### Update image digest
```bash
# Find new digest for new version
docker buildx imagetools inspect ghcr.io/external-secrets/external-secrets:v2.5.0 | grep "Digest:"

# Update in kustomization.yaml
images:
  - name: ghcr.io/external-secrets/external-secrets
    digest: sha256:NEW_DIGEST_HERE
```

## Architecture Principles

1. **Values-first**: Use Helm chart values before resorting to patches
2. **Minimal patches**: Only patch unavoidable hardcoded template values
3. **Document exceptions**: Every policy skip needs explicit justification
4. **Immutable deployments**: Pin image digests, not tags
5. **HA by default**: Configure replicas + anti-affinity at deployment time

## Debugging Checklist

- [ ] Did `make render` succeed? Check `.render/` for manifest output
- [ ] Do Checkov checks pass? Run with full output (remove `--quiet`) to see details
- [ ] Does kube-linter pass? May show advisory warnings (acceptable)
- [ ] Do pod labels match affinity selectors? Inspect rendered YAML `spec.template.metadata.labels`
- [ ] Are probes configured? Check `livenessProbe` and `readinessProbe` in rendered manifests
- [ ] Is image digest set? Verify no `:` tag in container image references
- [ ] Are resources limited? Check `resources.requests` and `resources.limits`

## Links

- **Main Doc**: [README.md](./README.md)
- **Validation Commands**: [VALIDATION.md](./VALIDATION.md)
- **Helm Values Pattern**: [../../kubernetes-helm-patterns.md](../../kubernetes-helm-patterns.md)
- **External Secrets**: https://external-secrets.io/
