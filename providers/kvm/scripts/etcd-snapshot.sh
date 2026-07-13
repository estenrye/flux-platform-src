#!/usr/bin/env bash
# 6-hourly etcd snapshot of the controlplane cluster, run ON THE KVM HOST via
# systemd timer (M1 design §5.3). Ships to a TrueNAS NFS export, prunes at 14
# days. Install per docs/runbooks/etcd-snapshot-restore.md; host prereqs in
# docs/runbooks/kvm-host-prep.md:
#   - talosctl at /usr/local/bin/talosctl (pin to the cluster version)
#   - talosconfig at /etc/controlplane/talosconfig (mode 0600, root)
#   - nfs-common installed; /etc/hosts alias nas-ula.rye.ninja -> NAS ULA
#   - netplan route fd97:...::1000/128 src fd97:...::2000 on br0 (the export
#     is restricted to the host static ULA; without the source hint the mount
#     egresses from a SLAAC address and is denied) — persistent host state, so
#     the route is up at boot before this timer can fire
#   - etcd-snapshot.service + .timer in /etc/systemd/system
set -euo pipefail

DEST_DIR="${DEST_DIR:-/mnt/truenas/etcd-snapshots}"
TALOSCONFIG="${TALOSCONFIG:-/etc/controlplane/talosconfig}"
NODE="${NODE:-fd97:45c2:b3a1:100::11}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

# Mount by /etc/hosts alias: mount.nfs4 cannot parse a bracketed IPv6 literal.
# The source-address pinning is the netplan route (a backup script must not
# mutate host routing), so this only self-mounts.
NAS_ALIAS="${NAS_ALIAS:-nas-ula.rye.ninja}"
NFS_EXPORT="${NFS_EXPORT:-/mnt/flash-pool/k8s/controlplane-etcd-snapshots}"

# ── Ensure the export is mounted (idempotent) ────────────────────────────────
if ! mountpoint -q "${DEST_DIR}"; then
  mkdir -p "${DEST_DIR}"
  mount -t nfs4 -o proto=tcp6 "${NAS_ALIAS}:${NFS_EXPORT}" "${DEST_DIR}"
fi
mountpoint -q "${DEST_DIR}" || { echo "ERROR: ${DEST_DIR} is not mounted" >&2; exit 1; }

# ── Snapshot + prune ─────────────────────────────────────────────────────────
SNAP="${DEST_DIR}/controlplane-etcd-$(date -u +%Y%m%dT%H%M%SZ).snapshot"
talosctl --talosconfig "${TALOSCONFIG}" -n "${NODE}" -e "${NODE}" etcd snapshot "${SNAP}"
echo "snapshot written: ${SNAP}"

find "${DEST_DIR}" -name 'controlplane-etcd-*.snapshot' -mtime "+${RETENTION_DAYS}" -delete
