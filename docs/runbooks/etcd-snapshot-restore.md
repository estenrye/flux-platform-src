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
   .bin/destroy-controlplane-cluster.sh
   .bin/create-controlplane-cluster.sh
   ```

2. **Do not let the empty cluster be treated as truth.** Immediately recover
   etcd from the snapshot (single-node recovery, then rejoin the others):

   ```sh
   export TALOSCONFIG=~/.talos/homelab-controlplane.yaml
   talosctl -n fd97:45c2:b3a1:100::11 etcd recover ./etcd-backups/controlplane-etcd-<ts>.snapshot
   talosctl -n fd97:45c2:b3a1:100::11 bootstrap --recover-from=./etcd-backups/controlplane-etcd-<ts>.snapshot
   ```

   (On the current Talos release `bootstrap --recover-from` uploads and
   recovers in one step; check `talosctl bootstrap -h` after upgrades.)

3. Watch the other control plane nodes rejoin:

   ```sh
   talosctl -n fd97:45c2:b3a1:100::11,fd97:45c2:b3a1:100::12,fd97:45c2:b3a1:100::13 etcd status
   ```

4. Verify convergence: Flux reconciles the baseline
   (`flux get kustomizations -A`), nodes go Ready once Calico is back,
   `talosctl health` clean, chainsaw baseline suites green.

## Prove a snapshot is usable (cheap check between drills)

```sh
talosctl -n fd97:45c2:b3a1:100::11 etcd snapshot /tmp/probe.snapshot
etcdutl snapshot status /tmp/probe.snapshot   # or: etcdctl snapshot status
```
