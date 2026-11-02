---
name: kube-proxy-clustercidr-masquerade
description: core-infra kube-proxy masqueraded pod-sourced ClusterIP traffic (clusterCIDR was Talos podSubnets, not the Calico pool); sender-based NetworkPolicies failed across nodes; fixed in pcd-ce-deploy talos.tf (2026-10-31)
metadata:
  type: project
---

On core-infra, kube-proxy's `clusterCIDR` defaulted to Talos `podSubnets` (`fd10:244::/56`, tofu `var.pod_subnet`), but pods get addresses from the Calico pool `fd00:db8:0:1100::/56`. kube-proxy therefore saw every real pod as an outside client and masqueraded its Service (ClusterIP) traffic to the **sending node's IP**. A backend received cross-node Service calls from a node address, so NetworkPolicy ingress rules that match the sender (`podSelector` / `namespaceSelector`) never matched.

**Symptom signature:** connections to a ClusterIP time out only when the client and backend are on different nodes (same-node works: Calico always allows local-host traffic), and only when the backend pod has a sender-based ingress policy. Connecting to the backend's pod IP directly works. Hit by `seaweedfs-db-rw` (CNPG replica joins, filer-1) and `seaweedfs-s3`. It had been latent: core-infra has no default-deny, so most pods have no ingress policy.

**Why:** `pod_subnet` was documented as a harmless "internal overlay", but Talos derives kube-proxy's `clusterCIDR` (and kube-controller-manager's `--cluster-cidr`) from it. OpenStack security groups were not involved (`cluster_internal_ingress` and `pod_pool_ingress` already allow node and pod traffic).

**Proof method:** a server pod on node A, a client pod on node B, a Service in front; the python `http.server` log shows the source address. Via the Service it logged the client's node IP; direct to the pod IP it logged the pod IP. After the fix both show the pod IP.

**Fix** (pcd-ce-deploy `tofu-pcd-talos-cluster/talos.tf`): a `KubeProxyConfig` document with `config.clusterCIDR` set from `local.pod_pool_cidrs`. Gotchas learned rolling it out:
- `KubeProxyConfig` is **control-plane only**; Talos rejects it on workers ("only allowed on control plane machines"), so it must not be in the common patches.
- Talos fills `clusterCIDR` from `podSubnets` only when the user hasn't set it, so the override is clean and `podSubnets` stays untouched.
- Talos's bootstrap manifest apply is **create-once**: a config change creates a new checksum-named ConfigMap (`kube-proxy-config-<16 hex>`) but never updates the existing DaemonSet. Repoint the DaemonSet's `config` volume at the new ConfigMap with `kubectl patch`; it rolls one node at a time. The old ConfigMap is kept, so rollback is repointing back.
- Do **not** run `talosctl upgrade-k8s` to sync it: the dry-run showed 32 hunks that would revert in-cluster changes to the Calico Installation, Spegel, and cinder-csi manifests. `--cluster-cidr` via `extraArgs` is ignored because kube-proxy runs with `--config`.

**How to apply:** if a cross-node ClusterIP call times out under a sender-based NetworkPolicy, first check whether the source address the backend sees is a node IP; if so suspect kube-proxy masquerading before adding policy exceptions. Related: [[calico-networkpolicy-dnat]] (egress is evaluated post-DNAT).
