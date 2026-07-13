#!/usr/bin/env bash
# 6-hourly etcd snapshot of the controlplane cluster, run ON THE KVM HOST via
# systemd timer (M1 design §5.3). Ships to a TrueNAS NFS export, prunes at 14
# days. Self-sufficient: ensures its own source route + NFS mount so a DR
# tool never silently no-ops after a reboot. Install per
# docs/runbooks/etcd-snapshot-restore.md:
#   - talosctl at /usr/local/bin/talosctl (pin to the cluster version)
#   - talosconfig at /etc/controlplane/talosconfig (mode 0600, root)
#   - nfs-common installed; /etc/hosts alias nas-ula.rye.ninja -> NAS ULA
#   - etcd-snapshot.service + .timer in /etc/systemd/system
set -euo pipefail

DEST_DIR="${DEST_DIR:-/mnt/truenas/etcd-snapshots}"
TALOSCONFIG="${TALOSCONFIG:-/etc/controlplane/talosconfig}"
NODE="${NODE:-fd97:45c2:b3a1:100::11}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

# TrueNAS NFS export (restricted to the host's static ULA). The host's default
# source toward the NAS ULA is a SLAAC address, so pin the /128 route source
# to the static ULA or the export denies access. Mount by /etc/hosts alias:
# mount.nfs4 cannot parse a bracketed IPv6 literal.
NAS_ULA="${NAS_ULA:-fd97:45c2:b3a1:100::1000}"
NAS_ALIAS="${NAS_ALIAS:-nas-ula.rye.ninja}"
HOST_ULA="${HOST_ULA:-fd97:45c2:b3a1:100::2000}"
NFS_IFACE="${NFS_IFACE:-br0}"
NFS_EXPORT="${NFS_EXPORT:-/mnt/flash-pool/k8s/controlplane-etcd-snapshots}"

# ── Ensure preconditions (idempotent) ────────────────────────────────────────
ip -6 route replace "${NAS_ULA}/128" dev "${NFS_IFACE}" src "${HOST_ULA}"
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
