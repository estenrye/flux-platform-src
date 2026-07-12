#!/usr/bin/env bash
# One-time preparation of a KVM host for the `controlplane` cluster.
# HUMAN-RUN as root ON THE HOST (M1 design §5.1, execution step 3):
#
#   scp providers/kvm/scripts/prep-kvm-host.sh automation-user@mf-ms-a2-01.usmnblm01.rye.ninja:
#   ssh automation-user@mf-ms-a2-01.usmnblm01.rye.ninja sudo bash prep-kvm-host.sh
#
# What it does (idempotent — safe to re-run):
#   1. Creates ZFS mirror `vmpool` on the two dedicated NVMe disks.
#   2. Sets compression=lz4, atime=off; creates vmpool/vms and vmpool/appliances.
#   3. Caps ZFS ARC at 8 GiB (runtime + persistent) — the host over-commits
#      guest RAM, ARC must not compete (design §7.3).
#   4. Enables KSM via ksmtuned with conservative settings.
#   5. Defines libvirt storage pools of type zfs over the datasets.
#
# It REFUSES to touch a disk that already carries partitions or a foreign
# ZFS label. The OS disk (nvme0n1) is never referenced.
set -euo pipefail

POOL="vmpool"
DISKS=(nvme1n1 nvme2n1)
ARC_MAX_BYTES=8589934592 # 8 GiB
EXPECTED_HOST="mf-ms-a2-01"

info() { echo "[INFO]  $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || err "must run as root"
case "$(hostname -s)" in
  "${EXPECTED_HOST}") ;;
  *) err "this script is written for ${EXPECTED_HOST}; running on $(hostname -s). Edit EXPECTED_HOST/DISKS deliberately for a new host." ;;
esac

# ── 1. Packages ──────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
# Ubuntu ships libvirt's ZFS storage backend as a separate driver package;
# without it, pool-define fails with "missing backend for pool type (zfs)".
apt-get install -y --no-install-recommends \
  zfsutils-linux ksmtuned libvirt-daemon-driver-storage-zfs >/dev/null
info "packages present: zfsutils-linux ksmtuned libvirt-daemon-driver-storage-zfs"
# Pick up the newly installed storage driver (domains keep running).
systemctl restart libvirtd
info "libvirtd restarted (zfs storage backend loaded)"

# ── 1b. AppArmor: allow qemu to open zvol block devices ─────────────────────
# virt-aa-helper whitelists the /dev/zvol/... symlink, but qemu opens the
# resolved /dev/zdN device and gets DENIED without this rule.
if ! grep -q '/dev/zd\[0-9\]\* rwk' /etc/apparmor.d/abstractions/libvirt-qemu; then
  echo '  /dev/zd[0-9]* rwk,' >> /etc/apparmor.d/abstractions/libvirt-qemu
  systemctl reload apparmor
  info "AppArmor: zvol device rule added to libvirt-qemu abstraction"
else
  info "AppArmor zvol rule already present"
fi

# ── 2. ZFS pool ──────────────────────────────────────────────────────────────
if zpool list "${POOL}" >/dev/null 2>&1; then
  info "pool ${POOL} already exists — skipping creation"
else
  BY_ID=()
  for d in "${DISKS[@]}"; do
    [ -b "/dev/${d}" ] || err "/dev/${d} not found"
    # refuse disks with partitions or existing filesystem/ZFS signatures
    if [ "$(lsblk -no NAME "/dev/${d}" | wc -l)" -gt 1 ]; then
      err "/dev/${d} has partitions — refusing. Wipe deliberately, then re-run."
    fi
    if blkid "/dev/${d}" >/dev/null 2>&1; then
      err "/dev/${d} carries a filesystem/label signature — refusing. Wipe deliberately, then re-run."
    fi
    # prefer stable by-id path for the vdev
    id_path=$(find /dev/disk/by-id -lname "*/${d}" \( -name 'nvme-*' ! -name '*_[0-9]' \) | sort | head -1)
    BY_ID+=("${id_path:-/dev/${d}}")
  done
  info "creating mirror ${POOL}: ${BY_ID[*]}"
  zpool create -o ashift=12 "${POOL}" mirror "${BY_ID[@]}"
fi

zfs set compression=lz4 atime=off "${POOL}"
zfs list "${POOL}/vms" >/dev/null 2>&1 || zfs create "${POOL}/vms"
zfs list "${POOL}/appliances" >/dev/null 2>&1 || zfs create "${POOL}/appliances"
info "datasets ready: ${POOL}/vms ${POOL}/appliances"

# ── 3. ARC cap ───────────────────────────────────────────────────────────────
echo "${ARC_MAX_BYTES}" > /sys/module/zfs/parameters/zfs_arc_max
cat > /etc/modprobe.d/zfs-arc.conf <<EOF
# ARC capped at 8 GiB: guest RAM is over-committed on this host (M1 design 7.3)
options zfs zfs_arc_max=${ARC_MAX_BYTES}
EOF
update-initramfs -u -k "$(uname -r)" >/dev/null
info "ARC capped at ${ARC_MAX_BYTES} bytes (runtime + persistent)"

# ── 4. KSM (conservative) ────────────────────────────────────────────────────
cat > /etc/ksmtuned.conf <<'EOF'
# Conservative KSM tuning for RAM over-commit (M1 design 7.3).
# Longer sleep + smaller page boost than defaults: trade dedup latency for CPU.
KSM_MONITOR_INTERVAL=60
KSM_SLEEP_MSEC=200
KSM_NPAGES_BOOST=300
KSM_NPAGES_DECAY=-50
KSM_NPAGES_MIN=64
KSM_NPAGES_MAX=1250
KSM_THRES_COEF=20
EOF
systemctl enable --now ksm ksmtuned >/dev/null 2>&1 || systemctl enable --now ksmtuned
info "ksmtuned enabled (conservative profile)"

# ── 5. libvirt storage pools ─────────────────────────────────────────────────
define_pool() {
  local name="$1" dataset="$2"
  if virsh pool-info "${name}" >/dev/null 2>&1; then
    info "libvirt pool ${name} already defined"
  else
    virsh pool-define /dev/stdin <<EOF
<pool type='zfs'>
  <name>${name}</name>
  <source>
    <name>${dataset}</name>
  </source>
</pool>
EOF
  fi
  virsh pool-autostart "${name}" >/dev/null
  virsh pool-start "${name}" >/dev/null 2>&1 || true
}
define_pool vms "${POOL}/vms"
define_pool appliances "${POOL}/appliances"

echo
zpool status "${POOL}"
virsh pool-list --all
info "host prep complete. Verify: mirror ONLINE above, pools 'vms' and 'appliances' active."
