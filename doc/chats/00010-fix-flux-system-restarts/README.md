# Fix flux-system Pod Restarts

Date: May 31, 2026
Chat ID: 00010
Status: In Progress

## Objective

Investigate pod restarts observed across the `flux-system` namespace, identify root causes, and establish ongoing observability to prove out the external API server instability.

## Prompt Timeline

1. Investigate the pod restarts in the `flux-system` namespace.
2. Let's dig deeper on Issue 2.
3. Document this investigation and fix in the `doc/chats/00010-fix-flux-system-restarts` folder.
4. Investigate Issue 3 (Cloudflare CRD CEL bug) and determine if provider update or kustomize can fix it.
5. Upgrade all Cloudflare providers to latest version and draft an upstream issue.
6. Dig deeper into Issue 1 (API server connectivity disruptions).
7. Propose a monitoring strategy using the OpenTelemetry Operator to prove out the Rackspace Spot API instability.

## Repository Context

Relevant files modified in this session:
- [applications/flux/base/patches/deployment.source-controller.yaml](../../../applications/flux/base/patches/deployment.source-controller.yaml)
- [applications/crossplane-providers/family-cloudflare/provider.yaml](../../../applications/crossplane-providers/family-cloudflare/provider.yaml)
- [applications/crossplane-providers/provider-cloudflare-zone/resources/provider.yaml](../../../applications/crossplane-providers/provider-cloudflare-zone/resources/provider.yaml)
- [applications/crossplane-providers/provider-cloudflare-dns/resources/provider.yaml](../../../applications/crossplane-providers/provider-cloudflare-dns/resources/provider.yaml)

Supporting documents created in this session:
- [upstream-issue-cloudflare-settings-cel-bug.md](upstream-issue-cloudflare-settings-cel-bug.md) — two-PR plan for the wildbitca/upjet CEL bug fix
- [monitoring-strategy-api-server-probe.md](monitoring-strategy-api-server-probe.md) — OTel Collector DaemonSet strategy to instrument and alert on API server disruptions

Environment context:
- Cluster access used with `KUBECONFIG=~/.kube/crossplane-controlplane-cluster.yaml`
- Cluster: `crossplane-controlplane-cluster` (4 worker nodes, Rackspace Spot, Ubuntu 24.04)
- Flux version: v2.7.5

## Investigation

### Initial State

`kubectl get pods -n flux-system` showed a spread of restart counts across all controllers, most recently ~1h prior and again ~12h prior:

| Controller | Replicas | Restarts (typical) | Last Restart |
|---|---|---|---|
| helm-controller | 3 | 2–7 | 12h–59m ago |
| kustomize-controller | 3 | 4–5 | 12h–58m ago |
| notification-controller | 3 | 1–5 | 12h–59m ago |
| image-reflector-controller | 3 | 3–5 | 12h–59m ago |
| image-automation-controller | 3 | 1–2 | 12h–59m ago |
| source-controller | 1/3 ready | 0–7 | 12h–14h ago |

### Issue 1: Intermittent API Server Connectivity Disruptions

**Root cause: Rackspace Spot managed control plane API server (`10.21.0.1:443`) experienced three separate connectivity disruptions on May 31, 2026.**

#### Disruption timeline (UTC)

Three confirmed events:

| Wave | Start | Duration | Severity |
|------|-------|----------|----------|
| 1 | 05:27Z | ~8 minutes | Most severe — all leader-electing controllers crashed multiple times |
| 2 | 16:45Z | ~45 seconds | Cluster-wide — Flux + Crossplane core all crashed once |
| 3 | 18:40Z | ~5–10 seconds | Brief — only Crossplane RBAC Manager crashed; Flux controllers survived |

#### Crash mechanism

Every Kubernetes controller using leader election periodically attempts to renew a Lease object via the API server. When `10.21.0.1:443` became unreachable, the renewal attempts failed with:

```json
{"level":"error","ts":"2026-05-31T16:45:35.323Z","logger":"runtime",
 "msg":"Failed to update lock optimistically: ... EOF, falling back to slow path"}
{"level":"error","ts":"2026-05-31T16:46:05.317Z","logger":"runtime",
 "msg":"error retrieving resource lock ...: context deadline exceeded - error from a previous attempt: EOF"}
{"level":"error","ts":"2026-05-31T16:46:20.318Z","logger":"setup",
 "msg":"problem running manager","error":"leader election lost"}
```

Timeline in wave 2: first `EOF` at **16:45:35Z**, lease renewal deadline exceeded at **16:46:05Z**, process exited at **16:46:20Z** — exactly 45 seconds of disruption.

#### Differential sensitivity by timeout

Not all controllers are equally sensitive. The API URL in the Lease error messages reveals each controller's HTTP timeout:

