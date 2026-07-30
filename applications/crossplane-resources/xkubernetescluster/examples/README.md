# xkubernetescluster examples

`example-claim.yaml` is illustrative only — **not wired into any live cluster's kustomization tree**, same as `delegated-hosted-zone-aws/examples/`. Applying it for real requires:

- A `platform-kvm-network` `EnvironmentConfig` entry for the claim's `metadata.name` (`clusters/controlplane/crossplane-resources/crossplane.environment-config.kvm-network.yaml`) — the Composition's `validate-network-allocation` step fails the claim otherwise.
- `provider-terraform`, `provider-kubernetes`, and the `talos-cluster-bootstrap` app all `Healthy`/applied on `controlplane`.

## Monitoring a real claim

```sh
kubectl get xkubernetescluster observability -n crossplane-system
kubectl describe xkubernetescluster observability -n crossplane-system
kubectl get workspace.tf.upbound.io observability
kubectl get object.kubernetes.crossplane.io observability-bootstrap
kubectl -n crossplane-system get job observability-bootstrap
kubectl -n crossplane-system logs -l job-name=observability-bootstrap -f
```

## Troubleshooting

- `phase: PendingNetworkAllocation` stuck — check `kubectl describe xkubernetescluster <name>` for the `NetworkAllocationResolved` claim condition; add the missing `platform-kvm-network` entry.
- `Workspace` not progressing — `kubectl describe workspace.tf.upbound.io <name>`; `provider-terraform` itself must be `Healthy` first (`kubectl get provider provider-terraform`).
- Bootstrap `Job` failing — `kubectl -n crossplane-system logs -l job-name=<name>-bootstrap`; the script is a close port of `.bin/create-controlplane-cluster.sh`, so failure modes there generally apply here too.
