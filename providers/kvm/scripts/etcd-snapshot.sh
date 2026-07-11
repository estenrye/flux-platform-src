#!/usr/bin/env bash
# 6-hourly etcd snapshot of the controlplane cluster, run ON THE KVM HOST via
# systemd timer (M1 design §5.3). Ships to a TrueNAS NFS export, prunes at 14
# days. Install per docs/runbooks/etcd-snapshot-restore.md:
#   - talosctl at /usr/local/bin/talosctl (pin to the cluster version)
#   - read-only talosconfig at /etc/controlplane/talosconfig (mode 0600)
#   - TrueNAS NFS export mounted at ${DEST_DIR} (fstab)
#   - etcd-snapshot.service + .timer in /etc/systemd/system
set -euo pipefail

DEST_DIR="${DEST_DIR:-/mnt/truenas/etcd-snapshots}"
TALOSCONFIG="${TALOSCONFIG:-/etc/controlplane/talosconfig}"
NODE="${NODE:-fd97:45c2:b3a1:100::11}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

mountpoint -q "${DEST_DIR}" || { echo "ERROR: ${DEST_DIR} is not a mounted NFS export" >&2; exit 1; }

SNAP="${DEST_DIR}/controlplane-etcd-$(date -u +%Y%m%dT%H%M%SZ).snapshot"
talosctl --talosconfig "${TALOSCONFIG}" -n "${NODE}" etcd snapshot "${SNAP}"
echo "snapshot written: ${SNAP}"

find "${DEST_DIR}" -name 'controlplane-etcd-*.snapshot' -mtime "+${RETENTION_DAYS}" -delete
