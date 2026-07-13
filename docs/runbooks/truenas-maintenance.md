# Runbook: TrueNAS maintenance (`nas.rye.ninja`)

TrueNAS is the storage SPOF for on-prem clusters (ADR-21): PVC data
(iSCSI zvols + NFS), etcd snapshots, and ZFS replication targets all live
on it. Plan maintenance windows accordingly.

## What breaks when TrueNAS is down

| Consumer | Impact |
|---|---|
| PVC-backed workloads | I/O stalls; pods with mounted volumes hang until it returns (NFS hard mounts by design) |
| New PVCs / expansion | Fail until the websocket API is back |
| etcd snapshots (6 h timer) | Skipped runs; etcd itself is unaffected (local to VMs) |
| ZFS replication (nightly) | Skipped runs; retried next night |
| The cluster itself | Keeps running — control plane state is on VM-local zvols, not TrueNAS |

## Before a planned reboot/upgrade

1. Pick a window away from the timers (etcd snapshots at :15 every 6 h,
   replication 02:30 UTC).
2. Scale down or quiesce heavily-writing PVC workloads if the window is
   long (NFS hard mounts survive short windows transparently).
3. Take an ad-hoc etcd snapshot first: `.bin/backup-controlplane-etcd.sh`
   (lands locally — TrueNAS being the normal destination is the point).
4. TrueNAS UI → Update. ZFS pool upgrades: do NOT `zpool upgrade`
   immediately after a TrueNAS update; wait a release unless a needed
   feature demands it (keeps rollback possible).

## After

1. Verify services: iSCSI + NFS running, portal listening:
   `curl -sk https://nas.rye.ninja/api/current` answers; from a node VLAN
   vantage, TCP 3260 and 2049 reachable on `fd97:45c2:b3a1:100::1000`.
2. Verify mounts recovered: `kubectl get volumeattachments`; spot-check a
   PVC pod writes.
3. Run the storage suite: `.bin/run-controlplane-baseline.sh storage`.
4. Check the timers caught up on the next cycle (`systemctl list-timers`
   on the KVM host; snapshot files appearing in the NFS export).

## Credential rotation

The CSI API key belongs to the dedicated `csi-controlplane` user (Full
Admin). To rotate: mint a new key in the TrueNAS UI, store it at
`op://controlplane/truenas-api-key/credential`, then re-encrypt the
secret (same flow as creation — the key is piped from 1Password into
sops, never written to disk) and let Flux roll it out. Rotation machinery
formalizes in M3 (ADR-15).

## Capacity watch

`flash-pool` also carries VM-zvol replicas (7 daily + 4 weekly of
`vmpool/vms`). If the pool passes ~80%, prune replication retention
before touching PVC data.
