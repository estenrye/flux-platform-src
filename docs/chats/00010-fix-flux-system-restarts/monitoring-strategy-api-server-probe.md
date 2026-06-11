# Monitoring Strategy: Prove Rackspace Spot API Server Instability

Date: May 31, 2026
Chat ID: 00010
Status: Draft

## Objective

Produce timestamped, node-attributed evidence that `10.21.0.1:443` (the managed
Kubernetes API server VIP) becomes unreachable from worker nodes, and correlate
those outages with the controller restart waves observed on May 31, 2026.

## Hypothesis to prove

> The API server VIP goes transiently unreachable at the network layer. All four
> worker nodes see the disruption simultaneously. The outage duration (45 s for
> wave 2, ~5–10 s for wave 3) determines which controllers crash, depending on
> each controller's HTTP timeout for lease operations.

## Current environment state

| Component | Status |
|-----------|--------|
| `opentelemetry-operator` application | Defined in repo, **not yet in cluster kustomization** |
| `prometheus-operator-crds` (PodMonitor, ServiceMonitor) | ✅ Deployed |
| Prometheus / Grafana | ❌ Not deployed |
| Monitoring backend (Grafana Cloud, etc.) | ❌ None configured |

---

## Architecture

```
 Worker Node 1  ──┐
 Worker Node 2  ──┤──▶  OTel Collector DaemonSet  ──▶  Prometheus /metrics endpoint
 Worker Node 3  ──┤         (per-node pod)                    │
 Worker Node 4  ──┘                                    PodMonitor scrape
                         ┌─────────────────┐                  │
                         │ httpcheckreceiver│                  ▼
                         │  10.21.0.1:443  │           Prometheus
                         │  every 5 s      │           (or Grafana Cloud OTLP)
                         └─────────────────┘
                         ┌─────────────────┐
                         │k8sobjectsreceiver│
                         │ flux-system &   │──▶  structured logs per restart event
                         │ crossplane-sys  │
                         └─────────────────┘
```

**DaemonSet mode is critical.** Running one collector per node lets us attribute
each probe result to a specific node. If all four nodes show `httpcheck.status = 0`
at the same instant, that is definitively a control-plane event, not a per-node
issue.

---

## Step 1: Wire the OTel Operator into the cluster

Add to `clusters/crossplane/kustomization.yaml`:

```yaml
  - ../../applications/opentelemetry-operator/base
```

This deploys the operator itself. The collector CR (below) creates the actual
collector pods.

---

## Step 2: Deploy the collector

Create `applications/opentelemetry-operator/base/resources/collector.apiserver-probe.yaml`:

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: apiserver-probe-collector
  namespace: opentelemetry-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: apiserver-probe-collector
rules:
  # k8sobjectsreceiver: list/watch events in target namespaces
  - apiGroups: [""]
    resources: ["events", "pods"]
    verbs: ["get", "list", "watch"]
  # k8sobjectsreceiver: need nodes for node-name attribute enrichment
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: apiserver-probe-collector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: apiserver-probe-collector
subjects:
  - kind: ServiceAccount
    name: apiserver-probe-collector
    namespace: opentelemetry-operator-system
---
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: apiserver-probe
  namespace: opentelemetry-operator-system
spec:
  mode: daemonset
  serviceAccount: apiserver-probe-collector

  # Expose the Prometheus metrics endpoint so a PodMonitor can scrape it.
  ports:
    - name: prometheus
      port: 8889
      protocol: TCP

  # Mount the node name from the downward API so metrics are node-attributed.
  env:
    - name: K8S_NODE_NAME
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName

  config:
    receivers:
      # ── Signal 1: Direct TCP/HTTPS reachability of the API server VIP ────────
      # httpcheck emits httpcheck.status (1=up, 0=down) and httpcheck.duration.
      # At 5 s intervals, a 45-second outage produces ≥9 consecutive 0 readings.
      httpcheck:
        targets:
          - endpoint: https://10.21.0.1:443/readyz
            method: GET
            tls:
              insecure_skip_verify: true   # we don't have the cluster CA in this collector
        collection_interval: 5s

      # ── Signal 2: Pod restart events ─────────────────────────────────────────
      # k8sobjectsreceiver streams Kubernetes Event objects as OTel log records.
      # Each restart produces a BackOff event and a (re)Started event; both are
      # captured here, giving exact timestamps to correlate with probe failures.
      k8sobjects:
        auth_type: serviceAccount
        objects:
          - name: events
            mode: watch
            namespaces:
              - flux-system
              - crossplane-system
            field_selector: "involvedObject.kind=Pod"

    processors:
      batch:
        timeout: 10s

      # Tag every data point with the node name for per-node analysis.
      attributes/node:
        actions:
          - key: k8s.node.name
            value: ${env:K8S_NODE_NAME}
            action: insert

    exporters:
      # ── Primary: Prometheus-format /metrics scrape endpoint ──────────────────
      # A PodMonitor (below) tells Prometheus where to scrape.
      prometheus:
        endpoint: "0.0.0.0:8889"
        metric_expiration: 5m     # keep last reading visible even during outage

      # ── Secondary: structured log output ─────────────────────────────────────
      # Until a log backend exists, restart events are visible in pod logs:
      #   kubectl logs -n opentelemetry-operator-system -l app.kubernetes.io/component=opentelemetry-collector -f
      debug:
        verbosity: basic

    service:
      pipelines:
        metrics:
          receivers: [httpcheck]
          processors: [batch, attributes/node]
          exporters: [prometheus]

        logs:
          receivers: [k8sobjects]
          processors: [batch, attributes/node]
          exporters: [debug]
