# Calico LoadBalancer IPAM: leaked allocation and periodic status clearing (IPv6), and the effect on ExternalDNS

Draft upstream bug reports. Everything below was observed on the `core-infra`
cluster on 2026-10-24 (UTC). Sections 1 and 2 are written to be pasted into
`projectcalico/calico` issues; section 3 is a smaller request for
`kubernetes-sigs/external-dns`.

> **Before posting:** scrub or generalize `rye.ninja` hostnames and the
> `fd97:45c2:b3a1::/48` ULA prefix if you do not want them public. They are
> real values from this cluster. The file name says "bgp" and "iam": BGP was
> checked and ruled out (the route was correct and advertised throughout), and
> "iam" is IPAM.

## What happened, in one paragraph

An IPv6-only Gateway's LoadBalancer address (served by Calico's LoadBalancer
IPAM) intermittently disappeared and reappeared, and external-dns, which
publishes that address to DNS, saw a wrong address and then an empty one. Two
separate Calico behaviors were involved. (1) A **leaked IPAM allocation** from
a previous incarnation of the same-named Service made the LoadBalancer
controller alternate the Service's status between two addresses. After
releasing the leaked allocation by hand, (2) the controller **still clears the
Service's `status.loadBalancer.ingress` for 1-2 seconds on every periodic sync**
(every 5 minutes), even though the Service already holds exactly the address it
should.

## Environment

| | |
|---|---|
| Calico | v3.32.1 (tigera-operator chart `v3.32.1`; `quay.io/calico/kube-controllers:v3.32.1`) |
| Kubernetes | v1.37.0 |
| OS | Talos v1.14.1, kernel 6.18.51-talos |
| Cluster networking | IPv6-only (`ipFamilies: ["IPv6"]`, `SingleStack`), Calico BGP to an external router |
| Gateway API | Calico's bundled Envoy Gateway (`quay.io/calico/envoy-gateway:v3.32.1`), proxies in `tigera-gateway` |
| `KubeControllersConfiguration` | `loadBalancer.assignIPs: AllServices` (running config) |
| IP pool | `lb-internal-routed`, `fd97:45c2:b3a1:f00::1:0/112`, `allowedUses: [LoadBalancer]`, `assignmentMode: Automatic` |
| Service | `tigera-gateway/envoy-netdata-netdata-c22a5e6a`, `type: LoadBalancer`, `loadBalancerClass: calico`, `externalTrafficPolicy: Cluster`, annotation `projectcalico.org/ipv6pools: ["lb-internal-routed"]`; created and spec-managed by Envoy Gateway |
| external-dns | chart `1.20.0`, image `registry.k8s.io/external-dns/external-dns@sha256:ddc7f4212ed09a21024deb1f470a05240837712e74e4b9f6d1f2632ff10672e7`, `--policy=sync --registry=txt --interval=3m --events`, `gateway-httproute` source, Cloudflare provider, 3 replicas |

---

## 1. Calico issue A: leaked LoadBalancer IPAM allocation makes the Service address flip

**Title:** LoadBalancer IPAM leaves two allocations for one Service after it is
recreated under the same name; controller flips `status.loadBalancer.ingress`
between them

### Summary

A Service was deleted and recreated with the same namespace and name. The old
Service's IPAM allocation was never released. Calico then held two
`LoadBalancer` allocations for `tigera-gateway/envoy-netdata-netdata-c22a5e6a`:
the live address and a stale one. The kube-controllers LoadBalancer controller
alternated the Service's `status.loadBalancer.ingress` between them
(`...::1:9285` -> `...::1:9284` -> `...::1:9285`, each for a few seconds).
We saw no log message identifying it as a leak, and it was not garbage-collected: it persisted from 2026-10-22 until we released it by hand on 2026-10-24 (about 3 days).

### Evidence

`calicoctl ipam show` for both addresses (handles and timestamps differ, the
owner attributes are identical):

