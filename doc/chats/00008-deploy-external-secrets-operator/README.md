# Deploy External Secrets Operator with Security Hardening

**Date**: May 13–14, 2026  
**Objective**: Deploy external-secrets v2.4.1 via Helm through Kustomize with complete security policy compliance (Checkov + kube-linter)  
**Status**: ✅ Complete - All security checks passing, pods stable in cluster

## Executive Summary

Deployed and hardened the external-secrets-operator Helm chart (v2.4.1) in a Kustomize-managed GitOps environment. Achieved clean security posture with all 319 Checkov policy checks passing and all kube-linter security best-practice checks passing. The implementation demonstrates applying upstream Helm chart configurations through values-first approach before resorting to patches, ensuring maintainability and minimizing upgrade friction.

## Architecture Decision Record

### Key Constraint: Values-First Configuration

The primary architectural decision was to prioritize Helm chart configuration values (`values.yaml`) over custom patches, following the principle documented in [kubernetes-helm-patterns.md](../../doc/kubernetes-helm-patterns.md):

1. **Always use Helm values first**: Chart authors expose safe configuration surfaces; patches should be exceptions
2. **Patch only unavoidable conflicts**: Policy violations that cannot be resolved through values require annotation-based exceptions
3. **Reduce upgrade friction**: Values-based config survives chart version updates better than patches

### Rationale

External Secrets is a complex controller managing multiple deployments (operator, webhook, cert-controller) with distinct responsibilities. The upstream chart exposes configuration for most hardening requirements via values, making patches necessary only for:
- Restart policies (hardcoded in chart templates)
- Checkov/kube-linter policy exceptions (unavoidable functional requirements)
- Image digest pinning (Kustomize image field, not chart values)

## Problem Analysis & Solutions

### 1. Health Probe Enablement (CKV_K8S_8, CKV_K8S_9)

**Problem**: Liveness and readiness probes disabled by default in external-secrets chart  
**Impact**: Container failures not detected; pods don't restart; no graceful recovery

**Solution**: Enabled probes via values.yaml
```yaml
livenessProbe:
  enabled: true
readinessProbe:
  enabled: true
```

**Applied to**: All three deployments (operator, webhook, cert-controller)

---

### 2. Resource Limits Configuration (CKV_K8S_10, CKV_K8S_11, CKV_K8S_12, CKV_K8S_13)

**Problem**: No CPU/memory requests or limits defined; pods could consume unbounded resources  
**Impact**: Pod evictions under load; cluster resource exhaustion

**Solution**: Set requests and limits in values.yaml for all deployments
```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi
```

**Rationale**: External Secrets controllers are lightweight (certificate rotation, secret reconciliation). These values provide room for spikes while preventing runaway consumption.

---

### 3. Image Pull Policy (CKV_K8S_15)

**Problem**: Default `IfNotPresent` allows stale image caching; tag reuse could deploy outdated code  
**Impact**: Security fixes not deployed; rogue actor could re-tag older versions

**Solution**: Set image pull policy to Always across all deployments
```yaml
image:
  pullPolicy: Always
```

---

### 4. Container UID Hardening (CKV_K8S_40)

**Problem**: Default `runAsUser: 1000` fails Checkov check requiring UID ≥ 10000  
**Impact**: Policy violation; possible conflict with host UIDs in some environments

**Solution**: Changed to `runAsUser: 65532` (standard distroless UID)
```yaml
securityContext:
  runAsUser: 65532
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

**Rationale**: 
- 65532 is the standard UID used by distroless images (upstream image: ghcr.io/external-secrets/external-secrets:v2.4.1)
- Non-conflicting with typical host UIDs (host UIDs usually ≥ 1000, service UIDs 100-999)
- Properly non-root without requiring excessive UID allocation

---

### 5. Image Digest Pinning (CKV_K8S_43)

**Problem**: Tag-based image references (`v2.4.1`) vulnerable to tag reuse/mutation  
**Impact**: Same tag could point to different images after push; reproducibility compromised

**Solution**: Resolved tag to immutable digest via Kustomize
```yaml
images:
  - name: ghcr.io/external-secrets/external-secrets
    digest: sha256:9440a40b394791a5e93f3f7e1b33399ecbdc0e38273de1d69ed83fe12936fc09
```

**Process**: 
1. Inspected multi-arch manifest: `docker buildx imagetools inspect ghcr.io/external-secrets/external-secrets:v2.4.1`
2. Extracted index digest (covers all architectures)
3. Applied via Kustomize `images` field (replaces tags with digest)

---

### 6. Pod Security Context Enablement (CKV_K8S_29)

**Problem**: `podSecurityContext.fsGroup` commented out; pods run without group permission enforcement  
**Impact**: File permissions not properly constrained; security context bypassed

**Solution**: Uncommented and enabled fsGroup in values.yaml
```yaml
podSecurityContext:
  enabled: true
  fsGroup: 2000

