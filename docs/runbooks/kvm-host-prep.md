# Runbook: KVM host prep / replacement (`mf-ms-a2-01`)

Scope: preparing a fresh (or replacement) KVM host to carry the
`controlplane` cluster. Design: M1 design §3, §5.1, §5.2.

## Prerequisites

- Ubuntu 22.04+, libvirt installed, `automation-user` with libvirt group and
  SSH key in your agent.
- Network: LACP bond `bond0`, bridge `br0` on native VLAN 100.
- Two dedicated, empty NVMe disks for the mirror (`nvme1n1`, `nvme2n1` on
  mf-ms-a2-01). The OS disk is never touched.

## Steps

1. **Host prep script** (ZFS mirror, ARC cap, KSM, libvirt pools):

   ```sh
   scp providers/kvm/scripts/prep-kvm-host.sh automation-user@mf-ms-a2-01.usmnblm01.rye.ninja:
   ssh automation-user@mf-ms-a2-01.usmnblm01.rye.ninja sudo bash prep-kvm-host.sh
   ```

   Verify: `zpool status vmpool` shows the mirror ONLINE; `virsh pool-list`
   shows `vms` and `appliances` active. For a new host, edit
   `EXPECTED_HOST`/`DISKS` in the script and add the host to
   `providers/kvm/hosts.yaml` first.

2. **Static ULA for the host** (`fd97:45c2:b3a1:100::2000/64` per
   network.yaml) in the host's netplan, alongside its existing addressing.

3. **DR timers** — prerequisites, then install both host-side units.

   Prerequisites (one-offs; verified working 2026-07-13):
   - `talosctl` at `/usr/local/bin/talosctl`, matching the cluster version
     (`talosctl-linux-amd64` from the pinned Talos release), and a
     talosconfig at `/etc/controlplane/talosconfig` (mode 0600, root).
   - `nfs-common` installed (provides `mount.nfs4`).
   - `/etc/hosts` alias for the NAS ULA — `mount.nfs4` cannot parse a
     bracketed IPv6 literal:
     `echo "fd97:45c2:b3a1:100::1000 nas-ula.rye.ninja" | sudo tee -a /etc/hosts`
   - The etcd-snapshot NFS export is restricted to the host's **static** ULA
     (`::2000`), but the host's default source toward the NAS ULA is a SLAAC
     address, so a `/128` route to the NAS with `from: ::2000` is required or
     the mount is denied. This lives in **netplan** (persistent host state, up
     at boot before the timer can fire) — add to the `br0` bridge stanza in
     `/etc/netplan/50-cloud-init.yaml`:

     ```yaml
     routes:
       - to: fd97:45c2:b3a1:100::1000/128
         scope: link
         from: fd97:45c2:b3a1:100::2000
     ```

     Then `sudo chmod 600 /etc/netplan/50-cloud-init.yaml && sudo netplan
     generate && sudo netplan apply`; verify with
     `ip -6 route get fd97:45c2:b3a1:100::1000` (should show `src ...::2000
     proto static`). `etcd-snapshot.sh` self-mounts on each run (no fstab
     entry needed) but relies on this route being present.
   - Replication SSH key on the host for the `replication` user on TrueNAS
     (`/root/.ssh/replication_ed25519` + an `/root/.ssh/config` alias) and
     the target dataset
     `flash-pool/replication/mf-ms-a2-01.usmnblm01.rye.ninja/vms`. Verify:
     `sudo ssh replication@nas.rye.ninja /usr/sbin/zfs list <target>` (remote
     zfs needs the absolute path — `/usr/sbin` is not in a non-root SSH PATH).

   Install:

   ```sh
   sudo install -m 0755 providers/kvm/scripts/etcd-snapshot.sh /usr/local/sbin/
   sudo install -m 0755 providers/kvm/scripts/zfs-replicate-vms.sh /usr/local/sbin/
   sudo install -m 0644 providers/kvm/scripts/etcd-snapshot.{service,timer} /etc/systemd/system/
   sudo install -m 0644 providers/kvm/scripts/zfs-replicate-vms.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload && sudo systemctl enable --now etcd-snapshot.timer zfs-replicate-vms.timer
   # Verify: sudo systemctl start etcd-snapshot.service && ls /mnt/truenas/etcd-snapshots/
   ```

   The first `zfs-replicate-vms` run does a full send of `vmpool/vms` (sizeable
   but sparse); subsequent nightly runs are incremental.

4. **Memory pressure spot-check** (until the Grafana alert lands in M5):

   ```sh
   for d in $(virsh list --name); do virsh dommemstat "$d" | grep -E 'actual|unused'; done
   free -h; arcstat 1 1
   ```

   If guests are pinned at full reservation simultaneously, drop
   `worker_memory_mb` to 12288 in the tofu root module and re-apply.

## Host replacement

VM disks are cattle (M1 design §5.2): prep the new host (steps 1–3), point
`providers/kvm/hosts.yaml` at it, and either rebuild via
`.bin/create-controlplane-cluster.sh` + etcd restore, or roll back the
replicated zvols from TrueNAS (`zfs send` them into the new `vmpool/vms` and
`virsh define` the domains via `tofu apply`).
