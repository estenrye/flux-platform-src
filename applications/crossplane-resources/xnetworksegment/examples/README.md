# xnetworksegment examples

`example-claim.yaml` is illustrative only — **not wired into any live cluster's kustomization tree**, same as `xkubernetescluster/examples/`. It's also the real values for the live `vlan100` claim, kept in sync by hand the same way `xkubernetescluster/examples/example-claim.yaml` is.

This claim **adopts** controlplane's own pre-existing VLAN 100 bridge (`br0`) rather than creating a new one — no `unifiNetworkRef`, since VLAN 100's UniFi network already exists, hand-configured outside this repo. `bridgeName`/`taggedVlan`/`bondInterface` exist specifically to support this case; see their descriptions in `../xrd.yaml`. Note `br0` also carries the KVM host's own management/SSH traffic — before ever applying a change like this for real, verify it with a `netplan generate` dry-run against an isolated `--root-dir` first (no real state touched), the same way this claim's own initial rollout was verified.

Applying a *new* (not adopted) segment for real requires, in order:

1. `provider-ansible` and `function-extra-resources` `Healthy` on `controlplane`.
2. If `unifiNetworkRef` is set: the referenced `XUnifiNetwork` claim applied first (see `../../xunifinetwork/examples/README.md` for its own prerequisites) — this segment's `status.ready` waits on that claim's `status.ready`. If reusing an already-existing UniFi network instead (e.g. VLAN 100, this claim's own case), omit `unifiNetworkRef` entirely and skip this.
3. This claim, applied before (or alongside) any referencing `XKubernetesCluster` claim gets its `spec.vlanRef` set — the cluster's `create-workspace` step waits on `status.ready` here before creating VMs.

## Monitoring a real claim

```sh
kubectl get xnetworksegment vlan100
kubectl describe xnetworksegment vlan100
kubectl get ansiblerun vlan100-bridge
kubectl get xunifinetwork vlan100  # only if unifiNetworkRef is set -- it isn't for vlan100 itself
```

If `unifiNetworkRef` is set, `kubectl describe`'s conditions will also show a `UnifiNetworkMatch` condition (set by `composition.yaml`'s `validate-unifi-network-match` step) — `False` means this claim's `vlanId` doesn't agree with the referenced `XUnifiNetwork`'s own `vlanId`. This is informational only today — it does not block the bridge from being created.

## Known unverified points (check live before trusting)

- `provider-ansible`'s `credentials[]` file materialization for a bare SSH key reference (`ansible_ssh_private_key_file=kvm-ssh-key`) — confirmed for git-credentials, not independently confirmed for this use.
- The `function-extra-resources` `Selector` matching semantics when the only `matchLabels` entry is dropped by `fromFieldPathPolicy: Optional` (a claim with no `unifiNetworkRef` set) — see the comment at `composition.yaml`'s `fetch-unifi-network` step, mirroring the same unverified point already flagged for `xkubernetescluster-composition.yaml`'s `fetch-network-segment` step.
- `AnsibleRun`'s default `deletionPolicy: Orphan` means deleting this claim never removes `/etc/netplan/60-br0.yaml` from the host or reverts `br0` -- confirmed intentional, not a gap (`docs/memory/provider-ansible-delete-cleanup-broken.md`: the alternative, delete-triggered cleanup, is confirmed broken upstream as of provider-ansible v0.8.0).
