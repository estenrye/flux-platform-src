---
name: external-dns-multi-instance-collision
description: Two external-dns Helm releases in one cluster/namespace need distinct releaseName, not just kustomize nameSuffix, or pod selector labels collide
metadata:
  type: project
---

Hit while adding `applications/external-dns/cloudflare/controlplane`
(M2 step 9, 2026-07-20/21) alongside the already-running
`external-dns/unifi/base` on `controlplane` — both in namespace
`external-dns`.

`applications/external-dns/{unifi,cloudflare,aws}/base/kustomization.yaml`
all hardcode `helmCharts[0].releaseName: external-dns`. Referencing
`../base` as a plain `resources:` entry from a new overlay (the pattern
used for every other provider-variant app in this repo — cert-manager,
step-ca, etc.) doesn't help here: by the time Kustomize sees it, Helm
has already rendered with base's hardcoded release name, so the
Service/ServiceAccount/ClusterRole/ClusterRoleBinding all come out
named `external-dns` — identical to the other instance already in that
namespace.

A `nameSuffix` transform on the overlay looked like the obvious fix but
doesn't actually work: it only renames `metadata.name`, not the
Helm-templated `app.kubernetes.io/instance` **label** baked into the
pod template (and into the Service's selector) at Helm-render time.
Two instances would end up with uniquely-named but identically-labeled
Services, each silently selecting *both* deployments' pods.

**Fix**: don't reference `../base` as a resource at all. Declare an
independent `helmCharts` block in the new overlay with its own
`releaseName` (`external-dns-cloudflare` for the controlplane variant),
own `values.yaml` (content copied from base, not shared), own
`patches/deployment.yaml`/`patches/cluster-role.yaml`, and own
`resources/network-policy.yaml` with `podSelector` updated to the new
instance name. This is more duplication than the normal
overlay-patches-base pattern, but it's the only way to get distinct
`app.kubernetes.io/instance` labels and thus distinct Service/
NetworkPolicy selection.

**Also watch for**: `includeCRDs: true` on both — Kustomize refuses to
accumulate the same CRD id (`dnsendpoints.externaldns.k8s.io`) from two
sources in one cluster build. Only one instance in the cluster needs
`includeCRDs: true`; set it `false` on every other one.

Two more real bugs found only because this was actually deployed for
the first time (both `cloudflare/base` and `cloudflare/controlplane`
had been dead code until this session):
- `extraArgs: [--enable-leader-election]` in `cloudflare/base/values.yaml`
  crashes chart version 1.20.0 outright (`unknown long flag`) — that
  flag doesn't exist in this chart version at all (confirmed against
  its own templates, no matching values key either). Removed from both
  base and the controlplane copy; `unifi/base` runs 3 replicas fine
  with no leader-election mechanism at all, so this wasn't papering
  over a real correctness need.
- The NetworkPolicy copied from base only allowed egress to port 443
  for apiserver access — Talos serves the apiserver on 6443, not 443
  (see [[calico-networkpolicy-dnat]]); `unifi/base`'s otherwise-identical
  NetworkPolicy already had the 6443 rule, which is what gave away the
  fix.
