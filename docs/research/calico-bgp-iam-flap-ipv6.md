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
publishes that address to DNS, saw a wrong address and then an empty one. Both
symptoms come from one defect in the kube-controllers LoadBalancer controller
(v3.32.1): after a Service is recreated under the same name, an IPAM
allocation keyed to the *old* Service UID remains, and `syncService` applies
that stale key to the *live* Service because it looks the Service up by name
only. While the old allocation existed, the stale key wrote its address into
the Service status (**issue A**, a flip between two addresses). After the
allocation was released by hand, the stale key stayed in the controller's
in-memory tracker as an empty entry and wrote an **empty** status on every
sync (**issue B**, a 1-2 second clear every few minutes). Restarting
kube-controllers made the clears stop. See "Root cause" below.

## Root cause (from the v3.32.1 source)

File: `kube-controllers/pkg/controllers/loadbalancer/loadbalancer_controller.go`
at tag `v3.32.1`.

1. **A handle includes the Service UID.** `createHandle` returns `"lb-" +
   base64(sha256("<name>-<namespace>-<uid>"))`. A Service recreated under the
   same name has a new UID and therefore a new handle.
2. **The tracker is keyed by `serviceKey{handle, name, namespace}`**, built from
   the IPAM block attributes in `handleBlockUpdate`. After a recreate that
   leaked the old allocation, the tracker holds two keys for the same
   `namespace/name`: the live handle and the stale one.
3. **`syncIPAM` runs `syncService` for every tracker key**, in addition to every
   live Service (it adds `for svcKey := range c.allocationTracker.ipsByService`
   to the set).
4. **`syncService` finds the Service by name only.** It calls
   `serviceLister.Services(svcKey.namespace).Get(svcKey.name)` and then uses
   that live Service with the stale `svcKey`. It never checks that
   `svcKey.handle` matches the Service's current handle. The "Service was
   deleted" garbage-collection branch only runs when that lookup returns
   NotFound, so a Service recreated under the same name masks the leak.
5. **With the stale key**, `needsIPsAssigned` (`len(ipsByService[svcKey]) != 1`)
   and `needsStatusUpdate` are evaluated against the stale key's IP set, and
   `updateServiceStatus` builds `status.loadBalancer.ingress` from that set:
   - stale key holds `{...9284}` -> status written as `[...9284]` (issue A);
   - stale key holds `{}` -> status written as `[]` (issue B).
6. **A released key is never removed.** `releaseAddressFromService` does
   `delete(t.ipsByService[svcKey], ip)` and leaves the (now empty) map under
   `ipsByService[svcKey]`, so `syncIPAM` keeps iterating it until the process
   restarts. (`assignIP` then logs "No new IPs to assign" and returns an empty
   slice, which is the `Assigned IPs []` line, but the status is written from
   the stale key, not from that slice.)
7. **Triggers:** the 5-minute periodic sync, and any `syncChan` kick, which
   every IPAM block update causes.

This was verified by experiment: after `calico-kube-controllers` was restarted
(23:01:05Z), the tracker was rebuilt from IPAM without the stale key and a
420-second watch, spanning the periodic sync at 23:06:11Z, saw no address
change and none of the `requires an IP assignment` / `Assigned IPs []` log
lines that preceded every earlier clear.

### Newer releases (source review, not run)

`loadbalancer_controller.go` was compared at `v3.32.1`, `v3.32.2`, `v3.33.0`
(published 2026-10-01) and `master`. The defect is unchanged in all of them:

| Code path | v3.32.1 | v3.32.2 | v3.33.0 | master |
|---|---|---|---|---|
| `syncIPAM` also syncs every tracker key | yes | yes | yes | yes |
| `syncService` looks the Service up by name only (no handle/UID check) | yes | yes | yes | yes |
| `releaseAddressFromService` leaves an empty `ipsByService` entry | yes | yes | yes | yes |

