# xunifinetwork examples

`example-claim.yaml` is illustrative only — **not wired into any live cluster's kustomization tree**, same as `xnetworksegment/examples/`. It's also the real values for `observability`'s network, kept in sync by hand with the live claim the same way `xnetworksegment/examples/example-claim.yaml` is.

This resource was split out of `xnetworksegment/composition.yaml` on 2026-08-06 so a segment's KVM-host bridge and its UniFi network object have independent lifecycles. Applying it for real requires, in order:

1. `provider-terraform` and `function-extra-resources` `Healthy` on `controlplane`.
2. The `unifi` `ClusterProviderConfig` (`clusters/controlplane/crossplane-resources/provider-config.unifi.yaml`).
3. This claim, applied before (or alongside) the referencing `XNetworkSegment` claim gets its `spec.unifiNetworkRef` set — the segment's `status.ready` waits on this claim's `status.ready`.

A segment reusing an already-existing UniFi network (e.g. VLAN 100) has no corresponding `XUnifiNetwork` claim at all — `unifiNetworkRef` stays unset on the `XNetworkSegment` side, and this Composition never runs for that segment.

## Monitoring a real claim

```sh
kubectl get xunifinetwork observability-vlan
kubectl describe xunifinetwork observability-vlan
kubectl get workspace.tf.upbound.io observability-vlan-vlan
```
