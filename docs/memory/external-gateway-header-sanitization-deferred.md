---
name: external-gateway-header-sanitization-deferred
description: Stripping inbound traceparent/tracestate/baggage on external Calico gateway classes is deferred until an external Gateway is actually provisioned
metadata:
  type: project
---

Tracing and JSON access logs (with `trace_id`) are enabled on all four `EnvoyProxy` configs in `applications/calico/base/resources/envoy-proxy-config.yaml` (decided 2026-10-24). The matching header-sanitizing policy for the external classes (`external-dedicated`, `external-merged`) is NOT written yet.

**Why:** a `ClientTrafficPolicy` targets individual Gateways, not gateway classes, and no Gateway in the repo uses an external Calico class (only `netdata` uses a Calico class, `internal-dedicated`; the rest use `merged-eg`/`internal-eg` from the separate envoy-gateway app). A policy now would have no target. Without it, an external client can send its own `traceparent` and force trace ID/sampling.

**How to apply:** when the first external Gateway is provisioned, add a `ClientTrafficPolicy` next to it with `spec.headers.earlyRequestHeaders.remove: [traceparent, tracestate, baggage]`. It must be the early-header field; an HTTPRoute header filter runs after Envoy has already adopted the incoming trace context. Confirm the Envoy Gateway version bundled with Calico (CRDs are installed at runtime by the operator) supports `earlyRequestHeaders` first. Also confirm `%TRACE_ID%` renders in the access log; fallback is `%REQ(TRACEPARENT)%`.