```

Add the new file to `applications/opentelemetry-operator/base/kustomization.yaml`:

```yaml
resources:
  - resources/networkpolicy.test-pods.yaml
  - resources/networkpolicy.deployment.yaml
  - resources/serviceaccount.test.yaml
  - resources/collector.apiserver-probe.yaml    # ← add this line
```

---

## Step 3: Scrape the metrics

`prometheus-operator-crds` are already deployed, so a `PodMonitor` works once any
Prometheus instance is running.

Create `applications/opentelemetry-operator/base/resources/podmonitor.apiserver-probe.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: apiserver-probe-collector
  namespace: opentelemetry-operator-system
  labels:
    # Match whatever label selector your Prometheus instance uses for PodMonitors.
    # kube-prometheus-stack default: release=<helm-release-name>
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/component: opentelemetry-collector
      app.kubernetes.io/instance: opentelemetry-operator-system.apiserver-probe
  podMetricsEndpoints:
    - port: prometheus
      path: /metrics
      interval: 10s
```

---

## Step 4: Alert on probe failures

Once scraped into Prometheus:

```yaml
# PrometheusRule — alert when any node cannot reach the API server
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: apiserver-probe-instability
  namespace: opentelemetry-operator-system
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: apiserver.probe
      interval: 15s
      rules:
        # Fires when the API server is unreachable from ANY node for > 10 s.
        - alert: ApiserverVIPUnreachable
          expr: |
            httpcheck_status{url="https://10.21.0.1:443/readyz"} == 0
          for: 10s
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "API server VIP unreachable from {{ $labels.k8s_node_name }}"
            description: |
              The Kubernetes API server VIP 10.21.0.1:443 is not responding
              to HTTPS probes from node {{ $labels.k8s_node_name }}.
              This is the same condition that caused leader election crashes on
              May 31, 2026 (waves at 05:27Z, 16:45Z, 18:40Z).

        # Supplementary: fires when > 1 node is affected simultaneously.
        # This distinguishes a single-node network issue from a control-plane event.
        - alert: ApiserverVIPClusterWideOutage
          expr: |
            count(httpcheck_status{url="https://10.21.0.1:443/readyz"} == 0) > 1
          for: 5s
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "API server VIP unreachable from {{ $value }} nodes simultaneously"
            description: |
              {{ $value }} worker nodes cannot reach 10.21.0.1:443 simultaneously.
              This is a control-plane-level event. Expect leader-electing controllers
              to crash within 10–45 seconds depending on their lease timeout.
```

---

## Key metrics emitted

| Metric | Type | Description |
|--------|------|-------------|
| `httpcheck_status` | Gauge | `1` = reachable, `0` = unreachable; labeled by `url` and `k8s_node_name` |
| `httpcheck_duration_milliseconds` | Gauge | Round-trip latency to the API server; spikes before outages are diagnostic |
| `httpcheck_error` | Sum | Cumulative errors since collector start |

---

## What the data will show

If the Rackspace Spot control plane causes the disruptions, the correlated evidence
will look like this:

```
T+00s   httpcheck_status → 0  (all 4 nodes simultaneously)
T+05s   httpcheck_status → 0  (still down)
T+40s   httpcheck_status → 0  (still down)
T+40s   k8sobjects log: BackOff event for notification-controller-... in flux-system
T+41s   k8sobjects log: BackOff event for helm-controller-... in flux-system
T+45s   httpcheck_status → 1  (API server reachable again)
T+60s   k8sobjects log: Started event for notification-controller-... (restarted)
```

If instead only a subset of nodes show the probe failure:
- 1 of 4 nodes: likely a node-level network issue (NIC, route, MTU)
- 3 of 4 nodes: unlikely coincidence; still suggests control-plane but worth
  correlating with Rackspace Spot's node metadata

---

## Backend options

The collector is backend-agnostic. Choose one:

### Option A: Grafana Cloud (fastest to get running — no local infra)

Add an `otlphttp` exporter targeting Grafana Cloud's free OTLP endpoint.
Grafana Cloud provides a built-in Explore view for both metrics and logs.

Replace the `prometheus` exporter in the pipeline with:

```yaml
exporters:
  otlphttp:
    endpoint: https://otlp-gateway-prod-<region>.grafana.net/otlp
    headers:
      authorization: "Basic ${env:GRAFANA_CLOUD_TOKEN}"
```

Inject the token via an `ExternalSecret` from the ESO secret store already in use.

### Option B: kube-prometheus-stack (self-contained, permanent)

Deploy the kube-prometheus-stack Helm chart (Prometheus + Grafana + Alertmanager).
Add to `clusters/crossplane/kustomization.yaml` after the OTel operator entry.
This is the natural next step for a full observability stack on this cluster.

The `PodMonitor` and `PrometheusRule` resources above are ready to use with this
option without changes.

### Option C: Debug mode only (zero infrastructure, immediate)

For immediate validation during an active incident, the `debug` exporter is already
in the pipeline config above. Tail the collector logs on all 4 nodes:

```bash
kubectl logs -n opentelemetry-operator-system \
  -l app.kubernetes.io/component=opentelemetry-collector \
  --all-containers -f 2>&1 \
  | grep -E "httpcheck|BackOff|Restarting|leader"
```

This produces real-time correlated output during the next disruption without
requiring a Prometheus or Grafana deployment.

---

## Implementation order

1. **Enable OTel Operator**: add `../../applications/opentelemetry-operator/base` to `clusters/crossplane/kustomization.yaml`
2. **Add collector CR**: create `collector.apiserver-probe.yaml` + add to `kustomization.yaml`
3. **Choose backend**: Option C (debug) proves the concept immediately; Option A or B for permanent retention
4. **Add alert rules**: after Prometheus is running (Option B)

The collector CR itself is the minimum viable unit — it begins emitting data the moment the operator deploys it. The backend can be added incrementally without modifying the collector config.
