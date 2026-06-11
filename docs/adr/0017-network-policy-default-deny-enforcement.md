# 17. Network Policy Default-Deny Enforcement

Date: 2026-06-11

## Status

Accepted

## Context

Kubernetes does not restrict pod-to-pod or pod-to-external traffic by default.
Without network policies, a compromised workload can freely communicate with
any other pod or external endpoint in the cluster.

The platform enforces a zero-trust network posture as a defense-in-depth
measure. Even if a workload is compromised, the blast radius is limited to
the traffic it has been explicitly granted.

Different Kubernetes CNI providers implement network policies differently.
The platform currently runs on Rackspace Spot, which uses Calico as the CNI.
Calico supports both standard Kubernetes `NetworkPolicy` and its own extended
`GlobalNetworkPolicy` and `NetworkPolicy` resources with additional capabilities
(e.g., policy precedence, deny rules, protocol-aware rules).

## Decision

We enforce a global default-deny policy on all clusters and require every
application to declare its required traffic explicitly.

### Global default-deny policy

The `global-network-policy-default-deny` application deploys a default-deny
policy to all namespaces. Provider-specific variants exist:

- `applications/global-network-policy-default-deny/rackspace-spot/` — uses
  Calico's `GlobalNetworkPolicy` for Calico-based clusters

The default-deny policy denies all ingress and egress for all pods in all
namespaces except system namespaces (kube-system, kube-public, etc.). The global
policy must be applied before any workloads are deployed. It includes allowances
for essential system traffic (e.g., DNS to kube-dns in kube-system).

### Per-application network policy requirements

Every application in `applications/` must include a network policy that grants
only the traffic it needs. The standard Kubernetes `NetworkPolicy` is used.
Common patterns:

**Operator webhook server** (ingress from API server):
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: <component>-allow-ingress
  namespace: <component>-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: <component>
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - port: 9443
      protocol: TCP
```

**Metrics scrape** (ingress from Prometheus):
```yaml
  ingress:
  - ports:
    - port: 8080
      protocol: TCP
    - port: metrics
      protocol: TCP
    from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
```

**DNS egress** (required by almost all workloads):
```yaml
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
```

**Kubernetes API server egress**:
```yaml
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - port: 6443
      protocol: TCP
```

### Adding network policy for a new application

1. Identify what traffic the application needs:
   - What ports does it expose (webhooks, metrics, health probes)?
   - What does it call out to (Kubernetes API, cloud APIs, DNS)?
   - Does it need to be reachable from other namespaces?
2. Write a `NetworkPolicy` in `applications/<name>/resources/network-policy.yaml`
   or `applications/<name>/base/network-policy.yaml`.
3. Add it to the appropriate `kustomization.yaml` as a resource.

### Debugging network policy issues

If a component fails to start or behaves unexpectedly after deployment, check
for network policy blocks. Use standard Kubernetes tools to inspect connection
failures:

```bash
# Check if a pod is running and ready
kubectl get pod -n <namespace> <pod-name>

# Inspect logs for connection errors
kubectl logs -n <namespace> <pod-name>

# Describe the pod to see events
kubectl describe pod -n <namespace> <pod-name>
```

A blocked connection will typically appear as a timeout or refused connection
in the application logs. The network policy name that dropped the traffic is
not visible without CNI-specific monitoring tools.

## Consequences

- Every new application deployment requires network policy authoring before
  the application can function. Missing network policies cause silent connection
  failures that can be difficult to diagnose without detailed application logs
  and understanding of the global-deny baseline.
- Health probes from the kubelet must be explicitly permitted. The kubelet
  communicates directly with pods on their configured probe ports and must not
  be blocked by network policy.
- The platform uses a single CNI provider (Calico on Rackspace Spot). If the
  platform migrates to a different CNI, Calico-specific global policies must
  be replaced with equivalent policies for the new provider.
- Network policies are namespace-scoped in Kubernetes. The global default-deny
  is cluster-wide via Calico's `GlobalNetworkPolicy`, while per-application
  policies use standard `NetworkPolicy` resources.

## References

- [ADR-10: GitOps Layering and Kustomize Composition Strategy](0010-gitops-layering-and-kustomize-composition-strategy.md)
- [ADR-13: Helm Chart Hardening via Kustomize Patches](0013-helm-chart-hardening-via-kustomize-patches.md)
- [Kubernetes: Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Calico: Network Policy](https://docs.tigera.io/calico/latest/reference/resources/networkpolicy)
- [Calico: Global Network Policy](https://docs.tigera.io/calico/latest/reference/resources/globalnetworkpolicy)