Changes between `v3.32.1` and `v3.33.0` in this file are unrelated: tombstone
handling in `onServiceDelete`, log wording, and a fallback to
`spec.loadBalancerIP`. `master` adds a nil-pointer guard for allocations with
no handle (#14108, after `v3.33.0`). Upstream issue and PR searches for these
symptoms returned nothing, which does not prove none exist.

### Proposed fixes

Two small changes against `v3.33.0` (the same code is in `v3.32.2` and `master`).
They address different halves of the problem and are independent.

#### Fix 1: do not apply a stale key to the live Service (`syncService`)

This removes the root cause: the stale key's handler no longer rewrites a
Service it does not own. **Not compiled or tested**: it needs the full
controller package; only the reasoning above supports it. Suggested placement
is right after the Service lookup succeeds, before `IsCalicoManagedLoadBalancer`:

```diff
 	svc, err := c.serviceLister.Services(svcKey.namespace).Get(svcKey.name)
 	if apierrors.IsNotFound(err) {
 		...
 	}
 	if err != nil {
 		log.WithError(err).Error("Error getting service from serviceLister")
 		return
 	}
+
+	// svcKey may belong to an earlier incarnation of a Service that was deleted and recreated
+	// under the same name (a new UID gives a new handle). Never apply a stale key to the live
+	// Service: doing so rewrites its status from the stale key's addresses.
+	if liveKey, err := serviceKeyFromService(svc); err == nil && liveKey.handle != svcKey.handle {
+		log.Warnf("Ignoring IPAM handle %s for Service %s/%s: it does not belong to the current Service (handle %s)",
+			svcKey.handle, svcKey.namespace, svcKey.name, liveKey.handle)
+		return
+	}
```

The conservative form above only ignores the stale key. Releasing it
(`c.releaseIPsByHandle(svcKey)` before returning, which also drops the key from
the tracker) would also fix the leak itself, but maintainers should decide
whether that is safe: if any earlier release derived `createHandle` differently,
a mismatch would not mean "stale" and the release would free a valid
allocation. Tests this needs: a controller-level test with a fake clientset and
IPAM where a Service is recreated under the same name and the old handle's
allocation is left in IPAM; assert the Service's status is never written from
the old handle's addresses.

#### Fix 2: drop empty tracker entries (`releaseAddressFromService`)

This removes the second symptom (the clear) even if a stale allocation was
released out of band. **Tested in isolation**: the tracker code was copied
verbatim from `v3.33.0` into a dependency-free module; the test below fails on
the unmodified code and passes with the patch.

```diff
 func (t *allocationTracker) releaseAddressFromService(svcKey serviceKey, ip string) {
 	delete(t.servicesByIP, ip)
 	delete(t.ipsByService[svcKey], ip)
+	if len(t.ipsByService[svcKey]) == 0 {
+		// Do not leave an empty entry behind: syncIPAM syncs every key in ipsByService.
+		delete(t.ipsByService, svcKey)
+	}
 	for block, ips := range t.ipsByBlock {
```

`deleteService` ranges over `t.ipsByService[svcKey]` while releasing; deleting the
outer entry during that range is safe because the range holds the inner map.

```go
package tracker

import "testing"

func newTracker() *allocationTracker {
	return &allocationTracker{
		servicesByIP: map[string]serviceKey{},
		ipsByService: map[serviceKey]map[string]bool{},
		ipsByBlock:   map[string]map[string]bool{},
	}
}

// A Service recreated under the same name has a new UID and therefore a new handle,
// so the tracker holds one key per handle for the same namespace/name.
var (
	oldKey  = serviceKey{handle: "lb-old-uid", namespace: "tigera-gateway", name: "envoy"}
	liveKey = serviceKey{handle: "lb-new-uid", namespace: "tigera-gateway", name: "envoy"}
)

// Releasing the last address of a key (what a block update does after the address is released
// in IPAM) must not leave the key behind: syncIPAM syncs every key still in ipsByService.
func TestReleasingLastAddressRemovesKey(t *testing.T) {
	tr := newTracker()
	tr.assignAddressToBlock("block", "fd97::9284", oldKey)
	tr.assignAddressToBlock("block", "fd97::9285", liveKey)

	tr.releaseAddressFromBlock("block", "fd97::9284")

	if _, present := tr.ipsByService[oldKey]; present {
		t.Fatalf("stale key %+v is still tracked with %d addresses; syncIPAM will keep syncing it against the live Service",
			oldKey, len(tr.ipsByService[oldKey]))
	}
	if !tr.ipsByService[liveKey]["fd97::9285"] {
		t.Fatalf("the live key lost its address")
	}
}

// The controller's own release path (releaseIPsByHandle -> deleteService) already removes the key.
func TestDeleteServiceRemovesKey(t *testing.T) {
	tr := newTracker()
	tr.assignAddressToBlock("block", "fd97::9284", oldKey)
	tr.deleteService(oldKey)
	if _, present := tr.ipsByService[oldKey]; present {
		t.Fatalf("deleteService left the key behind")
	}
}

// Releasing one of two addresses must keep the key and the remaining address.
func TestReleasingOneOfTwoKeepsKey(t *testing.T) {
	tr := newTracker()
	tr.assignAddressToBlock("block", "10.0.0.1", liveKey)
	tr.assignAddressToBlock("block", "fd97::9285", liveKey)
	tr.releaseAddressFromBlock("block", "10.0.0.1")
	if !tr.ipsByService[liveKey]["fd97::9285"] || len(tr.ipsByService[liveKey]) != 1 {
		t.Fatalf("expected only fd97::9285 to remain, got %v", tr.ipsByService[liveKey])
	}
}
```

Result against the unmodified `v3.33.0` tracker:

```
--- FAIL: TestReleasingLastAddressRemovesKey
    stale key {handle:lb-old-uid name:envoy namespace:tigera-gateway} is still tracked with 0 addresses; syncIPAM will keep syncing it against the live Service
```

and with the patch all three tests pass. Fix 2 alone does not stop the *flip*
(a stale key that still has an allocation keeps rewriting the status); Fix 1
does.

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

The alternation between the two addresses is explained by the "Root cause"
section above (the stale key's handler rewrites the live Service's status).

---

## 2. Calico issue B: periodic sync clears `status.loadBalancer.ingress` of a healthy Service

**Title:** kube-controllers LoadBalancer controller writes an empty
`status.loadBalancer.ingress` ("Assigned IPs []") for a Service that already has
its address, every periodic sync

### Summary

With the leaked allocation from issue A released, every Service in the pool
has exactly one allocation matching its status. Even so, the LoadBalancer
controller briefly **clears** the Service's `status.loadBalancer.ingress` and
then restores it 1-2 seconds later (until kube-controllers is restarted). It happens on the controller's 5-minute
periodic sync and also on some event-driven reconciles. Any consumer of the
Service/Gateway address (here: external-dns, an Envoy Gateway `Gateway`'s
`status.addresses`) sees the address disappear and reappear.

### Reproduction (as understood; step 2 is untested)

The clear needs a stale tracker key for a Service name that is still in use,
which is what an allocation leaked across a Service recreate and then released
leaves behind. A single healthy Service does not clear.

1. Have a `type: LoadBalancer` Service `S` with a Calico-assigned address
   (`loadBalancerClass: calico`, a `LoadBalancer`-use pool, `assignIPs:
   AllServices`).
2. Leak an allocation for an earlier UID of `S`. We do not know how this
   happened on our cluster (see issue A). One untested way to try: stop
   kube-controllers, delete and recreate `S`, restart kube-controllers.
3. Release the leaked allocation: `calicoctl ipam release --ip=<leaked-ip>`.
4. Watch `S`:
   `kubectl get svc -n <ns> <name> -w -o jsonpath='{.metadata.name} {.status.loadBalancer.ingress[*].ip}{"\n"}'`
   and note the status going empty on each periodic sync (5 minutes) and on
   IPAM block updates, until `calico-kube-controllers` is restarted.

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

### Cause

See "Root cause" above. The empty write comes from the stale tracker key left
behind (as an empty entry) after the leaked allocation was released, not from
`assignIP` returning an empty slice. An earlier hypothesis in this document
that `assignIP`'s empty return value was written to the status was wrong: the
status is built from the tracker entry for the key being synced.

### Impact

- The Service's `status.loadBalancer.ingress` and any resource derived from it
  (here: Envoy Gateway `Gateway.status.addresses`) are empty for 1-2 seconds
  every few minutes.
- Controllers that publish the address externally (external-dns) can observe
  the empty state. See section 3.

### Workaround

Release the leaked allocation, then restart `calico-kube-controllers` so its
in-memory tracker is rebuilt without the stale key:

```
calicoctl ipam release --ip=<leaked-ip>
kubectl delete pod -n calico-system -l k8s-app=calico-kube-controllers
```

Releasing alone removed the address flip but not the clear; the restart removed
the clear. The condition returns if a Service is recreated under the same name
and leaks again.

### Questions for maintainers

- Is the by-name lookup in `syncService` intended, or should it verify the
  handle? (By source review the same code is present in v3.32.2, v3.33.0 and
  `master`; see "Newer releases" above.)
- Should releasing an allocation also remove the empty `ipsByService` entry?

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
- The creation of the leaked allocation was not captured; the rest of the root cause was read from the v3.32.1 source and confirmed by restarting kube-controllers (one periodic sync observed afterward).
- Newer releases were reviewed by reading source only, not run (see "Newer releases" above).
- The creation event of the leaked allocation (issue A) was not captured.
- A search of the upstream issue tracker for these symptoms found no matching
  issue; the nearest, [#10412](https://github.com/projectcalico/calico/issues/10412)
  (IPv6 address missing from an `apiserver-calico` Service), shows the same
  "No new IPs to assign" log line but a different symptom.
