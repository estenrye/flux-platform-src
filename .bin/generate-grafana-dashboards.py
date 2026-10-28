#!/usr/bin/env python3
"""Generate the Grafana dashboards for the apps installed in clusters/core-infra.

Output: applications/grafana/base/dashboards/*.json plus the configMapGenerator
block (labelled grafana_dashboard=1 for the Grafana sidecar) between the BEGIN/END
markers in applications/grafana/base/kustomization.yaml. The renderer wants a
catalog.yaml in every kustomization directory, so dashboards/ has none of its own.

Series reach VictoriaMetrics through the otelcol-ds collector's OTLP export,
where service.name becomes the `service_name` label. Every app dashboard therefore has
a `svc` variable over that app's service_name values (VictoriaMetrics stores
the scrape job as service_name and the target as service_instance_id), and
every panel filters on it. The regex per app was taken from the live label
values; "All" selects exactly that app's services.

Usage: .bin/generate-grafana-dashboards.py   (run from anywhere; rewrites files)
"""
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "applications/grafana/base/dashboards"
KUSTOMIZATION = OUT.parent / "kustomization.yaml"
BEGIN = "# BEGIN generated dashboards (.bin/generate-grafana-dashboards.py)"
END = "# END generated dashboards"
DS = {"type": "prometheus", "uid": "victoria-metrics"}

# Common process/runtime row shared by every Go-based app.
COMMON = [
    ("CPU (cores)", 'sum by (service_name, service_instance_id) (rate(process_cpu_seconds_total{service_name=~"$svc"}[5m]))', "short"),
    ("Resident memory", 'sum by (service_name, service_instance_id) (process_resident_memory_bytes{service_name=~"$svc"})', "bytes"),
    ("Goroutines", 'sum by (service_name, service_instance_id) (go_goroutines{service_name=~"$svc"})', "short"),
    ("Open file descriptors", 'sum by (service_name, service_instance_id) (process_open_fds{service_name=~"$svc"})', "short"),
]

CONTROLLER_RUNTIME = [
    ("Reconciles/s by result", 'sum by (controller, result) (rate(controller_runtime_reconcile_total{service_name=~"$svc"}[5m]))', "ops"),
    ("Reconcile errors/s", 'sum by (controller) (rate(controller_runtime_reconcile_errors_total{service_name=~"$svc"}[5m]))', "ops"),
    ("Reconcile duration p95", 'histogram_quantile(0.95, sum by (le, controller) (rate(controller_runtime_reconcile_time_seconds_bucket{service_name=~"$svc"}[5m])))', "s"),
    ("Workqueue depth", 'sum by (name) (workqueue_depth{service_name=~"$svc"})', "short"),
]

