---
name: calico-33-gateway-namespace-mode
description: Calico 3.33's bundled Envoy Gateway deploys each Gateway's proxy into the Gateway's own namespace, named after the Gateway; a name collision left the netdata Gateway with no address and external-dns deleted its record
metadata:
  type: project
---

Upgrading Calico 3.32.x -> 3.33.0 (2026-10-25) switched the bundled Envoy Gateway to `deploy.type: GatewayNamespace`. Proxy infrastructure (ServiceAccount, Deployment, Service, all **named after the Gateway**) now lives in the Gateway's own namespace instead of `tigera-gateway`, and the controller moved to `calico-system`.

**What broke:** the Gateway `netdata/netdata` tried to create ServiceAccount `netdata/netdata`, which the Netdata chart already owns ("already exists and is not owned by this Gateway"). The Gateway stayed `Programmed=False` / `AddressNotAssigned`, and external-dns (`--policy=sync`) deleted `core-infra.netdata.rye.ninja`. The old proxies kept serving on stale config (xDS to the old controller gone), which hid the outage from the data plane.

**Why:** the pattern generalizes: any Gateway whose name equals an existing ServiceAccount/Deployment/Service name in its namespace will fail to provision under 3.33.

**How to apply:**
- Name Gateways so they cannot collide in their namespace (the netdata Gateway is now `netdata-gateway`).
- GatewayClasses now point at operator-managed `EnvoyProxy` copies in `calico-system` (copies of the ones in `envoy-gateway-system`, with telemetry, `ipFamily` and the LB pool annotation carried over). A `ReferenceGrant` for the tracing backendRef must allow `EnvoyProxy` in **`calico-system`** (kept for `envoy-gateway-system` too).
- Select proxy pods by label `gateway.envoyproxy.io/owning-gateway-name/-namespace` in the **Gateway's namespace** (NetworkPolicy podSelector with no namespaceSelector; PodMonitor `namespaceSelector.any: true`). kube-linter then needs `ignore-check.kube-linter.io/dangling-networkpolicypeer-podselector` because the pods are created at runtime.
- Deleting/renaming a Gateway orphans its old infra if the old controller is gone; delete by label manually. cert-manager recreates the Certificate for the new Gateway; the Secret survives.
- Pre-flight a change like this with a throwaway Gateway in its own namespace (class `internal-dedicated`, an `HTTPRouteFilter` `directResponse` route needs no backend) before touching a real one.
- Only `applications/calico/base` deploys the bundled Envoy Gateway (the `GatewayAPI` resource); the `controlplane` and `observability` Calico overlays do not, and have no operator digest pin ([[calico-operator-digest-pin]]).

Related: [[external-dns-multi-instance-collision]] (external-dns owner IDs), [[calico-lb-stale-handle-bug]].
