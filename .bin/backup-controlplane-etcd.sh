#!/usr/bin/env bash
# On-demand etcd snapshot of the `controlplane` cluster (M1 design §5.3).
# The scheduled 6-hourly snapshot runs on the KVM host via systemd timer
# (providers/kvm/scripts/etcd-snapshot.*); this script is the workstation
# equivalent for ad-hoc snapshots, e.g. before an upgrade or DR drill.
#
# Env:
#   TALOSCONFIG_PATH  default ~/.talos/homelab-controlplane.yaml
#   OUTPUT_DIR        default ./etcd-backups (created; NOT committed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PATH="${REPO_ROOT}/.venv/bin:${PATH}"
source "${SCRIPT_DIR}/lib/prompt-color.sh"

TALOSCONFIG_PATH="${TALOSCONFIG_PATH:-${HOME}/.talos/homelab-controlplane.yaml}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/etcd-backups}"
FIRST_CP=$(yq -r '.allocations.controlplane_nodes | to_entries | .[0].value' "${REPO_ROOT}/providers/kvm/network.yaml")

[ -f "${TALOSCONFIG_PATH}" ] || { error "talosconfig not found: ${TALOSCONFIG_PATH}"; exit 1; }
mkdir -p "${OUTPUT_DIR}"

SNAP="${OUTPUT_DIR}/controlplane-etcd-$(date -u +%Y%m%dT%H%M%SZ).snapshot"
info "Snapshotting etcd from ${FIRST_CP} ..."
talosctl --talosconfig "${TALOSCONFIG_PATH}" -n "${FIRST_CP}" etcd snapshot "${SNAP}"
success "etcd snapshot: ${SNAP}"
info "Restore procedure: docs/runbooks/etcd-snapshot-restore.md"