```
$ calicoctl ipam show --ip=fd97:45c2:b3a1:f00::1:9284
IP fd97:45c2:b3a1:f00::1:9284 is in use
Handle ID: lb-YiTCpxkZIxpwBwo55H4YXMiubheSSAxvW3uBycoaI
Active Owner Attributes:
  namespace: tigera-gateway
  service: envoy-netdata-netdata-c22a5e6a
  timestamp: 2026-10-22 00:38:41.432905953 +0000 UTC
  type: LoadBalancer

$ calicoctl ipam show --ip=fd97:45c2:b3a1:f00::1:9285
IP fd97:45c2:b3a1:f00::1:9285 is in use
Handle ID: lb-fzeMFSHXcWMowv606jd3W92xgqdtXNXB5BmbMczxME
Active Owner Attributes:
  namespace: tigera-gateway
  service: envoy-netdata-netdata-c22a5e6a
  timestamp: 2026-10-22 01:13:04.772775336 +0000 UTC
  type: LoadBalancer
```

The Service object that exists was created at `2026-10-22T01:13:04Z`, which
matches the `...9285` allocation. The `...9284` allocation (00:38:41) belongs to
an earlier incarnation of the Service.

A watch on the Service recorded only `status.loadBalancer.ingress` changing
(`spec`, annotations and labels identical across each change), and
`managedFields` showed `kube-controllers` as the writer of the status:

```
MODIFIED rv=8996192  ['fd97:45c2:b3a1:f00::1:9284']  ingress ['...9285'] -> ['...9284']
MODIFIED rv=8996206  ['fd97:45c2:b3a1:f00::1:9285']  ingress ['...9284'] -> ['...9285']
MODIFIED rv=8997285  ['fd97:45c2:b3a1:f00::1:9284']  ingress ['...9285'] -> ['...9284']
MODIFIED rv=8997297  ['fd97:45c2:b3a1:f00::1:9285']  ingress ['...9284'] -> ['...9285']
```

### Resolution used

```
calicoctl ipam release --ip=fd97:45c2:b3a1:f00::1:9284
```

After this the Service no longer flipped to a second address.

### Expected behavior

When a Service is deleted, its LoadBalancer allocation is released. If a
leaked allocation does exist (for example because the delete event was missed),
the LoadBalancer controller should detect an allocation attributed to a Service
that is not using it, and either garbage-collect it or at least report it.

### Actual behavior

The stale allocation was never released or garbage-collected, and we saw no
log message about it. Because it is attributed to the same `namespace/service`
as the live Service, we suspect it is not recognized as a leak, but we have not
confirmed that. The controller alternated the Service's status between the two
addresses.

### Not known

- **How the leak was created.** We believe the Service was recreated by Envoy
  Gateway (the proxy Service is owned by its Gateway) around 2026-10-22 00:38 -
  01:13 UTC, but we do not have logs from that window and have not reproduced
  it on a clean cluster.
- Whether the controller deliberately picks among multiple allocations or this
  is an ordering artifact. We only observed the alternation.

---

## 2. Calico issue B: periodic sync clears `status.loadBalancer.ingress` of a healthy Service

**Title:** kube-controllers LoadBalancer controller writes an empty
`status.loadBalancer.ingress` ("Assigned IPs []") for a Service that already has
its address, every periodic sync

### Summary

With the leaked allocation from issue A removed, every Service in the pool
still has exactly one allocation matching its status. Even so, the LoadBalancer
controller briefly **clears** the Service's `status.loadBalancer.ingress` and
then restores it 1-2 seconds later. It happens on the controller's 5-minute
periodic sync and also on some event-driven reconciles. Any consumer of the
Service/Gateway address (here: external-dns, an Envoy Gateway `Gateway`'s
`status.addresses`) sees the address disappear and reappear.

### Reproduction

We see it every cycle on this cluster, where this is the only Service holding a
Calico-assigned LoadBalancer address (`type: LoadBalancer`,
`loadBalancerClass: calico`, a `LoadBalancer`-use pool, `assignIPs:
AllServices`). We have not tried a minimal cluster.

