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

today=$(date -u +%Y%m%d)
label="nightly-${today}"
[ "$(date -u +%u)" = "7" ] && label="weekly-${today}"

# ── snapshot ─────────────────────────────────────────────────────────────────
if ! zfs list -t snapshot "${SRC_DATASET}@${label}" >/dev/null 2>&1; then
  zfs snapshot -r "${SRC_DATASET}@${label}"
fi

# ── incremental send ─────────────────────────────────────────────────────────
# Find the newest snapshot that exists on both sides to use as the increment base.
remote_snaps=$(ssh "${NAS_USER}@${NAS_HOST}" "zfs list -H -t snapshot -o name -s creation -d 1 ${NAS_DATASET} 2>/dev/null" | awk -F@ '{print $2}' || true)
base=""
for s in $(zfs list -H -t snapshot -o name -s creation -d 1 "${SRC_DATASET}" | awk -F@ '{print $2}' | tac); do
  [ "${s}" = "${label}" ] && continue
  if echo "${remote_snaps}" | grep -qx "${s}"; then base="${s}"; break; fi
done

if [ -z "${base}" ]; then
  echo "no common base snapshot — full send of ${SRC_DATASET}@${label}"
  zfs send -R "${SRC_DATASET}@${label}" | ssh "${NAS_USER}@${NAS_HOST}" "zfs recv -uF ${NAS_DATASET}"
else
  echo "incremental send ${base} -> ${label}"
  zfs send -RI "@${base}" "${SRC_DATASET}@${label}" | ssh "${NAS_USER}@${NAS_HOST}" "zfs recv -uF ${NAS_DATASET}"
fi

# ── prune (both sides) ───────────────────────────────────────────────────────
prune() { # $1 = list command prefix ("" local, ssh remote), $2 = dataset
  local prefix="$1" dataset="$2" cutoff_daily cutoff_weekly snap date_part
  cutoff_daily=$(date -u -d '7 days ago' +%Y%m%d 2>/dev/null || date -u -v-7d +%Y%m%d)
  cutoff_weekly=$(date -u -d '28 days ago' +%Y%m%d 2>/dev/null || date -u -v-28d +%Y%m%d)
  for snap in $(${prefix} zfs list -H -t snapshot -o name -d 1 "${dataset}" | awk -F@ '{print $2}'); do
    date_part="${snap##*-}"
    case "${snap}" in
      nightly-*) [ "${date_part}" -lt "${cutoff_daily}" ] && ${prefix} zfs destroy -r "${dataset}@${snap}" ;;
      weekly-*) [ "${date_part}" -lt "${cutoff_weekly}" ] && ${prefix} zfs destroy -r "${dataset}@${snap}" ;;
    esac
  done
  return 0
}
prune "" "${SRC_DATASET}"
prune "ssh ${NAS_USER}@${NAS_HOST}" "${NAS_DATASET}"

echo "replication complete: ${SRC_DATASET}@${label} -> ${NAS_HOST}:${NAS_DATASET}"
