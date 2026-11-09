---
name: core-infra-nfs-outage-2026-11
description: Nov 2026 core-infra outage — Cinder/NFS loss wedged the Talos boot disks (Cinder root volumes), etcd lost quorum for ~71h; recovered by Nova hard reboots; open hardening items
metadata:
  type: project
---

# core-infra outage after Cinder lost nfs.nas.rye.ninja (found 2026-11-08)

## What happened
- The PCD Cinder NFS backend lost the NAS. All 8 Talos VMs (3 CP + 5 workers)
  boot from **Cinder root volumes** (`vda`, 22 GB, virtio), so the loss hit the
  **node OS disks**, not just PVCs.
- Nova kept every VM `ACTIVE`/power-state 1 — the outage was invisible there.
- Inside the nodes: `input/output error` on `/var`, `/var/lib/etcd/member/snap`,
  `/var/run/wireguard`; containerd (`mkdir /var: file exists`) and etcd
  (`failed rootfs umount … input/output error`) could not restart.
- etcd lost quorum ~71h before detection (health check failing since
  2026-11-05). API VIP `fd97:45c2:b3a1:1179::2c2` stayed down; all workers
  NotReady; CNPG, Grafana, Keycloak, SeaweedFS affected.
- By the time of investigation Cinder had already recovered
  (`truenas-nova`/`truenas-glance` volume services up). The nodes stayed wedged:
  the disks never recovered without a power cycle.

## Resolution (2026-11-08/09)
1. `talosctl reboot` (graceful) hung in stage `rebooting` for 7+ min — Talos
   cannot unmount wedged filesystems.
2. `openstack server reboot --hard <vm>` on the PCD host, one node at a time:
   CP-2 → CP-3 → CP-1 (etcd regained quorum after the second; leader elected,
   DB 72 MB, no data loss observed), then workers 1–5, each waited to `Ready`.
3. CNPG clusters (`grafana-db`, `keycloak-db`, `seaweedfs-db`) stuck in
   "Failing over" / "error while interacting with plugins" for ~15 min because
   the operator held a dead barman-cloud plugin connection.
   `kubectl -n cnpg-system rollout restart deploy/barman-cloud deploy/cnpg-cloudnative-pg`
   cleared it; all three returned to 3/3 healthy.
4. Final state: 8/8 nodes Ready, etcd 3 members, no non-Running pods.

## Aftershock: flaky admission webhooks (found 2026-11-09)
- Flux kept failing on `opentelemetry-operator-webhook` timeouts, intermittently.
  Cause: `talos-controlplane-1` had picked up a leftover **SLAAC global address**
  during the hard reboot (before the `autoconf=0` sysctl applied). Node-originated
  traffic used it as source and the security group dropped it, so the apiserver on
  CP1 could not reach any pod. Other CPs/pods were fine.
- Detect: probe a pod's port from each CP with a hostNetwork pod in `kube-system`;
  `talosctl get addresses` shows an extra `...:f816:3eff:...` global address.
- Fix: graceful `talosctl reboot` of the affected node. After any hard reboot,
  check every node for this address.

## Diagnostics worth remembering
- Nova `ACTIVE` ≠ healthy. Check `talosctl service` (etcd/cri/kubelet) and
  `talosctl dmesg | grep -i input/output`.
- Talosconfig can be regenerated from state:
  `cd pcd-ce-deploy/tofu-pcd-talos-cluster && tofu output -raw talosconfig`.
  `~/.kube/talosconfig` was stale (pre-rebuild IPs); a fresh copy is at
  `~/.kube/talosconfig.core-infra`.
- PCD access: `ssh ubuntu@pcd.rye.ninja`, `sudo su -`, `source /root/openstackrc`.
- Workstation reaches the `1179::` subnet only intermittently (route flapped
  during the investigation); retry before assuming a cluster-side fault.

## Open hardening items (not done)
- **No core-infra etcd snapshot existed** (only `controlplane` was backed up).
  A manual snapshot was taken 2026-11-09 (`etcd-backups/`, gitignored, 84 MB).
  Scheduled snapshots to R2 are built but need rollout: see
  [etcd-snapshot-core-infra runbook](../runbooks/etcd-snapshot-core-infra.md).
- Boot disks on NFS-backed Cinder make the NAS a SPOF for the OS itself.
  Consider a non-NFS root-volume backend or local ephemeral disks for CPs.
- No NFS mount options (`soft`/`timeo`/`retrans`) found in `tofu-pcd`; hard
  mounts mean I/O hangs rather than fails. Decide deliberately.
- No alert for etcd health / node `NotReady` fired for 71h — add alerting that
  does not depend on the cluster itself.
- No PDBs or CNPG failover tuning on stateful workloads.
- Stale `cinder-scheduler` record (host `cinder-scheduler-7886c59d87-hxksp`,
  down since 2026-10-09) — clean with `openstack volume service set`/delete.
- Related: `pcd-ce-deploy/docs/persistant-storage-role-stuck.md` (wrong NFS IP
  fixes possibly unapplied). Confirm `tofu-pcd` was applied.