1. Have a LoadBalancer Service that already has its IP assigned from a Calico
   pool.
2. Watch it:
   `kubectl get svc -n <ns> <name> -w -o jsonpath='{.metadata.name} {.status.loadBalancer.ingress[*].ip}{"\n"}'`
3. Wait for the controller's periodic sync (every 5 minutes).

### Expected behavior

A Service that already holds its desired address keeps
`status.loadBalancer.ingress` untouched.

### Actual behavior

The address is cleared and restored. Observed with a purpose-built watcher over
a 330-second window (timestamps are when the change was seen; the Gateway
column is Envoy Gateway's `Gateway.status.addresses`, which follows the
Service):

```
22:09:50Z  CLEARED   gateway/netdata/netdata                          fd97:45c2:b3a1:f00::1:9285 -> (none)
22:09:50Z  CLEARED   svc/tigera-gateway/envoy-netdata-netdata-c22a5e6a fd97:45c2:b3a1:f00::1:9285 -> (none)
22:09:51Z  RESTORED  gateway/netdata/netdata                          (none) -> fd97:45c2:b3a1:f00::1:9285
22:09:51Z  RESTORED  svc/tigera-gateway/envoy-netdata-netdata-c22a5e6a (none) -> fd97:45c2:b3a1:f00::1:9285
22:12:04Z  CLEARED   (both)  ...9285 -> (none)
22:12:05Z  RESTORED (both)  (none) -> ...9285
22:12:12Z  CLEARED   (both)  ...9285 -> (none)
22:12:13Z  RESTORED (both)  (none) -> ...9285
22:14:50Z  CLEARED   (both)  ...9285 -> (none)
22:14:51Z  RESTORED (both)  (none) -> ...9285
```

No `CHANGED` events (address never moved to a different IP) in this window.
Earlier we saw the same at 22:02:12Z, and the Gateway address was empty at 22:04:51Z.

kube-controllers log for the 22:09:50 event (identical sequence at 22:12:04,
22:12:12 and 22:14:50):

```
22:09:50.195 loadbalancer_controller.go 264: Running periodic IPAM sync of Service LoadBalancer
22:09:50.197 loadbalancer_controller.go 857: Resolved pool name lb-internal-routed to cidr fd97:45c2:b3a1:f00::1:0/112
22:09:50.197 loadbalancer_controller.go 590: Service requires an IP assignment tigera-gateway/envoy-netdata-netdata-c22a5e6a
22:09:50.198 loadbalancer_controller.go 740: Service tigera-gateway/envoy-netdata-netdata-c22a5e6a requires 0 IPv4 and 1 IPv6 addresses.
22:09:50.198 loadbalancer_controller.go 751: Service already has an IPv6 address: fd97:45c2:b3a1:f00::1:9285
22:09:50.198 loadbalancer_controller.go 758: No new IPs to assign, Service already has desired LB addresses svc="envoy-netdata-netdata-c22a5e6a"
22:09:50.198 loadbalancer_controller.go 595: Assigned IPs [] for Service tigera-gateway/envoy-netdata-netdata-c22a5e6a
22:09:51.249 loadbalancer_controller.go 857: Resolved pool name lb-internal-routed to cidr fd97:45c2:b3a1:f00::1:0/112
```

At 22:14:50 the same handling also logged:

```
22:14:50.290 loadbalancer_controller.go 649: Failed to update service status tigera-gateway/envoy-netdata-netdata-c22a5e6a error=Operation cannot be fulfilled on services "...": the object has been modified; please apply your changes to the latest version and try
```

`managedFields` on the Service shows the status writer as
`kube-controllers / Update / status`, with the timestamp matching these events
(e.g. `2026-10-24T22:02:12Z`).

### Suspected cause (hypothesis, not confirmed)

