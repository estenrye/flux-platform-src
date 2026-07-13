#!/usr/bin/env bash
# Nightly ZFS snapshot + incremental replication of VM zvols to TrueNAS
# (M1 design §5.2). Runs ON THE KVM HOST via systemd timer.
#
# Perspective from the design: Talos VM disks are cattle — the restore-critical
# set is (a) etcd snapshots, (b) SOPS-encrypted machine secrets in git,
# (c) PVC data on TrueNAS. This replication is the convenience layer that
# turns "rebuild the cluster" into "roll back the zvols".
#
# Install per docs/runbooks/kvm-host-prep.md:
#   - replication SSH key for ${NAS_USER}@${NAS_HOST} with zfs recv perms
#     (human installs the key on TrueNAS)
#   - target dataset ${NAS_DATASET} exists on TrueNAS
#
# Retention: 7 daily on both sides; Sunday snapshots kept 28 days (≈4 weekly).
set -euo pipefail

SRC_DATASET="${SRC_DATASET:-vmpool/vms}"
NAS_HOST="${NAS_HOST:-nas.rye.ninja}"
NAS_USER="${NAS_USER:-replication}"
NAS_DATASET="${NAS_DATASET:-flash-pool/replication/mf-ms-a2-01.usmnblm01.rye.ninja/vms}"
# Absolute path: /usr/sbin is not in a non-root user's non-interactive SSH
# PATH on TrueNAS SCALE, so bare `zfs` fails remotely.
REMOTE_ZFS="${REMOTE_ZFS:-/usr/sbin/zfs}"

today=$(date -u +%Y%m%d)
label="nightly-${today}"
[ "$(date -u +%u)" = "7" ] && label="weekly-${today}"

# ── snapshot ─────────────────────────────────────────────────────────────────
if ! zfs list -t snapshot "${SRC_DATASET}@${label}" >/dev/null 2>&1; then
  zfs snapshot -r "${SRC_DATASET}@${label}"
fi

# ── incremental send, one zvol at a time ─────────────────────────────────────
# Each child zvol is sent into ${NAS_DATASET}/<name> individually. Sending the
# parent filesystem with -R would make the remote `recv -F` roll back (and thus
# unmount) the mounted target dataset, and Linux ZFS cannot delegate
# mount/umount to the non-root ${NAS_USER} — zvols have no mounts, so per-zvol
# receives stay inside what `zfs allow` can grant.
for src in $(zfs list -H -r -d 1 -t volume -o name "${SRC_DATASET}"); do
  child="${src##*/}"
  target="${NAS_DATASET}/${child}"

  # Newest snapshot present on both sides is the increment base.
  remote_snaps=$(ssh "${NAS_USER}@${NAS_HOST}" "${REMOTE_ZFS} list -H -t snapshot -o name -s creation -d 1 ${target} 2>/dev/null" | awk -F@ '{print $2}' || true)
  base=""
  for s in $(zfs list -H -t snapshot -o name -s creation -d 1 "${src}" | awk -F@ '{print $2}' | tac); do
    [ "${s}" = "${label}" ] && continue
    if echo "${remote_snaps}" | grep -qx "${s}"; then base="${s}"; break; fi
  done

  if [ -z "${base}" ]; then
    echo "no common base snapshot — full send of ${src}@${label}"
    zfs send "${src}@${label}" | ssh "${NAS_USER}@${NAS_HOST}" "${REMOTE_ZFS} recv -uF ${target}"
  else
    echo "incremental send ${base} -> ${label} for ${src}"
    zfs send -I "@${base}" "${src}@${label}" | ssh "${NAS_USER}@${NAS_HOST}" "${REMOTE_ZFS} recv -uF ${target}"
  fi
done

# ── prune (both sides) ───────────────────────────────────────────────────────
prune() { # $1 = command prefix ("" local, ssh remote), $2 = zfs binary, $3 = dataset
  local prefix="$1" zfs_bin="$2" dataset="$3" cutoff_daily cutoff_weekly snap date_part
  cutoff_daily=$(date -u -d '7 days ago' +%Y%m%d 2>/dev/null || date -u -v-7d +%Y%m%d)
  cutoff_weekly=$(date -u -d '28 days ago' +%Y%m%d 2>/dev/null || date -u -v-28d +%Y%m%d)
  for snap in $(${prefix} "${zfs_bin}" list -H -t snapshot -o name -d 1 "${dataset}" | awk -F@ '{print $2}'); do
    date_part="${snap##*-}"
    case "${snap}" in
      nightly-*) [ "${date_part}" -lt "${cutoff_daily}" ] && ${prefix} "${zfs_bin}" destroy -r "${dataset}@${snap}" ;;
      weekly-*) [ "${date_part}" -lt "${cutoff_weekly}" ] && ${prefix} "${zfs_bin}" destroy -r "${dataset}@${snap}" ;;
    esac
  done
  return 0
}
prune "" "zfs" "${SRC_DATASET}"
# Remote snapshots live on the per-zvol children (no parent-level snapshots).
for src in $(zfs list -H -r -d 1 -t volume -o name "${SRC_DATASET}"); do
  prune "ssh ${NAS_USER}@${NAS_HOST}" "${REMOTE_ZFS}" "${NAS_DATASET}/${src##*/}"
done

echo "replication complete: ${SRC_DATASET}@${label} -> ${NAS_HOST}:${NAS_DATASET}"
