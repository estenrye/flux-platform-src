#!/usr/bin/env python3
"""Generate the Grafana dashboards for the apps installed in clusters/core-infra.

Output: applications/grafana/base/dashboards/*.json plus the configMapGenerator
block (labelled grafana_dashboard=1 for the Grafana sidecar) between the BEGIN/END
markers in applications/grafana/base/kustomization.yaml. The renderer wants a
catalog.yaml in every kustomization directory, so dashboards/ has none of its own.

Series reach VictoriaMetrics through the otelcol-ds collector's OTLP export,
where service.name becomes the `job` label. Every app dashboard therefore has
a `job` variable seeded from one anchor metric of that app, and every panel
filters on it, so the dashboards do not depend on PodMonitor/ServiceMonitor
naming.

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
    ("CPU (cores)", 'sum by (job, instance) (rate(process_cpu_seconds_total{job=~"$job"}[5m]))', "short"),
    ("Resident memory", 'sum by (job, instance) (process_resident_memory_bytes{job=~"$job"})', "bytes"),
    ("Goroutines", 'sum by (job, instance) (go_goroutines{job=~"$job"})', "short"),
    ("Open file descriptors", 'sum by (job, instance) (process_open_fds{job=~"$job"})', "short"),
]

CONTROLLER_RUNTIME = [
    ("Reconciles/s by result", 'sum by (controller, result) (rate(controller_runtime_reconcile_total{job=~"$job"}[5m]))', "ops"),
    ("Reconcile errors/s", 'sum by (controller) (rate(controller_runtime_reconcile_errors_total{job=~"$job"}[5m]))', "ops"),
    ("Reconcile duration p95", 'histogram_quantile(0.95, sum by (le, controller) (rate(controller_runtime_reconcile_time_seconds_bucket{job=~"$job"}[5m])))', "s"),
    ("Workqueue depth", 'sum by (name) (workqueue_depth{job=~"$job"})', "short"),
]

# slug -> (title, anchor metric, [(panel title, expr, unit)], include controller-runtime row)
APPS = {
    "flux": (
        "Flux controllers",
        "gotk_reconcile_duration_seconds_count",
        [
            ("Reconciliations/s by kind", 'sum by (kind) (rate(gotk_reconcile_duration_seconds_count{job=~"$job"}[5m]))', "ops"),
            ("Reconcile duration p95 by kind", 'histogram_quantile(0.95, sum by (le, kind) (rate(gotk_reconcile_duration_seconds_bucket{job=~"$job"}[5m])))', "s"),
        ],
        True,
    ),
    "flux-state": (
        "Flux resource state (flux-state-metrics)",
        "gotk_resource_info",
        [
            ("Resources by kind and readiness", 'count by (customresource_kind, ready) (gotk_resource_info)', "short"),
            ("Resources not ready", 'count by (customresource_kind, name, exported_namespace) (gotk_resource_info{ready!="True"})', "short"),
            ("Suspended resources", 'count by (customresource_kind) (gotk_resource_info{suspended="true"})', "short"),
        ],
        False,
    ),
    "cert-manager": (
        "cert-manager",
        "certmanager_certificate_ready_status",
        [
            ("Certificates ready", 'sum by (condition) (certmanager_certificate_ready_status{job=~"$job"})', "short"),
            ("Days until certificate expiry", '(certmanager_certificate_expiration_timestamp_seconds{job=~"$job"} - time()) / 86400', "d"),
            ("Sync calls/s by controller", 'sum by (controller) (rate(certmanager_controller_sync_call_count{job=~"$job"}[5m]))', "ops"),
            ("ACME client requests/s by status", 'sum by (status, method) (rate(certmanager_http_acme_client_request_count{job=~"$job"}[5m]))', "ops"),
        ],
        False,
    ),
    "cert-manager-approver-policy": (
        "cert-manager approver-policy",
        "controller_runtime_reconcile_total",
        [],
        True,
    ),
    "cert-manager-trust-manager": (
        "cert-manager trust-manager",
        "trust_manager_bundle_reconcile_count",
        [("Bundle reconciles/s", 'sum by (job) (rate(trust_manager_bundle_reconcile_count{job=~"$job"}[5m]))', "ops")],
        True,
    ),
    "cert-manager-spiffe": (
        "cert-manager SPIFFE CSI driver approver",
        "controller_runtime_reconcile_total",
        [],
        True,
    ),
    "external-dns": (
        "external-dns",
        "external_dns_registry_endpoints_total",
        [
            ("Registry endpoints", 'sum by (job) (external_dns_registry_endpoints_total{job=~"$job"})', "short"),
            ("Source endpoints", 'sum by (job) (external_dns_source_endpoints_total{job=~"$job"})', "short"),
            ("Seconds since last sync", 'time() - external_dns_controller_last_sync_timestamp_seconds{job=~"$job"}', "s"),
            ("Verified A/AAAA records", 'sum by (record_type) (external_dns_controller_verified_records{job=~"$job"})', "short"),
            ("Registry/source errors/s", 'sum by (job) (rate(external_dns_registry_errors_total{job=~"$job"}[5m]) + rate(external_dns_source_errors_total{job=~"$job"}[5m]))', "ops"),
        ],
        False,
    ),
    "external-secrets": (
        "external-secrets",
        "externalsecret_sync_calls_total",
        [
            ("ExternalSecret status (Ready)", 'sum by (name, namespace) (externalsecret_status_condition{type="Ready", status="True", job=~"$job"})', "short"),
            ("ExternalSecrets not ready", 'sum by (name, namespace) (externalsecret_status_condition{type="Ready", status="False", job=~"$job"})', "short"),
            ("Sync calls/s", 'sum by (name) (rate(externalsecret_sync_calls_total{job=~"$job"}[5m]))', "ops"),
            ("Sync errors/s", 'sum by (name) (rate(externalsecret_sync_calls_error{job=~"$job"}[5m]))', "ops"),
        ],
        True,
    ),
    "keda": (
        "KEDA",
        "keda_scaler_active",
        [
            ("Active scalers", 'sum by (scaledObject, scaler) (keda_scaler_active{job=~"$job"})', "short"),
            ("Scaler errors/s", 'sum by (scaledObject, scaler) (rate(keda_scaler_errors_total{job=~"$job"}[5m]))', "ops"),
            ("Scaler metric value", 'sum by (scaledObject, metric) (keda_scaler_metrics_value{job=~"$job"})', "short"),
        ],
        True,
    ),
    "reloader": (
        "Reloader",
        "reloader_reload_executed_total",
        [
            ("Reloads/s by result", 'sum by (success) (rate(reloader_reload_executed_total{job=~"$job"}[5m]))', "ops"),
            ("Reloads by namespace", 'sum by (namespace) (reloader_reload_executed_total{job=~"$job"})', "short"),
        ],
        False,
    ),
    "descheduler": (
        "Descheduler",
        "descheduler_pods_evicted_total",
        [
            ("Pods evicted/s by strategy", 'sum by (strategy, result) (rate(descheduler_pods_evicted_total{job=~"$job"}[15m]))', "ops"),
            ("Pods evicted by namespace", 'sum by (namespace) (descheduler_pods_evicted_total{job=~"$job"})', "short"),
        ],
        False,
    ),
    "calico": (
        "Calico (Felix, Typha, kube-controllers)",
        "felix_active_local_endpoints",
        [
            ("Active local endpoints", 'sum by (instance) (felix_active_local_endpoints{job=~"$job"})', "short"),
            ("Cluster hosts", 'max(felix_cluster_num_hosts{job=~"$job"})', "short"),
            ("Dataplane apply time p95", 'histogram_quantile(0.95, sum by (le) (rate(felix_int_dataplane_apply_time_seconds_bucket{job=~"$job"}[5m])))', "s"),
            ("Typha connections", 'sum by (instance) (typha_connections_active{job=~"$job"})', "short"),
            ("Policy/IP set errors/s", 'sum by (instance) (rate(felix_int_dataplane_failures{job=~"$job"}[5m]))', "ops"),
        ],
        False,
    ),
    "envoy-gateway-proxy": (
        "Gateway API Envoy proxies",
        "envoy_http_downstream_rq_total",
        [
            ("Requests/s by listener", 'sum by (envoy_http_conn_manager_prefix, job) (rate(envoy_http_downstream_rq_total{job=~"$job"}[5m]))', "reqps"),
            ("5xx responses/s", 'sum by (envoy_http_conn_manager_prefix) (rate(envoy_http_downstream_rq_xx{envoy_response_code_class="5", job=~"$job"}[5m]))', "reqps"),
            ("Upstream request time p95", 'histogram_quantile(0.95, sum by (le, envoy_cluster_name) (rate(envoy_cluster_upstream_rq_time_bucket{job=~"$job"}[5m])))', "ms"),
            ("Active downstream connections", 'sum by (job) (envoy_http_downstream_cx_active{job=~"$job"})', "short"),
        ],
        False,
    ),
    "spegel": (
        "Spegel",
        "spegel_advertised_images",
        [
            ("Advertised images", 'sum by (registry) (spegel_advertised_images{job=~"$job"})', "short"),
            ("Mirror requests/s by cache result", 'sum by (cache, registry) (rate(spegel_mirror_requests_total{job=~"$job"}[5m]))', "reqps"),
            ("Resolve duration p95", 'histogram_quantile(0.95, sum by (le) (rate(spegel_resolve_duration_seconds_bucket{job=~"$job"}[5m])))', "s"),
        ],
        False,
    ),
    "vertical-pod-autoscaler": (
        "Vertical Pod Autoscaler",
        "vpa_recommender_recommendation_latency_bucket",
        [
            ("Recommendation latency p95", 'histogram_quantile(0.95, sum by (le) (rate(vpa_recommender_recommendation_latency_bucket{job=~"$job"}[5m])))', "s"),
            ("Tracked VPAs", 'sum(vpa_recommender_vpa_objects_count{job=~"$job"})', "short"),
            ("Updater evictions/s", 'sum(rate(vpa_updater_evicted_pods_total{job=~"$job"}[15m]))', "ops"),
        ],
        False,
    ),
    "cinder-csi": (
        "Cinder CSI and snapshot controller",
        "csi_sidecar_operations_seconds_count",
        [
            ("CSI operations/s by method", 'sum by (method_name, grpc_status_code) (rate(csi_sidecar_operations_seconds_count{job=~"$job"}[5m]))', "ops"),
            ("CSI operation duration p95", 'histogram_quantile(0.95, sum by (le, method_name) (rate(csi_sidecar_operations_seconds_bucket{job=~"$job"}[5m])))', "s"),
            ("Snapshot operations/s", 'sum by (operation_name, operation_status) (rate(snapshot_controller_operation_total_seconds_count{job=~"$job"}[5m]))', "ops"),
        ],
        False,
    ),
    "metrics-server": (
        "metrics-server",
        "metrics_server_api_metric_freshness_seconds_count",
        [
            ("Metric freshness p95", 'histogram_quantile(0.95, sum by (le) (rate(metrics_server_api_metric_freshness_seconds_bucket{job=~"$job"}[5m])))', "s"),
            ("Scrape tick duration p95", 'histogram_quantile(0.95, sum by (le) (rate(metrics_server_manager_tick_duration_seconds_bucket{job=~"$job"}[5m])))', "s"),
            ("Kubelet scrape requests/s", 'sum by (success) (rate(metrics_server_kubelet_request_total{job=~"$job"}[5m]))', "ops"),
        ],
        False,
    ),
    "kubelet-serving-cert-approver": (
        "kubelet-serving-cert-approver",
        "controller_runtime_reconcile_total",
        [],
        True,
    ),
    "opentelemetry-operator": (
        "OpenTelemetry operator",
        "opentelemetry_operator_collector_info",
        [("Managed collectors", 'count(opentelemetry_operator_collector_info{job=~"$job"})', "short")],
        True,
    ),
    "opentelemetry-collector": (
        "OpenTelemetry collectors (otelcol-ds)",
        "otelcol_process_uptime_seconds_total",
        [
            ("Metric points accepted/s", 'sum by (receiver) (rate(otelcol_receiver_accepted_metric_points_total{job=~"$job"}[5m]))', "ops"),
            ("Metric points sent/s", 'sum by (exporter) (rate(otelcol_exporter_sent_metric_points_total{job=~"$job"}[5m]))', "ops"),
            ("Metric points send failures/s", 'sum by (exporter) (rate(otelcol_exporter_send_failed_metric_points_total{job=~"$job"}[5m]))', "ops"),
            ("Log records sent/s", 'sum by (exporter) (rate(otelcol_exporter_sent_log_records_total{job=~"$job"}[5m]))', "ops"),
            ("Exporter queue size", 'sum by (exporter) (otelcol_exporter_queue_size{job=~"$job"})', "short"),
            ("Collector memory RSS", 'sum by (instance) (otelcol_process_memory_rss_bytes{job=~"$job"})', "bytes"),
        ],
        False,
    ),
    "openstack-ccm": (
        "OpenStack cloud controller manager",
        "cloudprovider_openstack_api_request_duration_seconds_count",
        [
            ("OpenStack API requests/s", 'sum by (request) (rate(cloudprovider_openstack_api_request_duration_seconds_count{job=~"$job"}[5m]))', "ops"),
            ("OpenStack API duration p95", 'histogram_quantile(0.95, sum by (le, request) (rate(cloudprovider_openstack_api_request_duration_seconds_bucket{job=~"$job"}[5m])))', "s"),
            ("OpenStack API errors/s", 'sum by (request) (rate(cloudprovider_openstack_api_request_errors{job=~"$job"}[5m]))', "ops"),
        ],
        True,
    ),
}

# Node-level dashboard from the collector's hostmetrics receiver (no job variable).
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


def dashboard(uid, title, panels, anchor=None):
    templating = []
    if anchor:
        templating.append({
            "name": "job",
            "label": "Job",
            "type": "query",
            "datasource": DS,
            "query": {"query": f"label_values({anchor}, job)", "refId": "job"},
            "refresh": 2,
            "includeAll": True,
            "multi": True,
            "allValue": ".*",
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
    for slug, (title, anchor, panels, ctrl) in APPS.items():
        allp = list(panels) + (CONTROLLER_RUNTIME if ctrl else []) + COMMON
        d = dashboard(f"core-infra-{slug}", title, allp, anchor)
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