The sequence "`No new IPs to assign, Service already has desired LB
addresses`" followed immediately by "`Assigned IPs []`" suggests the
assignment function returns an empty slice when nothing new is needed, and the
caller then writes that empty slice into `status.loadBalancer.ingress` instead
of leaving the existing status alone. The next reconcile sees the Service
needs an address, finds the existing allocation and restores it. We have not
read the source for the exact code path; the log line numbers (590-602, 649,
740-758) are v3.32.1.

### Impact

- The Service's `status.loadBalancer.ingress` and any resource derived from it
  (here: Envoy Gateway `Gateway.status.addresses`) are empty for 1-2 seconds
  every few minutes.
- Controllers that publish the address externally (external-dns) can observe
  the empty state. See section 3.

### Workaround

None found. Releasing the leaked allocation in issue A removed the address
*flip*, but not this clear-and-restore.

### Questions for maintainers

- Is this intended? If not, is there a fix in a newer release (v3.33.0 or
  main)?
- Is there a supported way to make the controller skip Services that already
  have a matching allocation?

---

## 3. external-dns: address withdrawn when a Gateway's `status.addresses` is momentarily empty (request, not a confirmed bug)

**Title:** `--policy=sync` plus `--events`: transient empty `Gateway.status.addresses`
can withdraw a record (request for a grace period or opt-out)

### Summary

The `gateway-httproute` source builds targets from the parent Gateway's
`status.addresses`. With `--policy=sync` and `--events` (event-triggered
reconciles), an HTTPRoute whose Gateway address is briefly empty produces no
endpoints, so a sync that lands inside the window would delete the record. In
our cluster the address is cleared by Calico for 1-2 seconds roughly every
2-3 minutes (section 2).

### What we observed (and did not observe)

- **Observed:** external-dns (3 replicas) generated the expected endpoint on
  both sides of the empty window (e.g. 22:02:11Z and 22:02:18Z for a clear at
  22:02:12Z); the record stayed in Cloudflare throughout.
- **Observed earlier the same day:** the record disappeared every ~2 minutes,
  but that was a separate cause (two external-dns instances in different
  clusters sharing owner ID `default` and deleting each other's records), now
  fixed with `--txt-owner-id`. It is unrelated to this request.
- **Not observed:** an external-dns replica actually deleting the record
  because of an empty Gateway address. We estimate the chance per sync is low
  (a ~2 s window against a 180 s interval, times 3 replicas), but have not
  measured it.

So this is a robustness request, not a reproduced bug.

### Request

One of:
- a flag to ignore (or delay acting on) an endpoint set that goes from non-empty
  to empty for a source, for a configurable grace period; or
- documented guidance for sources whose upstream status flaps (for example,
  `--policy=upsert-only` for that zone, or running a single replica).

### Environment

See the table at the top. Also: `--interval=3m`, `--events`
(`triggerLoopOnEvent: true`), `--registry=txt --txt-prefix=edns.`.

---

## Appendix: tooling used

Reproducible with the scripts in this repo (`flux-platform-src`):

- `make detect-calico-ipam-flapping CLUSTER=<cluster>` finds an IPAM
  allocation that its Service is not using (issue A). Add `WATCH=330` to run
  the live watcher that produced the `CLEARED` / `RESTORED` timeline above
  (issue B).
- `make release-calico-ipam-allocation CLUSTER=<cluster> IP=<address>`
  releases a leaked allocation after refusing anything a live Service uses.
- `.bin/test/test-detect-calico-ipam-flapping.sh` has fixture tests for the
  leak detector, including the exact duplicate-allocation case from issue A.

## Not verified / limits of this report

- No clean-cluster reproduction of either issue.
- No source-level confirmation of the suspected cause in section 2.
- No test of Calico v3.33.0 or any newer release.
- The creation event of the leaked allocation (issue A) was not captured.
- A search of the upstream issue tracker for these symptoms found no matching
  issue; the nearest, [#10412](https://github.com/projectcalico/calico/issues/10412)
  (IPv6 address missing from an `apiserver-calico` Service), shows the same
  "No new IPs to assign" log line but a different symptom.
