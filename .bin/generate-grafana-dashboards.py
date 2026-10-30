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

COMMON_NO_FDS = [c for c in COMMON if "process_open_fds" not in c[1]]

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
        "otelcol-k8s|otelcol-cluster",
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
    # ── Kubernetes control plane, CoreDNS and kubelets (scraped by otelcol-ds) ──
    "kube-apiserver": (
        "Kubernetes API server",
        "kube-apiserver",
        [
            ("Requests/s by verb", 'sum by (verb) (rate(apiserver_request_total{service_name=~"$svc"}[5m]))', "reqps"),
            ("Server errors (5xx) per second by code", 'sum by (code) (rate(apiserver_request_total{service_name=~"$svc", code=~"5.."}[5m]))', "reqps"),
            ("5xx share of requests", 'sum(rate(apiserver_request_total{service_name=~"$svc", code=~"5.."}[5m])) / sum(rate(apiserver_request_total{service_name=~"$svc"}[5m]))', "percentunit"),
            ("Client errors (4xx excl. 404/409) per second", 'sum by (code) (rate(apiserver_request_total{service_name=~"$svc", code=~"4..", code!~"404|409"}[5m]))', "reqps"),
            # The collector keeps only the 0.1/0.4/1/5 SLI buckets (and drops ones identical to the previous),
            # so quantiles are approximate; "within 400ms" is exact.
            ("Request latency p99, excl. WATCH/CONNECT (approximate)", 'histogram_quantile(0.99, sum by (le) (rate(apiserver_request_sli_duration_seconds_bucket{service_name=~"$svc", verb!~"WATCH|CONNECT"}[5m])))', "s"),
            ("Share of requests served within 400ms", 'sum(rate(apiserver_request_sli_duration_seconds_bucket{service_name=~"$svc", verb!~"WATCH|CONNECT", le="0.4"}[5m])) / sum(rate(apiserver_request_sli_duration_seconds_count{service_name=~"$svc", verb!~"WATCH|CONNECT"}[5m]))', "percentunit"),
            ("Average latency by verb (excl. WATCH/CONNECT)", 'sum by (verb) (rate(apiserver_request_sli_duration_seconds_sum{service_name=~"$svc", verb!~"WATCH|CONNECT"}[5m])) / sum by (verb) (rate(apiserver_request_sli_duration_seconds_count{service_name=~"$svc", verb!~"WATCH|CONNECT"}[5m]))', "s"),
            ("In-flight requests", 'sum by (request_kind, k8s_node_name) (apiserver_current_inflight_requests{service_name=~"$svc"})', "short"),
            ("Flow control: executing requests by priority level", 'sum by (priority_level) (apiserver_flowcontrol_current_executing_requests{service_name=~"$svc"})', "short"),
            ("Flow control: queued requests by priority level", 'sum by (priority_level) (apiserver_flowcontrol_current_inqueue_requests{service_name=~"$svc"})', "short"),
            ("Flow control: average queue wait", 'sum by (priority_level) (rate(apiserver_flowcontrol_request_wait_duration_seconds_sum{service_name=~"$svc"}[5m])) / sum by (priority_level) (rate(apiserver_flowcontrol_request_wait_duration_seconds_count{service_name=~"$svc"}[5m]))', "s"),
            ("etcd requests/s by operation (API server client)", 'sum by (operation) (rate(etcd_request_duration_seconds_count{service_name=~"$svc"}[5m]))', "ops"),
            ("etcd request average latency by operation", 'sum by (operation) (rate(etcd_request_duration_seconds_sum{service_name=~"$svc"}[5m])) / sum by (operation) (rate(etcd_request_duration_seconds_count{service_name=~"$svc"}[5m]))', "s"),
            ("etcd request errors/s", 'sum by (operation) (rate(etcd_request_errors_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Storage size (etcd database as seen by the API server)", 'max(apiserver_storage_size_bytes{service_name=~"$svc"})', "bytes"),
            ("Admission webhook requests/s by name and result", 'sum by (name, rejected) (rate(apiserver_admission_webhook_request_total{service_name=~"$svc"}[5m]))', "reqps"),
            ("KMS plugin operations/s (Barbican)", 'sum by (method_name, grpc_status_code) (rate(apiserver_envelope_encryption_kms_operations_latency_seconds_count{service_name=~"$svc"}[5m]))', "ops"),
            ("KMS plugin average latency", 'sum by (method_name) (rate(apiserver_envelope_encryption_kms_operations_latency_seconds_sum{service_name=~"$svc"}[5m])) / sum by (method_name) (rate(apiserver_envelope_encryption_kms_operations_latency_seconds_count{service_name=~"$svc"}[5m]))', "s"),
            ("Secret decryption key cache fill", 'max by (k8s_node_name) (apiserver_envelope_encryption_dek_cache_fill_percent{service_name=~"$svc"})', "percent"),
            ("TLS handshake errors/s", 'sum by (k8s_node_name) (rate(apiserver_tls_handshake_errors_total{service_name=~"$svc"}[5m]))', "ops"),
        ],
        False,
    ),
    "etcd": (
        "etcd",
        "etcd",
        [
            ("Members with a leader (want all)", 'min(etcd_server_has_leader{service_name=~"$svc"})', "short"),
            ("Leader (1 = this member leads)", 'etcd_server_is_leader{service_name=~"$svc"}', "short"),
            ("Leader changes in the last hour", 'sum(increase(etcd_server_leader_changes_seen_total{service_name=~"$svc"}[1h]))', "short"),
            ("Database size vs in use", 'etcd_mvcc_db_total_size_in_bytes{service_name=~"$svc"}', "bytes"),
            ("Database size as share of the backend quota", 'etcd_mvcc_db_total_size_in_bytes{service_name=~"$svc"} / etcd_server_quota_backend_bytes{service_name=~"$svc"}', "percentunit"),
            ("Database bytes in use", 'etcd_mvcc_db_total_size_in_use_in_bytes{service_name=~"$svc"}', "bytes"),
            ("WAL fsync p99 (disk latency; want < 10ms; approximate, bucketed)", 'histogram_quantile(0.99, sum by (le) (rate(etcd_disk_wal_fsync_duration_seconds_bucket{service_name=~"$svc"}[5m])))', "s"),
            ("Backend commit p99 (want < 25ms; approximate, bucketed)", 'histogram_quantile(0.99, sum by (le) (rate(etcd_disk_backend_commit_duration_seconds_bucket{service_name=~"$svc"}[5m])))', "s"),
            ("Proposals committed/s", 'sum by (k8s_node_name) (rate(etcd_server_proposals_committed_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Proposals failed/s (want 0)", 'sum by (k8s_node_name) (rate(etcd_server_proposals_failed_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Slow applies and slow read indexes per second", 'sum(rate(etcd_server_slow_apply_total{service_name=~"$svc"}[5m])) + sum(rate(etcd_server_slow_read_indexes_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Peer round-trip time (average)", 'sum by (k8s_node_name) (rate(etcd_network_peer_round_trip_time_seconds_sum{service_name=~"$svc"}[5m])) / sum by (k8s_node_name) (rate(etcd_network_peer_round_trip_time_seconds_count{service_name=~"$svc"}[5m]))', "s"),
            ("Active peers", 'etcd_network_active_peers{service_name=~"$svc"}', "short"),
            ("Heartbeat send failures and health failures (increase over 1h)", 'sum(increase(etcd_server_heartbeat_send_failures_total{service_name=~"$svc"}[1h])) + sum(increase(etcd_server_health_failures_total{service_name=~"$svc"}[1h]))', "short"),
        ],
        False,
    ),
    "kube-scheduler": (
        "Kubernetes scheduler",
        "kube-scheduler",
        [
            ("Pending pods by queue", 'sum by (queue) (scheduler_pending_pods{service_name=~"$svc"})', "short"),
            ("Unschedulable pods", 'sum(scheduler_unschedulable_pods{service_name=~"$svc"})', "short"),
            ("Scheduling attempts/s by result", 'sum by (result) (rate(scheduler_schedule_attempts_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Scheduling attempt duration (average)", 'sum(rate(scheduler_scheduling_attempt_duration_seconds_sum{service_name=~"$svc"}[5m])) / sum(rate(scheduler_scheduling_attempt_duration_seconds_count{service_name=~"$svc"}[5m]))', "s"),
            ("Time from queue to scheduled (SLI, average)", 'sum(rate(scheduler_pod_scheduling_sli_duration_seconds_sum{service_name=~"$svc"}[15m])) / sum(rate(scheduler_pod_scheduling_sli_duration_seconds_count{service_name=~"$svc"}[15m]))', "s"),
            ("Attempts needed per pod (average)", 'sum(rate(scheduler_pod_scheduling_attempts_sum{service_name=~"$svc"}[15m])) / sum(rate(scheduler_pod_scheduling_attempts_count{service_name=~"$svc"}[15m]))', "short"),
            ("Pods entering the queue per second by event", 'sum by (event) (rate(scheduler_queue_incoming_pods_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Preemption attempts per hour", 'sum(increase(scheduler_preemption_attempts_total{service_name=~"$svc"}[1h]))', "short"),
            ("Leader (1 = this scheduler leads)", 'max by (k8s_node_name) (leader_election_master_status{service_name=~"$svc"})', "short"),
        ],
        False,
        COMMON_NO_FDS,
    ),
    "kube-controller-manager": (
        "Kubernetes controller-manager",
        "kube-controller-manager",
        [
            ("Workqueue depth, deepest 10 controllers", 'topk(10, sum by (name) (workqueue_depth{service_name=~"$svc"}))', "short"),
            ("Items added per second, busiest 10 controllers", 'topk(10, sum by (name) (rate(workqueue_adds_total{service_name=~"$svc"}[5m])))', "ops"),
            ("Retries per second, top 10 controllers", 'topk(10, sum by (name) (rate(workqueue_retries_total{service_name=~"$svc"}[5m])))', "ops"),
            ("Time items wait in the queue, slowest 10 (average)", 'topk(10, sum by (name) (rate(workqueue_queue_duration_seconds_sum{service_name=~"$svc"}[5m])) / sum by (name) (rate(workqueue_queue_duration_seconds_count{service_name=~"$svc"}[5m])))', "s"),
            ("Time spent per item, slowest 10 (average)", 'topk(10, sum by (name) (rate(workqueue_work_duration_seconds_sum{service_name=~"$svc"}[5m])) / sum by (name) (rate(workqueue_work_duration_seconds_count{service_name=~"$svc"}[5m])))', "s"),
            ("Longest running processor, top 10", 'topk(10, max by (name) (workqueue_longest_running_processor_seconds{service_name=~"$svc"}))', "s"),
            ("Unfinished work, top 10", 'topk(10, sum by (name) (workqueue_unfinished_work_seconds{service_name=~"$svc"}))', "s"),
            ("Node lifecycle: evictions per hour by zone", 'sum by (zone) (increase(node_collector_evictions_total{service_name=~"$svc"}[1h]))', "short"),
            ("Node lifecycle: unhealthy nodes by zone", 'max by (zone) (node_collector_unhealthy_nodes_in_zone{service_name=~"$svc"})', "short"),
            ("Garbage collector sync errors per hour", 'sum(increase(garbagecollector_controller_resources_sync_error_total{service_name=~"$svc"}[1h]))', "short"),
            ("Leader (1 = this controller-manager leads)", 'max by (k8s_node_name) (leader_election_master_status{service_name=~"$svc"})', "short"),
        ],
        False,
        COMMON_NO_FDS,
    ),
    "coredns": (
        "CoreDNS",
        "kube-dns",
        [
            ("Queries/s by type", 'sum by (type) (rate(coredns_dns_requests_total{service_name=~"$svc"}[5m]))', "reqps"),
            ("Responses/s by rcode", 'sum by (rcode) (rate(coredns_dns_responses_total{service_name=~"$svc"}[5m]))', "reqps"),
            ("SERVFAIL share of responses", 'sum(rate(coredns_dns_responses_total{service_name=~"$svc", rcode="SERVFAIL"}[5m])) / sum(rate(coredns_dns_responses_total{service_name=~"$svc"}[5m]))', "percentunit"),
            ("Request latency p99", 'histogram_quantile(0.99, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket{service_name=~"$svc"}[5m])))', "s"),
            ("Request latency (average)", 'sum(rate(coredns_dns_request_duration_seconds_sum{service_name=~"$svc"}[5m])) / sum(rate(coredns_dns_request_duration_seconds_count{service_name=~"$svc"}[5m]))', "s"),
            ("Cache hit ratio", 'sum(rate(coredns_cache_hits_total{service_name=~"$svc"}[5m])) / sum(rate(coredns_cache_requests_total{service_name=~"$svc"}[5m]))', "percentunit"),
            ("Cache entries", 'sum by (type) (coredns_cache_entries{service_name=~"$svc"})', "short"),
            ("Upstream forwarding: broken health checks per hour", 'sum(increase(coredns_forward_healthcheck_broken_total{service_name=~"$svc"}[1h]))', "short"),
            ("Kubernetes DNS programming latency p99 (time for Service changes to reach DNS)", 'histogram_quantile(0.99, sum by (le) (rate(coredns_kubernetes_dns_programming_duration_seconds_bucket{service_name=~"$svc"}[15m])))', "s"),
        ],
        False,
    ),
    "kubelet": (
        "Kubelet (per node)",
        "kubelet",
        [
            ("Running pods per node", 'sum by (k8s_node_name) (kubelet_running_pods{service_name=~"$svc"})', "short"),
            ("Running containers per node", 'sum by (k8s_node_name) (kubelet_running_containers{service_name=~"$svc"})', "short"),
            ("Pod start latency (average, SLI)", 'sum by (k8s_node_name) (rate(kubelet_pod_start_sli_duration_seconds_sum{service_name=~"$svc"}[15m])) / sum by (k8s_node_name) (rate(kubelet_pod_start_sli_duration_seconds_count{service_name=~"$svc"}[15m]))', "s"),
            ("PLEG relist duration (average; high = node trouble)", 'sum by (k8s_node_name) (rate(kubelet_pleg_relist_duration_seconds_sum{service_name=~"$svc"}[5m])) / sum by (k8s_node_name) (rate(kubelet_pleg_relist_duration_seconds_count{service_name=~"$svc"}[5m]))', "s"),
            ("PLEG relist interval (average; expected ~1s)", 'sum by (k8s_node_name) (rate(kubelet_pleg_relist_interval_seconds_sum{service_name=~"$svc"}[5m])) / sum by (k8s_node_name) (rate(kubelet_pleg_relist_interval_seconds_count{service_name=~"$svc"}[5m]))', "s"),
            ("Container runtime operation errors/s", 'sum by (operation_type) (rate(kubelet_runtime_operations_errors_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Container runtime operations/s", 'sum by (operation_type) (rate(kubelet_runtime_operations_total{service_name=~"$svc"}[5m]))', "ops"),
            ("Container runtime operation latency (average)", 'sum by (operation_type) (rate(kubelet_runtime_operations_duration_seconds_sum{service_name=~"$svc"}[5m])) / sum by (operation_type) (rate(kubelet_runtime_operations_duration_seconds_count{service_name=~"$svc"}[5m]))', "s"),
            ("Image pull duration (average)", 'sum by (k8s_node_name) (rate(kubelet_image_pull_duration_seconds_sum{service_name=~"$svc"}[15m])) / sum by (k8s_node_name) (rate(kubelet_image_pull_duration_seconds_count{service_name=~"$svc"}[15m]))', "s"),
            ("Pod and container start errors per hour", 'sum(increase(kubelet_started_pods_errors_total{service_name=~"$svc"}[1h])) + sum(increase(kubelet_started_containers_errors_total{service_name=~"$svc"}[1h]))', "short"),
            ("Persistent volume usage", 'max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes{service_name=~"$svc"} / kubelet_volume_stats_capacity_bytes{service_name=~"$svc"})', "percentunit"),
            ("Persistent volume free space", 'min by (namespace, persistentvolumeclaim) (kubelet_volume_stats_available_bytes{service_name=~"$svc"})', "bytes"),
            ("Persistent volume free inodes", 'min by (namespace, persistentvolumeclaim) (kubelet_volume_stats_inodes_free{service_name=~"$svc"} / kubelet_volume_stats_inodes{service_name=~"$svc"})', "percentunit"),
            ("Kubelet serving certificate: days until expiry", 'min by (k8s_node_name) (kubelet_certificate_manager_server_ttl_seconds{service_name=~"$svc"}) / 86400', "d"),
        ],
        False,
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


# ── Minecraft servers ───────────────────────────────────────────────────────
# Two exporters share the namespace/minecraft job (applications/minecraft/base/
# resources/podmonitor.yaml): TickScope inside the server (mc_*; Paper 1.21,
# metric names from TickScope 2.x) and the mc-monitor status-ping sidecar
# (minecraft_status_*, outside-in). One namespace per instance, so the
# `instance` variable is the namespace label. Container CPU/memory come from
# cAdvisor (same series as the efficiency dashboards).
MC = 'namespace=~"$instance"'
MC_CONTAINER = f'{MC}, container!=""'


def stat(idx, title, expr, unit, x, y, w=4, h=4, steps=None, mappings=None, decimals=None):
    defaults = {
        "unit": unit,
        "color": {"mode": "thresholds"},
        "thresholds": {"mode": "absolute", "steps": steps or [{"color": "green", "value": None}]},
    }
    if mappings:
        defaults["mappings"] = mappings
    if decimals is not None:
        defaults["decimals"] = decimals
    return {
        "id": idx, "type": "stat", "title": title, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": "background", "graphMode": "none", "textMode": "auto",
        },
        "targets": [{"datasource": DS, "expr": expr, "refId": "A"}],
    }


def minecraft_dashboard():
    inst = {
        "name": "instance", "label": "Instance", "type": "query", "datasource": DS,
        "query": {"query": "label_values(mc_players_online, namespace)", "refId": "instance"},
        "refresh": 2, "includeAll": True, "multi": True, "allValue": ".*",
        "current": {"selected": True, "text": "All", "value": "$__all"},
    }
    ok_bad = [{"color": "red", "value": None}, {"color": "green", "value": 1}]
    tps = [{"color": "red", "value": None}, {"color": "orange", "value": 15}, {"color": "green", "value": 19}]
    mspt = [{"color": "green", "value": None}, {"color": "orange", "value": 0.04}, {"color": "red", "value": 0.05}]
    up_map = [{"type": "value", "options": {"0": {"text": "DOWN"}, "1": {"text": "UP"}}}]
    panels = [
        # Row 1: at-a-glance (y=0)
        stat(1, "Status ping", f'min(minecraft_status_healthy{{{MC}}})', "none", 0, 0, steps=ok_bad, mappings=up_map),
        stat(2, "Players online", f'sum(mc_players_online{{{MC}}})', "short", 4, 0),
        stat(3, "TPS (1m, worst)", f'min(mc_tps{{{MC}, window="1m"}})', "short", 8, 0, steps=tps, decimals=1),
        stat(4, "Tick time p95 (worst)", f'max(mc_tick_duration_seconds{{{MC}, statistic="p95"}})', "s", 12, 0, steps=mspt, decimals=3),
        stat(5, "Heap used", f'max(mc_jvm_memory_used_bytes{{{MC}, area="heap"}} / mc_jvm_memory_max_bytes{{{MC}, area="heap"}})', "percentunit", 16, 0,
             steps=[{"color": "green", "value": None}, {"color": "orange", "value": 0.8}, {"color": "red", "value": 0.92}]),
        stat(6, "Uptime", f'min(mc_uptime_seconds{{{MC}}})', "s", 20, 0),
        # Players and status (y=4)
        ts(7, "Players online vs max", [("online {{namespace}}", f'sum by (namespace) (mc_players_online{{{MC}}})'),
                                        ("max {{namespace}}", f'max by (namespace) (mc_players_max{{{MC}}})')], "short", 0, 4),
        ts(8, "Status ping latency", [("{{namespace}}", f'max by (namespace) (minecraft_status_response_time_seconds{{{MC}}})')], "s", 12, 4),
        # Tick health (y=12)
        ts(9, "TPS", [("{{namespace}} {{window}}", f'min by (namespace, window) (mc_tps{{{MC}}})')], "short", 0, 12),
        ts(10, "Tick duration", [("{{namespace}} {{statistic}}", f'max by (namespace, statistic) (mc_tick_duration_seconds{{{MC}, statistic=~"p50|p95|p99|max"}})')], "s", 12, 12),
        # Worlds (y=20)
        ts(11, "Entities by world", [("{{namespace}} {{world}}", f'sum by (namespace, world) (mc_world_entities{{{MC}}})'),
                                     ("tile {{namespace}} {{world}}", f'sum by (namespace, world) (mc_world_tile_entities{{{MC}}})')], "short", 0, 20),
        ts(12, "Loaded chunks and players by world", [("chunks {{namespace}} {{world}}", f'sum by (namespace, world) (mc_world_chunks{{{MC}}})'),
                                                      ("players {{namespace}} {{world}}", f'sum by (namespace, world) (mc_world_players{{{MC}}})')], "short", 12, 20),
        ts(13, "Top 10 entity types", [("{{type}}", f'topk(10, sum by (type) (mc_world_entities_by_type{{{MC}}}))')], "short", 0, 28),
        ts(14, "Player events/min", [("{{namespace}} {{event}}", f'sum by (namespace, event) (rate(mc_events_total{{{MC}}}[5m])) * 60')], "short", 12, 28),
        # JVM and process (y=36)
        ts(15, "JVM memory", [("heap used {{namespace}}", f'sum by (namespace) (mc_jvm_memory_used_bytes{{{MC}, area="heap"}})'),
                              ("heap committed {{namespace}}", f'sum by (namespace) (mc_jvm_memory_committed_bytes{{{MC}, area="heap"}})'),
                              ("heap max {{namespace}}", f'max by (namespace) (mc_jvm_memory_max_bytes{{{MC}, area="heap"}})'),
                              ("non-heap used {{namespace}}", f'sum by (namespace) (mc_jvm_memory_used_bytes{{{MC}, area="nonheap"}})')], "bytes", 0, 36),
        ts(16, "GC time and collections", [("time/s {{namespace}} {{gc}}", f'sum by (namespace, gc) (rate(mc_jvm_gc_seconds_total{{{MC}}}[5m]))'),
                                           ("collections/s {{namespace}} {{gc}}", f'sum by (namespace, gc) (rate(mc_jvm_gc_collections_total{{{MC}}}[5m]))')], "short", 12, 36),
        ts(17, "Server process CPU (cores) and load", [("process cores {{namespace}}", f'sum by (namespace) (rate(mc_process_cpu_seconds_total{{{MC}}}[5m]))'),
                                                       ("process load ratio {{namespace}}", f'max by (namespace) (mc_process_cpu_load_ratio{{{MC}}})')], "short", 0, 44),
        ts(18, "JVM threads", [("current {{namespace}}", f'sum by (namespace) (mc_jvm_threads_current{{{MC}}})'),
                               ("daemon {{namespace}}", f'sum by (namespace) (mc_jvm_threads_daemon{{{MC}}})')], "short", 12, 44),
        # Container (y=52)
        ts(19, "Container CPU (cores)", [("{{namespace}} {{container}}", f'sum by (namespace, container) (rate(container_cpu_usage_seconds_total{{{MC_CONTAINER}}}[5m]))'),
                                         ("throttled {{namespace}} {{container}}", f'sum by (namespace, container) (rate(container_cpu_cfs_throttled_seconds_total{{{MC_CONTAINER}}}[5m]))')], "short", 0, 52),
        ts(20, "Container memory (working set)", [("{{namespace}} {{container}}", f'max by (namespace, container) (container_memory_working_set_bytes{{{MC_CONTAINER}}})')], "bytes", 12, 52),
        # Exporter health (y=60)
        ts(21, "Player ping (ms)", [("{{namespace}} {{statistic}}", f'max by (namespace, statistic) (mc_player_ping_seconds{{{MC}}}) * 1000')], "ms", 0, 60),
        ts(22, "TickScope collection health", [("seconds since last success {{namespace}}", f'time() - max by (namespace) (mc_collection_last_success_timestamp_seconds{{{MC}}})'),
                                                ("failures/s {{namespace}}", f'sum by (namespace) (rate(mc_collection_failures_total{{{MC}}}[5m]))'),
                                                ("collection duration {{namespace}}", f'max by (namespace) (mc_collection_duration_seconds{{{MC}}})')], "short", 12, 60),
    ]
    d = raw_dashboard("core-infra-minecraft", "Minecraft servers", panels, [inst],
                      "Per-instance Minecraft health: TickScope (inside the server) plus mc-monitor status pings.")
    d["tags"] = ["core-infra", "generated", "minecraft"]
    d["refresh"] = "1m"
    return d


# ── CloudNativePG ───────────────────────────────────────────────────────────
# Operator metrics come from the chart PodMonitor (applications/cnpg/base,
# monitoring.podMonitorEnabled); instance metrics (cnpg_*) come from each
# Cluster's own PodMonitor (spec.monitoring.enablePodMonitor). The `cluster`
# variable is the pod's cnpg.io/cluster label as exposed by the target allocator.
CNPG_OP = 'namespace="cnpg-system"'
CNPG = 'namespace=~"$namespace", pod=~"$cluster-[0-9]+"'


def cnpg_dashboard():
    ns = {
        "name": "namespace", "label": "Namespace", "type": "query", "datasource": DS,
        "query": {"query": "label_values(cnpg_collector_up, namespace)", "refId": "namespace"},
        "refresh": 2, "includeAll": True, "multi": True, "allValue": ".*",
        "current": {"selected": True, "text": "All", "value": "$__all"},
    }
    cl = {
        "name": "cluster", "label": "Cluster", "type": "query", "datasource": DS,
        "query": {"query": 'label_values(cnpg_collector_up{namespace=~"$namespace"}, cluster)', "refId": "cluster"},
        "refresh": 2, "includeAll": True, "multi": True, "allValue": ".*",
        "current": {"selected": True, "text": "All", "value": "$__all"},
    }
    ok_bad = [{"color": "red", "value": None}, {"color": "green", "value": 1}]
    up_map = [{"type": "value", "options": {"0": {"text": "DOWN"}, "1": {"text": "UP"}}}]
    C = 'namespace=~"$namespace", cluster=~"$cluster"'
    panels = [
        # At a glance (y=0)
        stat(1, "Operator up", f'min(up{{{CNPG_OP}, job=~".*cloudnative-pg.*"}})', "none", 0, 0, steps=ok_bad, mappings=up_map),
        stat(2, "Instances up", f'sum(cnpg_collector_up{{{C}}})', "short", 4, 0),
        stat(3, "Instances down", f'count(cnpg_collector_up{{{C}}} == 0) or vector(0)', "short", 8, 0,
             steps=[{"color": "green", "value": None}, {"color": "red", "value": 1}]),
        stat(4, "Max replication lag", f'max(cnpg_pg_replication_lag{{{C}}})', "s", 12, 0, decimals=1,
             steps=[{"color": "green", "value": None}, {"color": "orange", "value": 5}, {"color": "red", "value": 30}]),
        stat(5, "Connections used", f'max(sum by (pod) (cnpg_backends_total{{{C}}}) / max by (pod) (cnpg_pg_settings_setting{{{C}, name="max_connections"}}))', "percentunit", 16, 0,
             steps=[{"color": "green", "value": None}, {"color": "orange", "value": 0.8}, {"color": "red", "value": 0.95}]),
        stat(6, "Operator reconcile errors (1h)", f'sum(increase(controller_runtime_reconcile_errors_total{{{CNPG_OP}}}[1h]))', "short", 20, 0,
             steps=[{"color": "green", "value": None}, {"color": "red", "value": 1}]),
        # Operator (y=4)
        ts(7, "Operator reconciles/s", [("{{controller}} {{result}}", f'sum by (controller, result) (rate(controller_runtime_reconcile_total{{{CNPG_OP}}}[5m]))')], "ops", 0, 4),
        ts(8, "Operator reconcile duration p95", [("{{controller}}", f'histogram_quantile(0.95, sum by (le, controller) (rate(controller_runtime_reconcile_time_seconds_bucket{{{CNPG_OP}}}[5m])))')], "s", 12, 4),
        ts(9, "Operator work queue depth", [("{{name}}", f'max by (name) (workqueue_depth{{{CNPG_OP}}})')], "short", 0, 12),
        ts(10, "Operator CPU and memory", [("CPU cores", f'sum(rate(container_cpu_usage_seconds_total{{{CNPG_OP}, container!=""}}[5m]))'),
                                           ("memory GiB", f'sum(container_memory_working_set_bytes{{{CNPG_OP}, container!=""}}) / 2^30')], "short", 12, 12),
        # Instances (y=20)
        ts(11, "Instance up", [("{{namespace}} {{pod}}", f'cnpg_collector_up{{{C}}}')], "none", 0, 20),
        ts(12, "Replication lag", [("{{namespace}} {{pod}}", f'cnpg_pg_replication_lag{{{C}}}')], "s", 12, 20),
        ts(13, "Connections", [("{{namespace}} {{pod}} {{state}}", f'sum by (namespace, pod, state) (cnpg_backends_total{{{C}}})'),
                               ("max {{namespace}} {{pod}}", f'max by (namespace, pod) (cnpg_pg_settings_setting{{{C}, name="max_connections"}})')], "short", 0, 28),
        ts(14, "Longest transaction", [("{{namespace}} {{pod}}", f'max by (namespace, pod) (cnpg_backends_max_tx_duration_seconds{{{C}}})')], "s", 12, 28),
        ts(15, "Database size", [("{{namespace}} {{datname}}", f'max by (namespace, datname) (cnpg_pg_database_size_bytes{{{C}}})')], "bytes", 0, 36),
        ts(16, "Transactions/s", [("commit {{namespace}} {{datname}}", f'sum by (namespace, datname) (rate(cnpg_pg_stat_database_xact_commit{{{C}}}[5m]))'),
                                  ("rollback {{namespace}} {{datname}}", f'sum by (namespace, datname) (rate(cnpg_pg_stat_database_xact_rollback{{{C}}}[5m]))')], "ops", 12, 36),
        # WAL and backups (y=44)
        ts(17, "WAL archiving", [("archived/s {{namespace}} {{pod}}", f'sum by (namespace, pod) (rate(cnpg_pg_stat_archiver_archived_count{{{C}}}[5m]))'),
                                 ("failed/s {{namespace}} {{pod}}", f'sum by (namespace, pod) (rate(cnpg_pg_stat_archiver_failed_count{{{C}}}[5m]))')], "ops", 0, 44),
        ts(18, "Seconds since last archived WAL", [("{{namespace}} {{pod}}", f'time() - max by (namespace, pod) (cnpg_pg_stat_archiver_last_archived_time{{{C}}})')], "s", 12, 44),
        ts(19, "Last base backup age", [("{{namespace}} {{cluster}}", f'time() - max by (namespace, cluster) (cnpg_collector_last_available_backup_timestamp{{{C}}})')], "s", 0, 52),
        ts(20, "Collector health", [("scrape errors {{namespace}} {{pod}}", f'max by (namespace, pod) (cnpg_collector_last_collection_error{{{C}}})'),
                                    ("collection duration {{namespace}} {{pod}}", f'max by (namespace, pod) (cnpg_collector_collection_duration_seconds{{{C}}})')], "short", 12, 52),
        # Containers (y=60)
        ts(21, "Postgres container CPU (cores)", [("{{namespace}} {{pod}}", f'sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{CNPG}, container="postgres"}}[5m]))'),
                                                  ("throttled {{namespace}} {{pod}}", f'sum by (namespace, pod) (rate(container_cpu_cfs_throttled_seconds_total{{{CNPG}, container="postgres"}}[5m]))')], "short", 0, 60),
        ts(22, "Postgres container memory (working set)", [("{{namespace}} {{pod}}", f'max by (namespace, pod) (container_memory_working_set_bytes{{{CNPG}, container="postgres"}})')], "bytes", 12, 60),
        ts(23, "Data volume used", [("{{namespace}} {{persistentvolumeclaim}}", f'max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes{{namespace=~"$namespace", persistentvolumeclaim=~"$cluster-[0-9]+"}} / kubelet_volume_stats_capacity_bytes{{namespace=~"$namespace", persistentvolumeclaim=~"$cluster-[0-9]+"}})')], "percentunit", 0, 68),
    ]
    d = raw_dashboard("core-infra-cnpg", "CloudNativePG", panels, [ns, cl],
                      "CloudNativePG operator and PostgreSQL cluster health: reconciliation, replication, connections, WAL archiving and backups.")
    d["tags"] = ["core-infra", "generated", "cnpg"]
    d["refresh"] = "1m"
    return d


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.json"):
        old.unlink()
    files = []
    for slug, (title, svc_regex, panels, ctrl, *rest) in APPS.items():
        common = rest[0] if rest else True
        allp = list(panels) + (CONTROLLER_RUNTIME if ctrl else []) + (COMMON if common is True else (common or []))
        d = dashboard(f"core-infra-{slug}", title, allp, svc_regex)
        (OUT / f"{slug}.json").write_text(json.dumps(d, indent=2) + "\n")
        files.append(f"{slug}.json")
    d = dashboard("core-infra-nodes", NODES[0], NODES[1])
    (OUT / "nodes.json").write_text(json.dumps(d, indent=2) + "\n")
    files.append("nodes.json")
    (OUT / "minecraft.json").write_text(json.dumps(minecraft_dashboard(), indent=2) + "\n")
    files.append("minecraft.json")
    (OUT / "cnpg.json").write_text(json.dumps(cnpg_dashboard(), indent=2) + "\n")
    files.append("cnpg.json")
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
