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

# slug -> (title, service_name regex, [(panel title, expr, unit)], include
# controller-runtime row[, include process/Go row (default True)])
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
    "calico": (
        "Calico (Felix, Typha, kube-controllers)",
        "calico-node-metrics|calico-typha-metrics|calico-kube-controllers-metrics",
        [
            ("Active local endpoints", 'sum by (service_instance_id) (felix_active_local_endpoints{service_name=~"$svc"})', "short"),
            ("Active local policies", 'sum by (service_instance_id) (felix_active_local_policies{service_name=~"$svc"})', "short"),
            ("Cluster hosts / workload endpoints", 'max(felix_cluster_num_hosts{service_name=~"$svc"}) or max(felix_cluster_num_workload_endpoints{service_name=~"$svc"})', "short"),
            ("Dataplane apply time p99", 'max by (service_instance_id) (felix_int_dataplane_apply_time_seconds{quantile="0.99", service_name=~"$svc"})', "s"),
            ("Dataplane failures/s", 'sum by (service_instance_id) (rate(felix_int_dataplane_failures_total{service_name=~"$svc"}[5m]))', "ops"),
            ("iptables/ipset errors/s", 'sum by (service_instance_id) (rate(felix_iptables_restore_errors_total{service_name=~"$svc"}[5m]) + rate(felix_ipset_errors_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Calc graph updates/s", 'sum by (service_instance_id) (rate(felix_calc_graph_updates_processed_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Typha connections", 'sum by (service_instance_id) (typha_connections_active{service_name=~"$svc"})', "short"),
            ("Typha updates/s", 'sum by (service_instance_id) (rate(typha_updates_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Typha ping latency p99", 'max by (service_instance_id) (typha_ping_latency{quantile="0.99", service_name=~"$svc"})', "s"),
        ],
        False,
    ),
    "external-secrets": (
        "external-secrets",
        "external-secrets.*",
        [
            ("ExternalSecrets ready", 'sum by (name, namespace) (externalsecret_status_condition{condition="Ready", status="True", service_name=~"$svc"})', "short"),
            ("ExternalSecrets not ready", 'sum by (name, namespace) (externalsecret_status_condition{condition="Ready", status="False", service_name=~"$svc"})', "short"),
            ("Sync calls/s", 'sum by (name) (rate(externalsecret_sync_calls_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Sync errors/s", 'sum by (name) (rate(externalsecret_sync_calls_error_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Provider API calls/s", 'sum by (provider, call, status) (rate(externalsecret_provider_api_calls_count_total{service_name=~"$svc"}[5m]))', "ops"),
            ("ClusterSecretStores ready", 'sum by (name) (clustersecretstore_status_condition{condition="Ready", status="True", service_name=~"$svc"})', "short"),
        ],
        True,
    ),
    "opentelemetry-collector": (
        "OpenTelemetry collectors (otelcol-ds) and target allocator",
        "otelcol-k8s",
        [
            ("Metric points accepted/s", 'sum by (receiver) (rate(otelcol_receiver_accepted_metric_points_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Metric points refused/s", 'sum by (receiver) (rate(otelcol_receiver_refused_metric_points_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Metric points sent/s", 'sum by (exporter) (rate(otelcol_exporter_sent_metric_points_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Metric points send failures/s", 'sum by (exporter) (rate(otelcol_exporter_send_failed_metric_points_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Log records sent/s", 'sum by (exporter) (rate(otelcol_exporter_sent_log_records_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Exporter queue size", 'sum by (exporter) (otelcol_exporter_queue_size{service_name=~"$svc"})', "short"),
            ("Collector memory RSS by node", 'sum by (k8s_node_name) (otelcol_process_memory_rss_bytes{service_name=~"$svc"})', "bytes"),
            ("Collector CPU (cores) by node", 'sum by (k8s_node_name) (rate(otelcol_process_cpu_seconds_total{service_name=~"$svc"}[5m]))', "short"),
            ("Target allocator: targets per collector", 'max by (collector_name) (opentelemetry_allocator_targets_per_collector{service="otelcol-ds-targetallocator"})', "short"),
            ("Target allocator: unassigned targets", 'sum(opentelemetry_allocator_targets_unassigned{service="otelcol-ds-targetallocator"})', "short"),
            ("Target allocator: collectors discovered", 'max(opentelemetry_allocator_collectors_discovered{service="otelcol-ds-targetallocator"})', "short"),
        ],
        False,
        False,
    ),
    "victoria-metrics": (
        "VictoriaMetrics",
        "victoria-metrics",
        [
            ("Rows inserted/s by protocol", 'sum by (type) (rate(vm_rows_inserted_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Active time series", 'sum(vm_cache_entries{type="storage/hour_metric_ids", service_name=~"$svc"})', "short"),
            ("Data size on disk", 'sum by (type) (vm_data_size_bytes{service_name=~"$svc"})', "bytes"),
            ("Free disk space", 'min(vm_free_disk_space_bytes{service_name=~"$svc"})', "bytes"),
            ("HTTP requests/s by path", 'sum by (path) (rate(vm_http_requests_total{service_name=~"$svc"}[5m]))', "reqps"),
            ("HTTP request errors/s", 'sum by (path) (rate(vm_http_request_errors_total{service_name=~"$svc"}[5m]))', "reqps"),
            ("Slow inserts / ignored rows", 'sum(rate(vm_slow_row_inserts_total{service_name=~"$svc"}[5m]))', "ops"),
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


# ── Resource-efficiency dashboards ──────────────────────────────────────────
# Sources: cAdvisor series (container_*; labels namespace/pod/container) from
# the kubelet-cadvisor job, requests/limits from the otelcol-cluster
# k8s_cluster receiver (k8s_container_*; labels k8s_namespace_name,
# k8s_pod_name, k8s_container_name) and the vpa-monitoring exporter
# (kube_customresource_vpa_*). Everything is joined on (namespace, workload,
# container); the workload is the pod name with its controller suffix removed
# (ReplicaSet hash, DaemonSet suffix or StatefulSet ordinal). Values are the
# busiest replica ("max by") so they compare directly with per-pod requests.
POD_SUFFIX = r"-[a-z0-9]{8,10}-[a-z0-9]{5}|-[a-z0-9]{5}|-[0-9]+"
WORKLOAD_RE = r"^(.+?)(" + POD_SUFFIX + r")$"
BY = "namespace, workload, container"


def wl(expr, pod="pod"):
    """Add a workload label: the pod name, minus its controller suffix when it has one."""
    return (
        f'label_replace(label_replace({expr}, "workload", "$1", "{pod}", "(.+)"), '
        f'"workload", "$1", "{pod}", "{WORKLOAD_RE}")'
    )


def kside(expr):
    """Rename the k8s_cluster receiver's labels to the cAdvisor names."""
    return (
        'label_replace(label_replace(label_replace('
        f'{expr}, "namespace", "$1", "k8s_namespace_name", "(.+)"), '
        '"pod", "$1", "k8s_pod_name", "(.+)"), '
        '"container", "$1", "k8s_container_name", "(.+)")'
    )


def per_pod_max(expr):
    return f"max by ({BY}) ({wl(expr)})"


NS = 'namespace=~"$ns"'
KNS = 'k8s_namespace_name=~"$ns"'
CPU_USE = per_pod_max(f"rate(container_cpu_usage_seconds_total{{{NS}}}[5m])")
CPU_P95 = f"quantile_over_time(0.95, ({CPU_USE})[$window:5m])"
MEM_PEAK = f"max_over_time(({per_pod_max(f'container_memory_working_set_bytes{{{NS}}}')})[$window:5m])"
CPU_REQ = per_pod_max(kside(f"k8s_container_cpu_request{{{KNS}}}"))
CPU_LIM = per_pod_max(kside(f"k8s_container_cpu_limit{{{KNS}}}"))
MEM_REQ = per_pod_max(kside(f"k8s_container_memory_request_bytes{{{KNS}}}"))
MEM_LIM = per_pod_max(kside(f"k8s_container_memory_limit_bytes{{{KNS}}}"))


def vpa(metric):
    return (
        f"max by ({BY}) (label_replace(label_replace({metric}{{exported_namespace=~\"$ns\"}}, "
        '"namespace", "$1", "exported_namespace", "(.+)"), "workload", "$1", "target_name", "(.+)"))'
    )


THROTTLE = (
    f"sum by ({BY}) ({wl(f'increase(container_cpu_cfs_throttled_periods_total{{{NS}}}[$window])')})"
    f" / sum by ({BY}) ({wl(f'increase(container_cpu_cfs_periods_total{{{NS}}}[$window])')})"
)
OOMS = f"sum by ({BY}) ({wl(f'increase(container_oom_events_total{{{NS}}}[$window])')})"
RESTARTS = f"sum by ({BY}) ({wl(kside(f'increase(k8s_container_restarts{{{KNS}}}[$window])'))})"


def ratio(a, b):
    return f"({a}) / on({BY}) ({b})"


def table(idx, title, queries, y, w=24, h=12, overrides=None, description=""):
    """Instant-query table; queries = [(column name, expr, unit)], merged on the label columns."""
    refs = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    rename = {"namespace": "Namespace", "workload": "Workload", "container": "Container"}
    ov = []
    for i, (col, _, unit) in enumerate(queries):
        rename[f"Value #{refs[i]}"] = col
        ov.append({"matcher": {"id": "byName", "options": col}, "properties": [{"id": "unit", "value": unit}]})
    return {
        "id": idx,
        "type": "table",
        "title": title,
        "description": description,
        "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": 0, "y": y},
        "fieldConfig": {"defaults": {}, "overrides": ov + (overrides or [])},
        "options": {"showHeader": True, "footer": {"show": False}},
        "targets": [
            {"datasource": DS, "expr": e, "format": "table", "instant": True, "refId": refs[i], "legendFormat": ""}
            for i, (_, e, _) in enumerate(queries)
        ],
        "transformations": [
            {"id": "merge", "options": {}},
            {
                "id": "organize",
                "options": {
                    "excludeByName": {"Time": True},
                    "renameByName": rename,
                    "indexByName": {"Namespace": 0, "Workload": 1, "Container": 2},
                },
            },
        ],
    }


def color_scale(col, steps, invert=False):
    """Colour a column by thresholds; steps = [(value, colour)] with the first value None."""
    return {
        "matcher": {"id": "byName", "options": col},
        "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in steps]}},
        ],
    }


def variables(extra=None):
    ns = {
        "name": "ns", "label": "Namespace", "type": "query", "datasource": DS,
        "query": {"query": "label_values(container_cpu_usage_seconds_total, namespace)", "refId": "ns"},
        "refresh": 2, "includeAll": True, "multi": True, "allValue": ".*",
        "current": {"selected": True, "text": "All", "value": "$__all"},
    }
    window = {
        "name": "window", "label": "History", "type": "custom",
        "query": "1h,6h,1d,3d,7d,14d", "multi": False, "includeAll": False,
        "current": {"selected": True, "text": "7d", "value": "7d"},
        "options": [{"text": v, "value": v, "selected": v == "7d"} for v in "1h 6h 1d 3d 7d 14d".split()],
    }
    return [ns, window] + (extra or [])


def raw_dashboard(uid, title, panels, templating, description=""):
    return {
        "uid": uid, "title": title, "description": description,
        "tags": ["core-infra", "generated", "efficiency"], "schemaVersion": 39, "version": 1, "editable": False,
        "time": {"from": "now-6h", "to": "now"}, "refresh": "5m",
        "templating": {"list": templating}, "panels": panels,
    }


def ts(idx, title, targets, unit, x, y, w=12, h=8, stack=False):
    """Time series with several (legend, expr) targets."""
    refs = "ABCDEFGH"
    return {
        "id": idx, "type": "timeseries", "title": title, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
        "targets": [
            {"datasource": DS, "expr": e, "legendFormat": leg, "refId": refs[i]} for i, (leg, e) in enumerate(targets)
        ],
    }


def efficiency_dashboards():
    util_ok = [(None, "red"), (0.2, "yellow"), (0.5, "green")]
    throttle = [(None, "green"), (0.05, "yellow"), (0.25, "red")]
    # 1. Allocation efficiency: one row per container
    main_table = table(
        3,
        "Allocation vs usage per container (busiest replica)",
        [
            ("CPU request", CPU_REQ, "short"),
            ("CPU p95 usage", CPU_P95, "short"),
            ("CPU used / request", ratio(CPU_P95, CPU_REQ), "percentunit"),
            ("CPU limit", CPU_LIM, "short"),
            ("CPU throttled", THROTTLE, "percentunit"),
            ("Mem request", MEM_REQ, "bytes"),
            ("Mem peak", MEM_PEAK, "bytes"),
            ("Mem peak / request", ratio(MEM_PEAK, MEM_REQ), "percentunit"),
            ("Mem limit", MEM_LIM, "bytes"),
            ("OOM kills", OOMS, "short"),
            ("Restarts", RESTARTS, "short"),
            ("VPA CPU target", vpa("kube_customresource_vpa_containerrecommendations_target_cpu_cores"), "short"),
            ("VPA mem target", vpa("kube_customresource_vpa_containerrecommendations_target_memory_bytes"), "bytes"),
        ],
        y=8,
        h=18,
        overrides=[
            color_scale("CPU used / request", util_ok),
            color_scale("Mem peak / request", util_ok),
            color_scale("CPU throttled", throttle),
        ],
        description=(
            "One row per workload container, comparing the busiest replica's usage over the History window with "
            "its request/limit and the VPA target. Low 'used / request' means over-allocated; throttling, OOM kills "
            "or restarts mean trimming is NOT safe. Rows with no request/limit appear in the Allocation gaps dashboard."
        ),
    )
    top = [
        ts(1, "Cluster CPU: allocatable vs requested vs used", [
            ("allocatable", 'sum(k8s_node_allocatable_cpu)'),
            ("requested", f'sum(sum by ({BY}) ({wl(kside("k8s_container_cpu_request"))}))'),
            ("used", 'sum(rate(container_cpu_usage_seconds_total{container!=""}[5m]))'),
        ], "short", 0, 0),
        ts(2, "Cluster memory: allocatable vs requested vs used", [
            ("allocatable", 'sum(k8s_node_allocatable_memory_bytes)'),
            ("requested", f'sum(sum by ({BY}) ({wl(kside("k8s_container_memory_request_bytes"))}))'),
            ("used (working set)", 'sum(container_memory_working_set_bytes{container!=""})'),
        ], "bytes", 12, 0),
    ]
    efficiency = raw_dashboard(
        "core-infra-resource-efficiency", "Resource efficiency: allocation vs usage", top + [main_table], variables(),
        "Requests, limits, usage, throttling and VPA targets for every container.",
    )

    # 2. Gaps: containers with no request / limit, with a suggested value
    def gap(idx, title, have, missing_ref, suggestion, unit, y):
        return table(
            idx, title,
            [("Usage (p95/peak)", have, unit), ("Suggested", suggestion, unit)],
            y=y, h=9,
            description="Containers that run without this setting. Suggested = observed usage over the History window plus headroom.",
        )

    gaps = [
        gap(1, "Containers with no CPU request",
            f"({CPU_P95}) unless on({BY}) ({CPU_REQ})", "", f"(({CPU_P95}) unless on({BY}) ({CPU_REQ})) * 1.15", "short", 4),
        gap(2, "Containers with no memory request",
            f"({MEM_PEAK}) unless on({BY}) ({MEM_REQ})", "", f"(({MEM_PEAK}) unless on({BY}) ({MEM_REQ})) * 1.1", "bytes", 13),
        gap(3, "Containers with no memory limit",
            f"({MEM_PEAK}) unless on({BY}) ({MEM_LIM})", "", f"(({MEM_PEAK}) unless on({BY}) ({MEM_LIM})) * 1.25", "bytes", 22),
        {
            "id": 4, "type": "text", "title": "Where to set them", "gridPos": {"h": 4, "w": 24, "x": 0, "y": 0},
            "options": {"mode": "markdown", "content": (
                "Not every gap is fixed in an app manifest. **Calico** workloads (calico-node, typha, kube-controllers, "
                "whisker, goldmane) are managed by the tigera-operator: set resources on the `Installation` / component "
                "resources. **Envoy gateway proxies** take them from the `EnvoyProxy` resource. **Control-plane static pods** "
                "(kube-apiserver, scheduler, controller-manager) come from the Talos machine config. Suggestions need "
                "several days of history to be meaningful; a CPU limit is deliberately not suggested."
            )},
        },
    ]
    gaps_dash = raw_dashboard(
        "core-infra-allocation-gaps", "Resource efficiency: allocation gaps", gaps, variables(),
        "Containers with no request or limit, with suggested values from observed usage.",
    )

    # 3. Trim safety for one workload: allocation vs usage next to the golden signals
    wvar = {
        "name": "workload", "label": "Workload", "type": "query", "datasource": DS,
        "query": {"query": 'label_values(container_memory_working_set_bytes{namespace=~"$ns"}, pod)', "refId": "workload"},
        "regex": "/^(.+?)(?:" + POD_SUFFIX + ")?$/", "refresh": 2, "includeAll": False, "multi": False,
        "current": {"selected": True, "text": "grafana", "value": "grafana"},
    }
    P = f'pod=~"$workload({POD_SUFFIX})?"'
    KP = f'k8s_pod_name=~"$workload({POD_SUFFIX})?"'
    use_cpu = f'max(rate(container_cpu_usage_seconds_total{{{NS}, {P}, container!=""}}[5m]))'
    use_mem = f'max(container_memory_working_set_bytes{{{NS}, {P}, container!=""}})'
    cpu_total = f'sum(rate(container_cpu_usage_seconds_total{{{NS}, {P}, container!=""}}[5m]))'
    mem_total = f'sum(container_memory_working_set_bytes{{{NS}, {P}, container!=""}})'
    work = f'sum(rate(controller_runtime_reconcile_total{{{NS}, {P}}}[5m]))'
    safety = [
        ts(1, "CPU per replica: usage vs request, limit, VPA", [
            ("usage (busiest replica)", use_cpu),
            ("request", f'max(k8s_container_cpu_request{{{KNS}, {KP}}})'),
            ("limit", f'max(k8s_container_cpu_limit{{{KNS}, {KP}}})'),
            ("VPA target", f'max(kube_customresource_vpa_containerrecommendations_target_cpu_cores{{exported_namespace=~"$ns", target_name="$workload"}})'),
        ], "short", 0, 0),
        ts(2, "Memory per replica: working set vs request, limit, VPA", [
            ("working set (busiest replica)", use_mem),
            ("request", f'max(k8s_container_memory_request_bytes{{{KNS}, {KP}}})'),
            ("limit", f'max(k8s_container_memory_limit_bytes{{{KNS}, {KP}}})'),
            ("VPA target", f'max(kube_customresource_vpa_containerrecommendations_target_memory_bytes{{exported_namespace=~"$ns", target_name="$workload"}})'),
        ], "bytes", 12, 0),
        ts(3, "CPU throttling (share of periods throttled)", [
            ("throttled", f'sum(rate(container_cpu_cfs_throttled_periods_total{{{NS}, {P}}}[5m])) / sum(rate(container_cpu_cfs_periods_total{{{NS}, {P}}}[5m]))'),
        ], "percentunit", 0, 8),
        ts(4, "OOM kills and restarts (per hour)", [
            ("OOM kills", f'sum(increase(container_oom_events_total{{{NS}, {P}}}[1h]))'),
            ("restarts", f'sum(increase(k8s_container_restarts{{{KNS}, {KP}}}[1h]))'),
        ], "short", 12, 8),
        ts(5, "Work: reconciles/s and error share (controller-runtime apps)", [
            ("reconciles/s", work),
            ("errors/s", f'sum(rate(controller_runtime_reconcile_errors_total{{{NS}, {P}}}[5m]))'),
        ], "ops", 0, 16),
        ts(6, "Latency and queue: reconcile p95, workqueue depth", [
            ("reconcile p95 (s)", f'histogram_quantile(0.95, sum by (le) (rate(controller_runtime_reconcile_time_seconds_bucket{{{NS}, {P}}}[5m])))'),
            ("workqueue depth", f'sum(workqueue_depth{{{NS}, {P}}})'),
        ], "short", 12, 16),
        ts(7, "Work per CPU core (reconciles per core-second)", [
            ("reconciles / core-s", f"{work} / {cpu_total}"),
        ], "short", 0, 24),
        ts(8, "Work per GiB of memory (reconciles/s per GiB working set)", [
            ("reconciles/s per GiB", f"{work} / ({mem_total} / 1073741824)"),
        ], "short", 12, 24),
        ts(9, "HTTP traffic (Envoy gateway proxies): requests/s and 5xx/s", [
            ("requests/s", f'sum(rate(envoy_http_downstream_rq_total{{{NS}, {P}}}[5m]))'),
            ("5xx/s", f'sum(rate(envoy_http_downstream_rq_total{{{NS}, {P}, envoy_response_code_class="5"}}[5m]))'),
        ], "reqps", 0, 32),
    ]
    safety_dash = raw_dashboard(
        "core-infra-trim-safety", "Resource efficiency: trim safety for a workload", safety, variables([wvar]),
        "Allocation next to the golden signals: before lowering a request, check there is no throttling, OOM, "
        "restart, error or latency regression and that usage sits well below the request.",
    )
    return {
        "resource-efficiency": efficiency,
        "allocation-gaps": gaps_dash,
        "trim-safety": safety_dash,
    }


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.json"):
        old.unlink()
    files = []
    for slug, (title, svc_regex, panels, ctrl, *rest) in APPS.items():
        common = rest[0] if rest else True
        allp = list(panels) + (CONTROLLER_RUNTIME if ctrl else []) + (COMMON if common else [])
        d = dashboard(f"core-infra-{slug}", title, allp, svc_regex)
        (OUT / f"{slug}.json").write_text(json.dumps(d, indent=2) + "\n")
        files.append(f"{slug}.json")
    d = dashboard("core-infra-nodes", NODES[0], NODES[1])
    (OUT / "nodes.json").write_text(json.dumps(d, indent=2) + "\n")
    files.append("nodes.json")
    for slug, d in efficiency_dashboards().items():
        (OUT / f"{slug}.json").write_text(json.dumps(d, indent=2) + "\n")
        files.append(f"{slug}.json")

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
