# xnetworksegment examples

`example-claim.yaml` is illustrative only — **not wired into any live cluster's kustomization tree**, same as `xkubernetescluster/examples/`. It's also the real values for `observability`'s segment, kept in sync by hand with the live claim the same way `xkubernetescluster/examples/example-claim.yaml` is.

Applying it for real requires, in order:

1. `provider-ansible`, `provider-terraform`, and `function-extra-resources` all `Healthy` on `controlplane`.
2. The `unifi` `ClusterProviderConfig` (`clusters/controlplane/crossplane-resources/provider-config.unifi.yaml`) — which itself needs a UniFi API key minted and stored in OpenBao at `provider-terraform/unifi-api-key` (not yet done; mirror `.bin/bootstrap-provider-terraform-kvm-key.sh`'s pattern for a new credential).
3. This claim, applied before (or alongside) the referencing `XKubernetesCluster` claim gets its `spec.vlanRef` set — the cluster's `create-workspace` step waits on `status.ready` here before creating VMs.

## Monitoring a real claim

```sh
kubectl get xnetworksegment observability-vlan
kubectl describe xnetworksegment observability-vlan
kubectl get ansiblerun observability-vlan-bridge
kubectl get workspace.tf.upbound.io observability-vlan-vlan
```

## Known unverified points (check live before trusting)

- `provider-ansible`'s `credentials[]` file materialization for a bare SSH key reference (`ansible_ssh_private_key_file=kvm-ssh-key`) — confirmed for git-credentials, not independently confirmed for this use.
- `filipowm/unifi`'s `file("unifi-api-key")` read inside the shared `configuration` HCL block (`provider-config.unifi.yaml`) — reasoned by analogy to the KVM ProviderConfig's `keyfile=` pattern, not yet tested live.
- The `function-extra-resources` `Selector` matching semantics when the only `matchLabels` entry is dropped by `fromFieldPathPolicy: Optional` (a claim with no `vlanRef` set) — see the comment at `cluster-talos-kvm-composition.yaml`'s `fetch-network-segment` step.
