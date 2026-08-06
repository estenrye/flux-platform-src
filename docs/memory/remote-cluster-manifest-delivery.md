---
name: remote-cluster-manifest-delivery
description: How to apply manifests to a cluster with no Flux instance of its own (e.g. observability) -- kustomize build + generated provider-kubernetes Objects, not provider-helm
metadata:
  type: reference
---

A cluster provisioned via `XKubernetesCluster` (e.g. `observability`) has no
Flux instance running on it -- Flux's `kustomize-controller` always applies
to the same cluster it runs in (`controlplane`), and pushing a second Flux
instance onto a new cluster is real, unbuilt work (no precedent in this
repo as of 2026-08-06). Until that exists, manifests reach a remote
cluster's API server via:

1. A `kubernetes.m.crossplane.io/v1alpha1` `ClusterProviderConfig` with
   `spec.credentials: {source: Secret, secretRef: {...}}` pointing at that
   cluster's own kubeconfig Secret (e.g. `observability-kubeconfig`,
   written by the bootstrap Job) -- confirmed live via `kubectl explain
   clusterproviderconfigs.kubernetes.m.crossplane.io.spec.credentials`.
2. `provider-kubernetes`'s `Object` resource wraps exactly **one** manifest
   each (`spec.forProvider.manifest`, confirmed via `kubectl explain
   objects.kubernetes.m.crossplane.io.spec.forProvider` -- no bulk/
   multi-document apply). A real application (e.g. Calico's
   tigera-operator chart) can be dozens of resources -- hand-wrapping each
   individually doesn't scale.
3. So: write a normal kustomize directory for the target app (e.g.
   `applications/calico/observability/`, mirroring an existing
   Flux-managed one like `applications/calico/controlplane/`), render it
   *statically* with `kustomize build --enable-helm` (same mechanism
   `make render-manifests` already uses -- no live cluster needed), then
   run `.bin/render/render-remote-objects.sh <dir> <provider-config-name>
   <output-file>` to wrap every resulting document as an individual
   `Object` targeting that `ClusterProviderConfig`. Commit the generated
   output file and wire it into `controlplane`'s own Flux tree (it runs
   *on* controlplane, each `Object` reaches *out* to the remote cluster).

**Why not `provider-helm`:** considered first, rejected -- would be a
brand-new, never-tested-in-this-fleet provider dependency, right after a
session's worth of "don't trust unverified provider behavior" lessons
(`docs/memory/provider-ansible-delete-cleanup-broken.md`, the
`ansible_provider_meta` key-format surprise). The kustomize + generated-
Objects path reuses tooling (`kustomize`, the same render step) already
proven in this repo's own CI, with zero new dependencies.

**Why this is smaller than it sounds:** Tigera's chart only ships the
*operator* (Namespace, ServiceAccount, ClusterRole(s), ClusterRoleBinding,
RoleBinding, Deployment) plus a handful of custom resources
(`Installation`, `APIServer`, etc., `operator.tigera.io` group) telling it
what to reconcile -- `manageCRDs: true` in the chart's own `values.yaml`
means the operator manages its *own* CRDs at runtime, not the chart.
`observability`'s render came to 13 total resources, not 50+.

**How to apply:** For any future app that needs to reach a cluster with no
Flux of its own, follow the same three steps -- don't reach for
`provider-helm` or hand-wrapped Objects as the default. If a cluster later
gets a real Flux instance of its own, these generated Objects should be
retired in favor of that cluster's own GitOps reconciliation, not left
running in parallel.
