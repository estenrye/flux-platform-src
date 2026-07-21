---
name: calico-networkpolicy-dnat
description: Calico evaluates egress NetworkPolicy post-DNAT; service port ≠ pod port in egress rules
metadata:
  type: project
---

When writing egress NetworkPolicy rules for pods that connect to Kubernetes Services via a ClusterIP, Calico applies policy in the iptables FORWARD chain — which runs **after** kube-proxy's DNAT in PREROUTING. This means:

- The **service port** (e.g., 443) is already rewritten to the **pod's targetPort** (e.g., 9000) before Calico evaluates egress.
- An egress rule allowing port 443 does NOT cover traffic to a pod listening on port 9000, even if the service maps 443→9000.
- To allow egress to a service, the egress rule must list the **pod's targetPort**, not the service port.

**Why:** Observed when debugging the `step-ca` Helm test pod. The pod connects to `step-certificates:443` (service), which routes to pod port 9000. The egress rule only listed port 443, so Calico dropped the traffic post-DNAT.

**How to apply:** When writing NetworkPolicy egress rules on this cluster (Calico CNI), always use the pod's container port, not the service port. If a service maps `443 → 9000`, the egress rule needs `port: 9000`.

**The apiserver is the sneakiest instance** (bit ESO during M2, 2026-07-14):
`kubernetes.default` ClusterIP:443 DNATs to the node apiserver endpoint —
**6443 on Talos**, but 443 on managed clusters (Rackspace Spot), so a
controller that worked on Spot crash-loops on `controlplane` with apiserver
i/o timeouts. Every controller namespace on a Talos cluster needs egress
TCP 6443 (see the envoy-gateway/cnpg/reloader/ESO base NPs for the
comment convention). Symptom signature: pod logs show
`dial tcp [<service-CIDR>::1]:443: i/o timeout`.

Related fix: the test pod had the same labels as the server pod (`app.kubernetes.io/name: step-certificates`), making it subject to the same NetworkPolicy. A targeted egress rule was added to allow traffic between step-certificates pods on port 9000.
