---
name: cluster-kubeconfig-lookup
description: Authoritative source for cluster kubeconfig paths is clusters/<name>/catalog.yaml rye.ninja/kubeconfig annotation
metadata:
  type: reference
---

# Cluster Kubeconfig Lookup

The authoritative source for which kubeconfig file to use to connect to a cluster is the `rye.ninja/kubeconfig` annotation in `clusters/<cluster-name>/catalog.yaml`.

For example, the ryezone-labs crossplane cluster uses:

```sh
export KUBECONFIG=~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
```

as documented in `clusters/crossplane/catalog.yaml`.