# slug -> (title, service_name regex, [(panel title, expr, unit)], include controller-runtime row)
APPS = {
    "flux": (
        "Flux controllers",
        "flux-system/flux-system",
        [
            ("Reconciliations/s by kind", 'sum by (kind) (rate(gotk_reconcile_duration_seconds_count{service_name=~"$svc"}[5m]))', "ops"),
            ("Reconcile duration p95 by kind", 'histogram_quantile(0.95, sum by (le, kind) (rate(gotk_reconcile_duration_seconds_bucket{service_name=~"$svc"}[5m])))', "s"),
        ],
        True,
    ),
    "flux-state": (
        "Flux resource state (flux-state-metrics)",
        "flux-state-metrics-kube-state-metrics",
        [
            ("Resources by kind and readiness", 'count by (customresource_kind, ready) (gotk_resource_info)', "short"),
            ("Resources not ready", 'count by (customresource_kind, name, exported_namespace) (gotk_resource_info{ready!="True"})', "short"),
            ("Suspended resources", 'count by (customresource_kind) (gotk_resource_info{suspended="true"})', "short"),
        ],
        False,
    ),
    "cert-manager": (
        "cert-manager",
        "cert-manager|cainjector|webhook",
        [
            ("Certificates ready", 'sum by (condition) (certmanager_certificate_ready_status{service_name=~"$svc"})', "short"),
            ("Days until certificate expiry", '(certmanager_certificate_expiration_timestamp_seconds{service_name=~"$svc"} - time()) / 86400', "d"),
            ("Sync calls/s by controller", 'sum by (controller) (rate(certmanager_controller_sync_call_count_total{service_name=~"$svc"}[5m]))', "ops"),
            ("ACME client requests/s by status", 'sum by (status, method) (rate(certmanager_http_acme_client_request_count_total{service_name=~"$svc"}[5m]))', "ops"),
        ],
        False,
    ),
    "cert-manager-approver-policy": (
        "cert-manager approver-policy",
        "cert-manager-approver-policy-metrics",
        [],
        True,
    ),
    "cert-manager-trust-manager": (
        "cert-manager trust-manager",
        "trust-manager|trust-manager-metrics",
        [],
        True,
    ),
    "cert-manager-spiffe": (
        "cert-manager SPIFFE CSI driver approver",
        "cert-manager-csi-driver-spiffe-approver-metrics",
        [],
        True,
    ),
    "external-dns": (
        "external-dns",
        "external-dns",
        [
            ("Registry endpoints", 'sum by (service_name) (external_dns_registry_endpoints_total{service_name=~"$svc"})', "short"),
            ("Source endpoints", 'sum by (service_name) (external_dns_source_endpoints_total{service_name=~"$svc"})', "short"),
            ("Seconds since last sync", 'time() - external_dns_controller_last_sync_timestamp_seconds{service_name=~"$svc"}', "s"),
            ("Verified A/AAAA records", 'sum by (record_type) (external_dns_controller_verified_records{service_name=~"$svc"})', "short"),
            ("Registry/source errors/s", 'sum by (service_name) (rate(external_dns_registry_errors_total{service_name=~"$svc"}[5m]) + rate(external_dns_source_errors_total{service_name=~"$svc"}[5m]))', "ops"),
        ],
        False,
    ),
    "keda": (
        "KEDA",
        "keda-admission-webhooks|keda/keda-operator|keda/keda-operator-metrics-apiserver",
        [
            ("Active scalers", 'sum by (scaledObject, scaler) (keda_scaler_active{service_name=~"$svc"})', "short"),
            ("Scaler errors/s", 'sum by (scaledObject) (rate(keda_scaled_object_errors_total{service_name=~"$svc"}[5m])) + sum by (scaledObject) (rate(keda_scaler_detail_errors_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Scaler metric value", 'sum by (scaledObject, metric) (keda_scaler_metrics_value{service_name=~"$svc"})', "short"),
        ],
        True,
    ),
    "reloader": (
        "Reloader",
        "reloader/reloader-reloader",
        [
            ("Reloads/s by result", 'sum by (success) (rate(reloader_reload_executed_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Reloads by namespace", 'sum by (namespace) (reloader_reload_executed_total{service_name=~"$svc"})', "short"),
        ],
        False,
    ),
    "descheduler": (
        "Descheduler",
        "descheduler",
        [
            ("Loop duration p95", 'histogram_quantile(0.95, sum by (le) (rate(descheduler_loop_duration_seconds_bucket{service_name=~"$svc"}[15m])))', "s"),
            ("Strategy duration p95", 'histogram_quantile(0.95, sum by (le, strategy) (rate(descheduler_strategy_duration_seconds_bucket{service_name=~"$svc"}[15m])))', "s"),
            ("Loops/hour", 'sum(increase(descheduler_loop_duration_seconds_count{service_name=~"$svc"}[1h]))', "short"),
        ],
        False,
    ),
    "envoy-gateway-proxy": (
        "Gateway API Envoy proxies",
        "calico-system/envoy-proxy",
        [
            ("Requests/s by listener", 'sum by (envoy_http_conn_manager_prefix, service_name) (rate(envoy_http_downstream_rq_total{service_name=~"$svc"}[5m]))', "reqps"),
            ("5xx responses/s", 'sum by (envoy_http_conn_manager_prefix) (rate(envoy_http_downstream_rq_total{envoy_response_code_class="5", service_name=~"$svc"}[5m]))', "reqps"),
            ("Upstream request time p95", 'histogram_quantile(0.95, sum by (le, envoy_cluster_name) (rate(envoy_cluster_upstream_rq_time_bucket{service_name=~"$svc"}[5m])))', "ms"),
            ("Active downstream connections", 'sum by (service_name) (envoy_http_downstream_cx_active{service_name=~"$svc"})', "short"),
        ],
        False,
    ),
    "spegel": (
        "Spegel",
        "spegel",
        [
            ("Advertised images", 'sum by (registry) (spegel_advertised_keys{service_name=~"$svc"})', "short"),
            ("Mirror requests/s by cache result", 'sum by (cache, registry) (rate(spegel_mirror_requests_total{service_name=~"$svc"}[5m]))', "reqps"),
            ("Resolve duration p95", 'histogram_quantile(0.95, sum by (le) (rate(spegel_resolve_duration_seconds_bucket{service_name=~"$svc"}[5m])))', "s"),
        ],
        False,
    ),
    "vertical-pod-autoscaler": (
        "Vertical Pod Autoscaler",
        "kube-system/vpa",
        [
            ("Recommendation latency p95", 'histogram_quantile(0.95, sum by (le) (rate(vpa_recommender_recommendation_latency_seconds_bucket{service_name=~"$svc"}[5m])))', "s"),
            ("Tracked VPAs", 'sum(vpa_recommender_vpa_objects_count{service_name=~"$svc"})', "short"),
            ("Updater evictions/s", 'sum(rate(vpa_updater_evicted_pods_total{service_name=~"$svc"}[15m]))', "ops"),
        ],
        False,
    ),
    "cinder-csi": (
        "Cinder CSI and snapshot controller",
        "kube-system/csi-cinder-controllerplugin|kube-system/snapshot-controller",
        [
            ("CSI operations/s by method", 'sum by (method_name, grpc_status_code) (rate(csi_sidecar_operations_seconds_count{service_name=~"$svc"}[5m]))', "ops"),
            ("CSI operation duration p95", 'histogram_quantile(0.95, sum by (le, method_name) (rate(csi_sidecar_operations_seconds_bucket{service_name=~"$svc"}[5m])))', "s"),
            ("Snapshot operations in flight", 'sum by (service_name) (snapshot_controller_operations_in_flight{service_name=~"$svc"})', "short"),
        ],
        False,
    ),
    "metrics-server": (
        "metrics-server",
        "metrics-server",
        [
            ("Metric freshness p95", 'histogram_quantile(0.95, sum by (le) (rate(metrics_server_api_metric_freshness_seconds_bucket{service_name=~"$svc"}[5m])))', "s"),
            ("Scrape tick duration p95", 'histogram_quantile(0.95, sum by (le) (rate(metrics_server_manager_tick_duration_seconds_bucket{service_name=~"$svc"}[5m])))', "s"),
            ("Kubelet scrape requests/s", 'sum by (success) (rate(metrics_server_kubelet_request_total{service_name=~"$svc"}[5m]))', "ops"),
        ],
        False,
    ),
    "kubelet-serving-cert-approver": (
        "kubelet-serving-cert-approver",
        "kubelet-serving-cert-approver/kubelet-serving-cert-approver",
        [],
        True,
    ),
    "opentelemetry-operator": (
        "OpenTelemetry operator",
        "opentelemetry-operator",
        [],
        True,
    ),
}

# Node-level dashboard from the collector's hostmetrics receiver (no service variable).
NODES = (
    "Nodes (hostmetrics)",
    [
        ("CPU utilisation", 'avg by (host_name) (system_cpu_utilization_ratio{state!="idle"})', "percentunit"),
        ("Load average (1m)", 'system_cpu_load_average_1m', "short"),
        ("Memory used", 'sum by (host_name) (system_memory_usage_bytes{state="used"})', "bytes"),
        ("Network receive", 'sum by (host_name) (rate(system_network_io_bytes_total{direction="receive"}[5m]))', "Bps"),
        ("Network transmit", 'sum by (host_name) (rate(system_network_io_bytes_total{direction="transmit"}[5m]))', "Bps"),
    ],
)


def panel(idx, title, expr, unit):
    return {
        "id": idx,
        "type": "timeseries",
        "title": title,
        "datasource": DS,
        "gridPos": {"h": 8, "w": 12, "x": 12 * ((idx - 1) % 2), "y": 8 * ((idx - 1) // 2)},
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
        "targets": [{"datasource": DS, "expr": expr, "legendFormat": "", "refId": "A"}],
    }


def dashboard(uid, title, panels, svc_regex=None):
    templating = []
    if svc_regex:
        templating.append({
            "name": "svc",
            "label": "Service",
            "type": "query",
            "datasource": DS,
            "query": {"query": f'label_values({{service_name=~"{svc_regex}"}}, service_name)', "refId": "svc"},
            "refresh": 2,
            "includeAll": True,
            "multi": True,
            "allValue": svc_regex,
            "current": {"selected": True, "text": "All", "value": "$__all"},
        })
    return {
        "uid": uid,
        "title": title,
        "tags": ["core-infra", "generated"],
        "schemaVersion": 39,
        "version": 1,
        "editable": False,
        "time": {"from": "now-6h", "to": "now"},
        "refresh": "1m",
        "templating": {"list": templating},
        "panels": [panel(i + 1, *p) for i, p in enumerate(panels)],
    }


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.json"):
        old.unlink()
    files = []
    for slug, (title, svc_regex, panels, ctrl) in APPS.items():
        allp = list(panels) + (CONTROLLER_RUNTIME if ctrl else []) + COMMON
        d = dashboard(f"core-infra-{slug}", title, allp, svc_regex)
        (OUT / f"{slug}.json").write_text(json.dumps(d, indent=2) + "\n")
        files.append(f"{slug}.json")
    d = dashboard("core-infra-nodes", NODES[0], NODES[1])
    (OUT / "nodes.json").write_text(json.dumps(d, indent=2) + "\n")
    files.append("nodes.json")

    lines = [
        "generatorOptions:",
        "  disableNameSuffixHash: true",
        "  labels:",
        '    grafana_dashboard: "1"',
        "",
        "configMapGenerator:",
    ]
    for f in sorted(files):
        lines += [f"  - name: grafana-dashboard-{f[:-5]}", "    files:", f"      - dashboards/{f}"]
    kust = KUSTOMIZATION.read_text()
    head = kust[: kust.index(BEGIN) + len(BEGIN)]
    tail = kust[kust.index(END):]
    KUSTOMIZATION.write_text(head + "\n" + "\n".join(lines) + "\n" + tail)
    print(f"wrote {len(files)} dashboards to {OUT}")


if __name__ == "__main__":
    main()