securityContext:
  runAsUser: 65532
```

**Rendered as**: Both pod-level and container-level context enforcement in deployment specs

---

### 7. Restart Policy (kube-linter restart-policy)

**Problem**: Deployments use default restart policy (None); failed pods don't restart  
**Impact**: Single pod failure causes partial outages; requires manual intervention

**Solution**: Added JSON6902 patch to all Deployments
```yaml
- op: add
  path: /spec/template/spec/restartPolicy
  value: Always
```

**Why Patch**: Restart policies are typically hardcoded in Helm templates and not exposed via values in most charts

---

### 8. Service Account Token Access (CKV_K8S_38, kube-linter access-to-secrets)

**Problem**: Unavoidable - External Secrets must read/write Kubernetes secrets and manage webhook certificates  
**Impact**: Cannot be resolved through configuration alone; requires policy exception

**Solution**: Added policy exception annotations
```yaml
# In patches/deployment.yaml
- op: add
  path: /metadata/annotations/checkov.io~1skip1
  value: "CKV_K8S_38=External Secrets controllers require the service account token to access Kubernetes secrets and manage webhook certificates."

# In patches/cluster-role-binding.yaml
- op: add
  path: /metadata/annotations/ignore-check.kube-linter.io~1access-to-secrets
  value: "External Secrets requires secret read and write access to reconcile ExternalSecret resources."
```

**Justification**: 
- Core functional requirement (cannot operate without secret access)
- Follows existing repo pattern (cert-manager uses identical exception)
- Annotations document the reason for exception
- Allows security audit trails to identify intentional vs accidental exemptions

---

### 9. Webhook RBAC Permissions (CKV_K8S_155)

**Problem**: Cert-controller ClusterRole includes `admissionregistration` permissions (unavoidable)  
**Impact**: Creates policy exception; must be explicitly acknowledged

**Solution**: Targeted patch on cert-controller ClusterRole
```yaml
# patches/cluster-role.yaml (targets external-secrets-cert-controller)
- op: add
  path: /metadata/annotations/checkov.io~1skip1
  value: "CKV_K8S_155=External Secrets manages validating webhook configurations for its certificate controller."
```

**Specificity**: Patch targets only cert-controller, not other ClusterRoles

---

### 10. Pod Anti-Affinity for HA (kube-linter no-anti-affinity)

**Problem**: Three replicas deployed without pod anti-affinity; all could land on single node  
**Impact**: No high-availability; single node failure causes complete outage

**Solution**: Added pod anti-affinity rules to values.yaml for all deployments
```yaml
# Main operator
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app.kubernetes.io/name
                operator: In
                values:
                  - external-secrets
          topologyKey: kubernetes.io/hostname

# Webhook (matches app.kubernetes.io/name=external-secrets-webhook)
# Cert-controller (matches app.kubernetes.io/name=external-secrets-cert-controller)
```

**Key Implementation Detail**: Label selectors must match actual pod labels from chart templates:
- Operator: `app.kubernetes.io/name=external-secrets`
- Webhook: `app.kubernetes.io/name=external-secrets-webhook`
- Cert-controller: `app.kubernetes.io/name=external-secrets-cert-controller`

Using `preferredDuringSchedulingIgnoredDuringExecution` allows graceful degradation if insufficient nodes available.

---

### 11. Liveness Probe Fix: Webhook & Cert-Controller (Post-Deployment)

**Date**: May 14, 2026  
**Problem**: After deploying to cluster, webhook and cert-controller pods entered restart loops with ~5 restarts each  
**Symptom**: `Liveness probe failed: HTTP probe failed with statuscode: 404`

**Investigation**:
1. Initial hypothesis: cert-manager approver-policy blocking CertificateRequests — **rejected**: all CertificateRequests showed `APPROVED=True, READY=True`
2. Checked events: `Warning Unhealthy ... Liveness probe failed: HTTP probe failed with statuscode: 404`
3. Root cause: The chart enables liveness probes with an HTTP path (`/healthz`) for webhook and cert-controller, but those containers bind their health server on `:8081` and **do not** serve that HTTP path at the expected route at runtime

**Fix Attempts**:
- Attempt 1: Changed liveness probe path from `/healthz` to `/livez` via JSON6902 patch → still 404
- Attempt 2: Switched to TCP socket probe on port 8081 → ✅ stable

**Solution**: Added TCP socket liveness probes for webhook and cert-controller via new patches
```yaml
# patches/deployment-webhook-liveness.yaml
# patches/deployment-cert-controller-liveness.yaml
- op: replace
  path: /spec/template/spec/containers/0/livenessProbe
  value:
    tcpSocket:
      port: 8081
    initialDelaySeconds: 10
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 5
    successThreshold: 1