| Component | Lease URL timeout | Result in Wave 3 (5-10s) |
|-----------|-------------------|--------------------------|
| Flux controllers | `?timeout=15s` | **Survived** — no restarts |
| Crossplane RBAC Manager | `?timeout=5s` | **Crashed** — leader election lost |
| Crossplane providers | No leader election | **Unaffected** — all waves |

Wave 3 lasted only ~5–10 seconds. Flux's 15s HTTP timeout meant it never got a timeout error; the connection eventually succeeded within the window. Crossplane RBAC Manager's 5s timeout expired immediately and it could not recover before its `RenewDeadline`.

#### Scope of impact

- **Flux controllers** (helm, kustomize, notification, image-reflector, image-automation, source-controller): crashed in waves 1 and 2, recovered in waves 1 and 2
- **Crossplane core** (`crossplane`, `crossplane-rbac-manager`): crashed in waves 1, 2, and 3
- **Crossplane provider pods** (all cloudflare, aws, github providers): **zero restarts** in any wave — they run as single-instance controllers without leader election
- **Worker nodes**: all 4 nodes remained `Ready` throughout all three waves — the disruptions were control-plane-only

#### Pod restart evidence

Precise UTC timestamps from `kubectl get pods -o custom-columns` with `lastState.terminated.finishedAt`:

**Wave 1 (05:27–05:35Z):**
```
05:27:52Z  image-automation-controller-7845f88c9c-6htjj
05:30:28Z  notification-controller-746cd8f7-7l475
05:31:31Z  notification-controller-746cd8f7-vz4nh
05:31:32Z  kustomize-controller-689d68fbd5-xzh4x
05:31:35Z  helm-controller-6c48c77899-t4pt4
05:31:39Z  image-reflector-controller-6c8b8656f-sfc78
05:31:41Z  kustomize-controller-689d68fbd5-x4xrb
05:32:32Z  crossplane-fc8689d6-4shc9
05:34:42Z  helm-controller-6c48c77899-2jnw4
05:35:06Z  source-controller-78d8fbdc64-8jcsr
05:35:14Z  crossplane-fc8689d6-cmffb
```

**Wave 2 (16:45–16:48Z):**
```
16:46:20Z  notification-controller-746cd8f7-b6pff
16:46:36Z  image-reflector-controller-6c8b8656f-5s9bz
16:46:38Z  image-automation-controller-7845f88c9c-2s27w
16:46:41Z  helm-controller-6c48c77899-n9xxz
16:46:44Z  source-controller-85bcf47b99-mjxts
16:46:45Z  crossplane-fc8689d6-fgzpw
16:47:20Z  kustomize-controller-689d68fbd5-q4hlk
16:48:20Z  crossplane-rbac-manager-65f4b958c5-28f4s
```

**Wave 3 (18:40Z):**
```
18:40:30Z  crossplane-rbac-manager-65f4b958c5-l4t7z  (only casualty)
```

#### What caused this?

`10.21.0.1` is the Kubernetes API server VIP managed by Rackspace Spot's control plane. Worker nodes have no visibility into what happens at this layer. Possible causes:

- Rackspace Spot control plane rolling upgrade of the API server
- Floating IP / VIP failover between redundant API server nodes
- Transient network disruption between worker nodes and the control plane network segment
- API server process restart due to OOM, certificate rotation, or config change

All three events were brief (seconds to minutes) and self-healing. There is no evidence of any worker node issue.

#### Recovery

All pods auto-restarted via Kubernetes restart policy and re-acquired leader election within 30–60 seconds of the API server becoming reachable again. No data was lost — Flux and Crossplane are stateless reconcilers that re-sync from Git/provider state on startup.

#### Mitigation options

| Option | Protects against | Notes |
|--------|-----------------|-------|
| Accept as platform behavior | — | Spot instances have less SLA than dedicated. Auto-recovery is working. |
| Tune Crossplane `LeaseDuration`/`RenewDeadline` | Short blips (<5s) | Increasing the HTTP timeout in Crossplane would reduce sensitivity to wave 3-type events |
| File Rackspace Spot support ticket | Nothing directly | Useful to establish a pattern if frequency increases |
| Migrate control plane to dedicated instances | All waves | Eliminates Spot-related control plane instability |

No code changes made for Issue 1 — the cluster is self-healing and the disruptions are external.

### Issue 2: `source-controller` Deployment Stuck in Rollout

```
NAME               READY   UP-TO-DATE   AVAILABLE
source-controller  1/3     3            1            → exceeded progress deadline
```

**Root cause: readiness probe targets the HTTP artifact storage server (port 9090), which is only started by the leader replica.**

In Flux source-controller's HA mode, only the leader pod starts the HTTP storage server on port 9090. Non-leader replicas never bind port 9090 and will always fail a readiness probe against it.

Confirmed via live cluster probe:

