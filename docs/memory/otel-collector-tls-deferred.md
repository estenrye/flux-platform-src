---
name: otel-collector-tls-deferred
description: TLS/mTLS/auth on the otelcol-ds OTLP trace receiver is deliberately deferred until cert-manager-spiffe-csi-driver lands
metadata:
  type: project
---

The `otelcol-ds` DaemonSet (applications/opentelemetry-collector-daemonset) accepts OTLP gRPC traces on `[::]:4317` (hostNetwork) with no TLS and no auth, and exports to netdata-otel with `tls.insecure: true`. Decided 2026-10-24 to leave it that way for now.

**Why:** the user intends to implement `applications/cert-manager-spiffe-csi-driver` soon and wants workload identity (SPIFFE/mTLS) to drive receiver auth, not an interim bearer token or per-node certs.

**How to apply:** don't add bearertokenauth or hand-rolled cert-manager Certificates to the collector receiver; when the SPIFFE CSI driver exists, revisit with mTLS (`tls.client_ca_file`) and a `internalTrafficPolicy: Local` Service for a stable name. NetworkPolicy does not cover the hostNetwork collector, so the open port is a known gap. See [[calico-networkpolicy-dnat]] for policy caveats.