```

**Probe Architecture by Deployment**:
| Deployment | Liveness Probe Type | Port | Notes |
|-----------|-------------------|------|-------|
| operator | HTTP GET `/healthz` | 8082 | Works — chart configures via `livenessProbe.spec` |
| webhook | TCP socket | 8081 | HTTP path returns 404; TCP confirms port is open |
| cert-controller | TCP socket | 8081 | HTTP path returns 404; TCP confirms port is open |

**Why Patch vs Values**: The chart's `webhook.livenessProbe` and `certController.livenessProbe` values control probe enablement and timing but hard-code the HTTP path in the template. Switching to TCP socket requires replacing the full probe spec via JSON6902 patch.

**Validation**: All 9 pods (3 per deployment) reached Running/Ready with 0 restarts on new ReplicaSets after fix applied.

---

### 12. Network Policy Isolation

**Problem**: Pods lack network segmentation; traffic unrestricted  
**Impact**: Potential lateral movement; no ingress/egress control

**Solution**: Created NetworkPolicy resource
```yaml
# resources/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: external-secrets-operator
  namespace: external-secrets-operator
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/instance: external-secrets
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - ports:
        - protocol: TCP
          port: 8080  # operator metrics
        - protocol: TCP
          port: 8081  # cert-controller metrics
        - protocol: TCP
          port: 8082  # webhook metrics
        - protocol: TCP
          port: 10250 # webhook service
  egress:
    - ports:
        - protocol: TCP
          port: 443   # HTTPS for external APIs
        - protocol: TCP
          port: 53    # DNS TCP
        - protocol: UDP
          port: 53    # DNS UDP
```

---

### 13. High Availability Configuration

**Decision**: Set `replicaCount: 3` for all deployments

**Rationale**:
- Three replicas provide 2-of-3 quorum (tolerates single pod failure)
- Enables pod anti-affinity to spread across nodes
- Supports graceful drains during node maintenance
- External Secrets controllers are stateless (no coordination needed)

---

## File Structure

```
applications/external-secrets-operator/base/
├── catalog.yaml              # Kustomize metadata
├── kustomization.yaml        # Build orchestration
├── values.yaml               # Helm chart configuration (PRIMARY)
├── charts/
│   └── external-secrets-2.4.1/  # Upstream chart
└── patches/
    ├── deployment.yaml                      # Restart policy + CKV_K8S_38 skip
    ├── cluster-role.yaml                    # CKV_K8S_155 skip (cert-controller)
    ├── cluster-role-binding.yaml            # kube-linter access-to-secrets skip
    ├── deployment-webhook-liveness.yaml     # TCP socket liveness (post-deploy fix)
    └── deployment-cert-controller-liveness.yaml  # TCP socket liveness (post-deploy fix)
└── resources/
    ├── namespace.yaml        # external-secrets-operator namespace
    └── network-policy.yaml   # Ingress/egress rules
```

### values.yaml Configuration

**Top-level sections** (applied to all operator deployments):
- `replicaCount: 3` - High availability
- `image.pullPolicy: Always` - Force fresh images
- `livenessProbe.enabled: true` - Container health monitoring
- `readinessProbe.enabled: true` - Traffic eligibility
- `podSecurityContext.enabled: true, fsGroup: 2000` - File permission enforcement
- `securityContext.runAsUser: 65532` - Non-root UID hardening
- `resources.requests/limits` - CPU/memory constraints
- `strategy.type: RollingUpdate` - Gradual pod replacement
- `affinity.podAntiAffinity` - Pod spread across nodes

**Nested sections** (per-component):
- `webhook.*` - Webhook deployment (replicas, probes, affinity)
- `certController.*` - Certificate controller (replicas, probes, affinity)

### Kustomization Build

```yaml
resources:
  - resources/namespace.yaml
  - resources/network-policy.yaml

patches:
  - target:
      kind: Deployment
    path: patches/deployment.yaml
  - target:
      kind: ClusterRole
      name: external-secrets-cert-controller
    path: patches/cluster-role.yaml
  - target:
      kind: ClusterRoleBinding
    path: patches/cluster-role-binding.yaml
  - target:
      kind: Deployment
      name: external-secrets-webhook
    path: patches/deployment-webhook-liveness.yaml
  - target:
      kind: Deployment
      name: external-secrets-cert-controller
    path: patches/deployment-cert-controller-liveness.yaml

images:
  - name: ghcr.io/external-secrets/external-secrets
    digest: sha256:9440a40b394791a5e93f3f7e1b33399ecbdc0e38273de1d69ed83fe12936fc09
