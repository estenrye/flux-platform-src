# controlplane baseline suites

Chainsaw contract suites for the `controlplane` cluster (M1 design §9).
All four green + a completed DR drill = M1 exit criteria.

Run them with:

```sh
.bin/run-controlplane-baseline.sh
```

The runner resolves the kubeconfig from the `rye.ninja/kubeconfig` annotation
in [clusters/controlplane/catalog.yaml](../../clusters/controlplane/catalog.yaml)
and exports [values/controlplane.env](values/controlplane.env) to the suites.

| Suite | Contract |
|---|---|
| [network](network/chainsaw-test.yaml) | Cross-node v6 pod traffic over the Calico BGP mesh; v6-native egress; egress to an IPv4-only endpoint via DNS64+NAT64 (asserts the `64:ff9b::` prefix was used); behavioral default-deny (ADR-17) |
| [storage](storage/chainsaw-test.yaml) | `truenas-iscsi` bind+write (iSCSI over IPv6), online expansion, data survives rescheduling across nodes; `truenas-nfs` concurrent cross-node RWX |
| [lb](lb/chainsaw-test.yaml) | Calico LB IPAM assigns VIPs from the correct pools (ULA internal, GUA ingress); both reachable from the runner's VLAN — proving BGP advertisement + gateway redistribution |
| [flux](flux/chainsaw-test.yaml) | Baseline GitRepository/Kustomization healthy; deleted workload restored on forced reconcile |

Notes:

- The lb suite's reachability check runs from the workstation, which is a
  different VLAN by design — it is the cross-VLAN vantage the design asks
  for. From-the-internet verification of GUA VIPs stays manual until an
  external vantage exists (M5/M6).
- Suites create everything in ephemeral chainsaw namespaces, which are
  subject to the default-deny GlobalNetworkPolicy — allow policies ship in
  each suite's `resources/`.
