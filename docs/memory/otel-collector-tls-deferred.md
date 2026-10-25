---
name: otel-collector-tls-deferred
description: mTLS on the otelcol-ds OTLP receiver and the collector->netdata-otel leg is deferred; SPIFFE CSI driver now exists, findings from the 2026-10-25 feasibility review
metadata:
  type: project
---

The `otelcol-ds` DaemonSet (applications/opentelemetry-collector-daemonset) accepts OTLP gRPC on `[::]:4317` (hostNetwork) with no TLS and no auth, and exports to netdata-otel (`netdata-otel.netdata.svc.cluster.local:4317`) with `tls.insecure: true`. The netdata-otel port is also plaintext and its NetworkPolicy has no `from:` restriction. Decided 2026-10-24 to leave it that way; re-confirmed 2026-10-25 after the SPIFFE CSI driver landed: **mTLS for the OpenTelemetry collectors is deferred again.**

**Why:** the user wants workload identity (SPIFFE/mTLS) to drive auth, not an interim bearer token or per-node certs. The 2026-10-25 review (feasible, but not trivial) found the open issues below, so it was postponed rather than half-done.

**How to apply:** don't add bearertokenauth or hand-rolled per-node certs. When revisiting, start from these findings:

- **SPIFFE SVIDs have a single URI SAN, no DNS SANs.** The csi-driver-spiffe approver rejects DNS names (`spiffe://core-infra.rye.ninja/ns/<ns>/sa/<sa>`). Fine for client certs; a gRPC client cannot hostname-verify a SPIFFE-only *server* cert. So netdata-otel's server cert should be a normal cert-manager `Certificate` with DNS name `netdata-otel.netdata.svc` (issued from the same CA), not an SVID.
- **mTLS only proves "chains to the CA".** Anything that can obtain an SVID from `csi-driver-spiffe-ca` passes. Real authorization comes from the existing `CertificateRequestPolicy`/ServiceAccount limits plus NetworkPolicy; per-identity allow-lists need an Envoy or collector-side check.
- **Netdata TLS config schema is unverified.** The plugin reference documents `endpoint.tls_cert_path` / `tls_key_path` / `tls_ca_cert_path` (matches the strict-parsed `endpoint.path` form already in `netdata/base/values.yaml`); another Netdata docs page shows a collector-style `tls.cert_file` / `client_ca_file`. Unknown keys stop the plugin from starting. Verify against the deployed version, and whether setting the CA path makes client certs mandatory, before writing manifests. Netdata needs a restart to load rotated certs (SVIDs here are 1h).
- **Other OTLP clients complicate the node-local receiver.** `ccm-sidecar` (operator-injected, sends to `127.0.0.1:4317`) and the Envoy Gateway proxies (via `otelcol-ds.reference-grant.yaml`) would each need a client SVID. If the receiver goes mTLS, they need a solution or a separate loopback-only plaintext listener.
- **NetworkPolicy does not cover the hostNetwork collector**, so the open receiver port is a known gap. See [[calico-networkpolicy-dnat]].
- **Sketch of the eventual design:** SPIFFE CSI volume (works with hostNetwork) on `otelcol-ds` for its client SVID; exporter `tls: {ca_file, cert_file, key_file}`; DNS-SAN `Certificate` for netdata-otel plus the trust-manager bundle as client CA; receiver `tls.client_ca_file`; roll out client certs before enforcing the server, keeping at least one netdata listener enabled throughout.
- Open questions for the user then: does the node-local receiver (4317) also require mTLS or only the collector->netdata-otel leg, and is a separate DNS-SAN server cert for netdata-otel acceptable.

Related: [[external-gateway-header-sanitization-deferred]].