```

---

## Validation Results

### Checkov (Security Policy Scanning)

```
Passed checks: 319
Failed checks: 0
Skipped checks: 4 (intentional policy exceptions with annotations)
```

**Clean status**: No security policy violations

---

### kube-linter (Best Practices)

**Security/Critical Checks**: ✅ All passing

**Advisory Checks Remaining**:
- 3x `no-node-affinity` warnings (optional topology constraint)
  - Recommendation: Add explicit node affinity if pods should target specific node pools
  - Impact: None (deployment functions correctly; optimization opportunity only)

---

## Lessons Learned

### 1. Helm Values as Configuration Surface

**Lesson**: Chart authors expose configuration surfaces for good reasons. Extensive values configuration prevents upgrade friction and enables maintainability.

**Application**: 
- Preferred values.yaml over patches for health probes, resource limits, image policy
- Only used patches for hardcoded template values (restart policy) or policy exceptions

### 2. Multi-Arch Digest Resolution

**Lesson**: Docker image tags are mutable; digests are immutable. Multi-arch images have both per-architecture digests and an index digest.

**Application**:
- Used `docker buildx imagetools inspect` to get multi-arch index digest
- Applied digest via Kustomize (replaces tag references)
- Ensures reproducible builds across all architectures

### 3. Pod Label Matching in Affinity Rules

**Lesson**: Pod anti-affinity selectors must match actual pod labels from templates, not component names.

**Application**:
- Verified actual label keys/values in rendered manifests
- Matched selectors to `app.kubernetes.io/name` (not custom component labels)
- Separate affinity rules per deployment using correct label values

### 4. Policy Exception Annotation Patterns

**Lesson**: Different tools use different annotation formats; both require clear justification.

**Application**:
- Checkov: `checkov.io/skipN` (N increments per annotation)
- kube-linter: `ignore-check.kube-linter.io/<check-name>`
- Included rationale in annotation values for audit trail

### 5. Functional Requirements as Design Constraints

**Lesson**: External Secrets fundamentally requires service account token access and webhook management permissions. These cannot be compromised; policy exceptions are appropriate.

**Application**:
- Documented unavoidable permissions in skip annotations
- Treated functional requirements as immutable constraints
- Used policy exceptions for necessary operations, not careless configuration

### 6. Verify Liveness Probes at Runtime (Not Just at Render Time)

**Lesson**: A liveness probe can render correctly in YAML and pass all linting tools while still failing at runtime if the container doesn't serve the expected HTTP path.

**Application**:
- After initial deployment, webhook and cert-controller restarted due to `/healthz` returning 404
- The chart exposes `webhook.livenessProbe.port` but hard-codes the HTTP path in the template
- Switching to TCP socket probes (which only verify the port is accepting connections) resolved the issue
- **Takeaway**: When a chart enables probes but pods restart immediately, check `kubectl describe pod` events and `kubectl logs --previous` before assuming a network/policy issue

---

## Deployment Readiness

### Production-Ready Checklist

- ✅ Security policies passing (Checkov: 319/319)
- ✅ Security best practices passing (kube-linter security checks)
- ✅ Health probes configured and enabled
- ✅ Resource limits defined (prevent runaway consumption)
- ✅ High availability configured (3 replicas with anti-affinity)
- ✅ Image digest pinned (immutable deployment)
- ✅ Network policies defined (ingress/egress rules)
- ✅ Pod security context hardened (non-root UID, capability dropping)
- ✅ Restart policies configured (automatic recovery)
- ✅ Functional requirements documented (policy exceptions justified)
- ✅ Deployed to cluster - all 9 pods Running/Ready with 0 restarts (May 14, 2026)
- ✅ Liveness probe restart loop identified and resolved (TCP socket probes)

### Post-Deployment Considerations

1. **Monitor** pod distribution across nodes (verify anti-affinity working)
2. **Verify** network policies don't block legitimate traffic
3. **Test** secret reconciliation (external-secret resource creation)
4. **Optional** add node affinity if topology constraints needed

---

## Artifacts

- **Configuration**: [values.yaml](../../applications/external-secrets-operator/base/values.yaml)
- **Patches**: [patches/](../../applications/external-secrets-operator/base/patches/)
- **Resources**: [resources/](../../applications/external-secrets-operator/base/resources/)
- **Build Definition**: [kustomization.yaml](../../applications/external-secrets-operator/base/kustomization.yaml)

---

## References

- [Helm values-first principle](../../kubernetes-helm-patterns.md)
- [External Secrets Official Docs](https://external-secrets.io/)
- [Checkov Policy Reference](https://www.checkov.io/1.Homepage/What%27s%20Checkov)
- [kube-linter Best Practices](https://docs.kubelinter.io/)
- [Pod Anti-Affinity Guide](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#inter-pod-affinity-and-anti-affinity)