```
Leader  (6zjq9): GET 10.20.140.145:9090/    → 200 OK (serves gitrepository/)
Standby (vjdxc): GET 10.20.175.120:9090/    → Connection refused
Leader  (6zjq9): GET 10.20.140.145:9440/readyz → 200 OK
Standby (vjdxc): GET 10.20.175.120:9440/readyz → 200 OK  ✓
```

**Rollout deadlock mechanics:**

With `replicas: 3` and `maxUnavailable: 1`, the Deployment controller requires ≥2 pods available at all times during a rollout:

```
minAvailable = 3 - maxUnavailable(1) = 2

New RS (85bcf47b99): 3 pods, but only 1 ever Available (leader only)
Old RS (78d8fbdc64): DESIRED=1, pod Not Ready (0 Available)

Total Available: 1  <  minAvailable (2)
→ Old RS cannot scale to 0
→ Rollout permanently stalled
→ Deployment exceeds progress deadline
→ Old RS pod (78d8fbdc64-8jcsr, 14h old, 7 restarts) lives forever
```

The key observation: every other Flux controller (helm, kustomize, notification, image-reflector, image-automation) uses `GET /readyz` on port `healthz` (9440), which all replicas serve regardless of leader status. Source-controller was the only exception, using `GET /` on port `http` (9090).

## What Was Implemented

### Readiness probe override for source-controller

Updated:
- [applications/flux/base/patches/deployment.source-controller.yaml](applications/flux/base/patches/deployment.source-controller.yaml)

Added a `replace` JSON patch operation to override the source-controller readiness probe from `GET / :http` to `GET /readyz :healthz`, consistent with all other Flux controllers:

```yaml
- op: replace
  path: /spec/template/spec/containers/0/readinessProbe
  value:
    httpGet:
      path: /readyz
      port: healthz
    failureThreshold: 3
    periodSeconds: 10
    successThreshold: 1
    timeoutSeconds: 1
```

**Expected outcome after Flux reconciles:**
- All 3 source-controller replicas become Ready (all serve `/readyz` on `:9440`)
- Deployment controller sees Available=3, completes the stalled rollout
- Old RS `78d8fbdc64` scales to 0; orphaned pod `8jcsr` is terminated
- `source-controller` deployment shows `READY 3/3`

Both linters passed after the change:
- checkov: `Passed checks: 5256, Failed checks: 0, Skipped checks: 139`
- kube-linter: `No lint errors found!`

### Issue 3: Cloudflare `settings` CRD Fails to Install — CEL Validation Bug

Warning events observed from the `wildbitca-provider-cloudflare-zone` provider revision:

```
CustomResourceDefinition "settings.zone.upjet-cloudflare.upbound.io" is invalid:
spec.versions[0].schema.openAPIV3Schema.properties[spec].x-kubernetes-validations[1].rule:
Invalid value: "expression": undefined field 'value'
```

**Affected MRDs:** `settings.zone.upjet-cloudflare.upbound.io` and `settings.zone.upjet-cloudflare.m.upbound.io` — both stuck `Established: False`. All other 12 CRDs from `provider-cloudflare-zone` and `provider-cloudflare-dns` are `Established: True`.

**Root cause:** The `cloudflare_zone_setting` Terraform resource uses a dynamic type for its `value` argument (it can be a string, integer, or object depending on which zone setting is being managed). Upjet maps this to `x-kubernetes-preserve-unknown-fields: true` with no `type`. However, the upjet code generator still emits a spec-level CEL required-field rule:

```yaml
x-kubernetes-validations:
  - rule: >-
      !('*' in self.managementPolicies || ...) || has(self.forProvider.value) ||
      (has(self.initProvider) && has(self.initProvider.value))
    message: spec.forProvider.value is a required parameter
```

The Kubernetes CEL static type environment excludes fields with no explicit `type` from the type-checking scope. The API server's CEL compiler cannot resolve `value`, causing `undefined field 'value'`. The CRD is rejected before it is ever created.

**Impact:** `Settings` resources (`kind: Setting`) are not used anywhere in this repository. The broken MRD produces continual `ApplyCustomResourceDefinition` error events but does not affect any managed resources we actually use.

**Provider upgrade assessment:** Upgrading to v0.2.6 (the latest available) does not fix this bug. The v0.2.1→v0.2.6 diff contains only Zero Trust and R2 changes — the zone package is untouched. The fix must come from the provider package itself.

**Kustomize workaround assessment:** Not viable. The MRD is owned by the Crossplane provider controller and will be overwritten on the next reconcile. Since the CRD is rejected before creation, there is no CRD object to patch in place either.

**Resolution:** Upgraded all three Cloudflare providers to v0.2.6 to stay current. The `settings` CEL bug persists but is harmless for this repository. A draft upstream issue was prepared at [upstream-issue-cloudflare-settings-cel-bug.md](upstream-issue-cloudflare-settings-cel-bug.md).

