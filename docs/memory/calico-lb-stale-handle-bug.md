---
name: calico-lb-stale-handle-bug
description: Calico kube-controllers (3.32.1, 3.32.2, 3.33.0) applies a stale IPAM handle key to a recreated same-name Service, flipping then clearing its LoadBalancer status; detect, release, and workaround targets exist
metadata:
  type: project
---

Root cause (read from `loadbalancer_controller.go`, confirmed by experiment): a Service recreated under the same name has a new UID, so a new IPAM handle. If the old allocation leaks (the delete was missed while kube-controllers was down), the tracker holds two keys for one `namespace/name`. `syncIPAM` syncs every tracker key and `syncService` looks the Service up **by name only**, so the stale key rewrites the live Service's `status.loadBalancer.ingress`: a flip between the two addresses while the stale allocation exists, then an empty status (1-2 s, on every IPAM sync and block update) after it is released out of band, because `releaseAddressFromService` leaves an empty tracker entry. Not fixed in 3.32.2, 3.33.0 or master; confirmed `BUG PRESENT` at runtime on all three (2026-10-25).

**Why it matters here:** the netdata Gateway's address flapped, and external-dns published a wrong then empty address. It leaked on 2026-10-22 when Envoy Gateway recreated the Service; nothing flagged it for 3 days.

**How to apply:**
- Detect: `CLUSTER=core-infra make detect-calico-ipam-flapping` (add `WATCH=330` for the live watch).
- Fix a leak: `CLUSTER=core-infra IP=<ip> make release-calico-ipam-allocation` (refuses anything a live Service uses), **then restart `calico-kube-controllers`** (`kubectl delete pod -n calico-system -l k8s-app=calico-kube-controllers`). Releasing alone removes the flip but leaves the clear; the restart removes the clear.
- Re-validate a new Calico version: `CLUSTER=core-infra make reproduce-calico-lb-stale-handle` (about 6 minutes; briefly force-kills kube-controllers; uses a throwaway Service).
- Do not upgrade Calico expecting this to be fixed. Full write-up, evidence and proposed patches (one tested in isolation) are in `docs/research/calico-bgp-iam-flap-ipv6.md`; nothing has been filed upstream.

Related: [[calico-operator-digest-pin]], [[external-dns-multi-instance-collision]].
