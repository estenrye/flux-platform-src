# xnetworksegment examples

`example-claim.yaml` is illustrative only — **not wired into any live cluster's kustomization tree**, same as `xkubernetescluster/examples/`. It's also the real values for `observability`'s segment, kept in sync by hand with the live claim the same way `xkubernetescluster/examples/example-claim.yaml` is.

Since 2026-08-06 this Composition only creates the KVM-host bridge — the UniFi network/VLAN object is a separate `XUnifiNetwork` claim (`../../xunifinetwork/examples/example-claim.yaml`), optionally referenced via `spec.unifiNetworkRef`. Applying this claim for real requires, in order:

1. `provider-ansible` and `function-extra-resources` `Healthy` on `controlplane`.
2. If `unifiNetworkRef` is set: the referenced `XUnifiNetwork` claim applied first (see `xunifinetwork/examples/README.md` for its own prerequisites) — this segment's `status.ready` waits on that claim's `status.ready`. If reusing an already-existing UniFi network instead (e.g. VLAN 100), omit `unifiNetworkRef` entirely and skip this.
3. This claim, applied before (or alongside) the referencing `XKubernetesCluster` claim gets its `spec.vlanRef` set — the cluster's `create-workspace` step waits on `status.ready` here before creating VMs.

## Monitoring a real claim

```sh
kubectl get xnetworksegment observability-vlan
kubectl describe xnetworksegment observability-vlan
kubectl get ansiblerun observability-vlan-bridge
kubectl get xunifinetwork observability-vlan  # only if unifiNetworkRef is set
```

If `unifiNetworkRef` is set, `kubectl describe`'s conditions will also show a `UnifiNetworkMatch` condition (set by `composition.yaml`'s `validate-unifi-network-match` step) — `False` means this claim's `vlanId` or one of its `addresses` doesn't agree with the referenced `XUnifiNetwork`'s own `vlanId`/`infraSubnet`, with a message naming the specific mismatch. This is informational only today — it does not block the bridge from being created.

## Known unverified points (check live before trusting)

- `provider-ansible`'s `credentials[]` file materialization for a bare SSH key reference (`ansible_ssh_private_key_file=kvm-ssh-key`) — confirmed for git-credentials, not independently confirmed for this use.
- The `function-extra-resources` `Selector` matching semantics when the only `matchLabels` entry is dropped by `fromFieldPathPolicy: Optional` (a claim with no `unifiNetworkRef` set) — see the comment at `composition.yaml`'s `fetch-unifi-network` step, mirroring the same unverified point already flagged for `xkubernetescluster-composition.yaml`'s `fetch-network-segment` step.
