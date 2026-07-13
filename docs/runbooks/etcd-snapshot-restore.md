# Runbook: etcd snapshot & restore (`controlplane`)

Snapshots are the crown-jewel backup (M1 design §5.3): 6-hourly via the
host timer (`providers/kvm/scripts/etcd-snapshot.*`) to the TrueNAS NFS
export, 14-day retention; ad-hoc via `.bin/backup-controlplane-etcd.sh`.
This procedure MUST be exercised once before M1 closes (exit criterion).

## Take a snapshot

```sh
.bin/backup-controlplane-etcd.sh          # writes ./etcd-backups/controlplane-etcd-<ts>.snapshot
```

## Restore onto a rebuilt cluster (DR drill = exactly this)

Machine secrets in `clusters/controlplane/secrets/talos-secrets.sops.yaml`
survive teardown, so the rebuilt cluster keeps the same CA and node identity.

1. Tear down and rebuild, stopping before workloads matter:

   ```sh
   # The NAT64 appliance is a SEPARATE module and survives the cluster
   # teardown — do NOT destroy it (the rebuild pulls the Talos installer
   # through it). If it is somehow down, bring it back first:
   #   .bin/create-nat64.sh
   .bin/destroy-controlplane-cluster.sh

   # Rebuild AND recover etcd in one shot: RECOVER_FROM makes the create
   # script initialize etcd from the snapshot instead of bootstrapping empty.
   RECOVER_FROM=./etcd-backups/controlplane-etcd-<ts>.snapshot \
     .bin/create-controlplane-cluster.sh
   ```

   The script uploads the snapshot and recovers via `talosctl bootstrap
   --recover-from` on the first control plane node, so etcd is never empty.
   (Manual equivalent, if not using the script:
   `talosctl -n fd97:45c2:b3a1:100::11 bootstrap --recover-from=<snapshot>`.)

2. Watch the other control plane nodes rejoin (cp-2/cp-3 join as learners,
   then auto-promote to voting members):

   ```sh
   talosctl --talosconfig ~/.talos/homelab-controlplane.yaml \
     -n fd97:45c2:b3a1:100::11 -e fd97:45c2:b3a1:100::11 etcd members
   ```

3. Verify convergence: nodes go Ready once Calico reconciles, Flux
   Kustomization Ready (`flux get kustomizations -A`), `talosctl health`
   clean, and the chainsaw baseline suites pass
   (`.bin/run-controlplane-baseline.sh`).

## Proving a restore (DR drill)

To prove the restore worked — not just that the cluster rebuilt and Flux
re-converged from git — plant a marker that lives ONLY in etcd before the
snapshot, and check it comes back:

```sh
kubectl create configmap dr-marker -n kube-system --from-literal=stamp="$(date -u +%s)"
.bin/backup-controlplane-etcd.sh          # snapshot now contains the marker
# ... destroy + RECOVER_FROM rebuild ...
kubectl get cm dr-marker -n kube-system   # present == etcd was restored
kubectl delete cm dr-marker -n kube-system
```

Exercised successfully 2026-07-13: full teardown + RECOVER_FROM rebuild,
marker recovered, 6/6 nodes Ready and all four baseline suites green.

## Prove a snapshot is usable (cheap check between drills)

```sh
talosctl -n fd97:45c2:b3a1:100::11 etcd snapshot /tmp/probe.snapshot
etcdutl snapshot status /tmp/probe.snapshot   # or: etcdctl snapshot status
```