## Key Learnings

1. **Flux source-controller HA mode uses a leader-only HTTP storage server on port 9090.**
   Non-leader replicas never start this server. The upstream default readiness probe (`GET / :9090`) means only the leader will ever be Ready when running >1 replica.

2. **All other Flux controllers correctly use `GET /readyz :9440` for readiness.**
   Port 9440 (healthz) is served by all replicas regardless of leader status, making it the correct probe target for HA deployments.

3. **A readiness probe mismatch in HA mode creates a permanent rollout deadlock.**
   With `maxUnavailable: 1` and only 1/N replicas ever passing readiness, the Deployment controller can never satisfy `minAvailable` from the new RS alone, so it cannot drain the old RS. The rollout exceeds its progress deadline and the old RS pod lives indefinitely.

4. **Diagnosing readiness probe failures: check whether the port is leader-gated.**
   When a pod shows `0 restarts` but is persistently Not Ready, the probe is likely checking something that only initializes after leader election rather than a crash. Curl-probing both a leader and a non-leader pod directly is the fastest way to confirm.

5. **Upjet-generated CRDs can contain CEL rules that reference typeless (`x-kubernetes-preserve-unknown-fields: true`) fields.**
   Kubernetes's CEL static type environment excludes such fields, causing CRD installation to fail with `undefined field`. Kustomize patches on Crossplane-owned MRDs are overwritten on every reconcile and are not a viable workaround. The fix must be in the provider package (skip CEL rule generation for typeless fields). If the affected resource is unused, the error is benign noise.

6. **Kubernetes leader election sensitivity is governed by the HTTP timeout in the Lease API URL, not just `LeaseDuration`/`RenewDeadline`.**
   Crossplane RBAC Manager uses `?timeout=5s` in its lease calls and crashes on disruptions as short as 5–10 seconds. Flux controllers use `?timeout=15s` and survive the same disruptions. When diagnosing differential pod restart patterns after a control plane blip, inspect the error message URLs to compare timeouts across components.

7. **Crossplane provider pods do not participate in leader election and are immune to control plane connectivity blips.**
   All provider pods (cloudflare, aws, github) showed zero restarts across all three disruption waves. Only components that actively renew Lease objects (`crossplane`, `crossplane-rbac-manager`, all Flux controllers) are affected. This pattern is a reliable fingerprint for API server disruption vs. node-level issues.

8. **Persistent pod restart counts mixed with precise `lastState.terminated.finishedAt` timestamps reveal disruption waves.**
   Running `kubectl get pods -o custom-columns=...,LAST-RESTART:.status.containerStatuses[0].lastState.terminated.finishedAt --sort-by=...` groups pods by restart timestamp and immediately reveals concurrent failure clusters — each wave appears as a tight band of timestamps spanning 30–90 seconds.

## Operational Notes

Commands used for verification:

```bash
# Overview with restart counts
kubectl get pods -n flux-system --sort-by='.status.containerStatuses[0].restartCount'

# Pod placement and node assignment
kubectl get pods -n flux-system -l app=source-controller -o wide

# Deployment rollout state
kubectl get deployment -n flux-system
kubectl rollout status deployment/source-controller -n flux-system

# ReplicaSet state (reveals old RS stuck at DESIRED=1)
kubectl get replicasets -n flux-system -l app=source-controller

# Live probe verification (leader vs standby)
kubectl run -n flux-system probe-test --image=curlimages/curl --rm -it --restart=Never -- sh -c "
  curl -sv http://<LEADER_IP>:9090/
  curl -sv http://<LEADER_IP>:9440/readyz
  curl -sv http://<STANDBY_IP>:9090/
  curl -sv http://<STANDBY_IP>:9440/readyz
"

# Probe config comparison
kubectl get pod -n flux-system <pod> -o jsonpath='{.spec.containers[0].readinessProbe}'

# Issue 1: Identify disruption waves by restart timestamp
kubectl get pods -n flux-system \
  -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST-RESTART:.status.containerStatuses[0].lastState.terminated.finishedAt,NODE:.spec.nodeName' \
  --sort-by='.status.containerStatuses[0].lastState.terminated.finishedAt'

# Issue 1: Check scope across namespaces
kubectl get pods -n crossplane-system \
  -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST-RESTART:.status.containerStatuses[0].lastState.terminated.finishedAt' \
  --sort-by='.status.containerStatuses[0].lastState.terminated.finishedAt'

# Issue 1: Get crash log from a specific pod's previous run
kubectl logs -n flux-system <pod-name> --previous | tail -30

# Issue 1: Node condition check (confirm nodes stayed healthy)
kubectl describe nodes | grep -A5 "Conditions:" | grep -v "^--$"
```
