#!/usr/bin/env bash
# Tear down the `controlplane` cluster VMs and their zvols (M1 design: the
# cluster can be torn down and rebuilt freely during this milestone).
#
# Destroys: VMs, system-disk zvols, NAT64 appliance, ISO/cloud-init media.
# Keeps:    SOPS-encrypted machine secrets (clusters/controlplane/secrets/),
#           etcd snapshots on TrueNAS, ZFS replicas, the host pools.
# A rebuild with create-controlplane-cluster.sh reuses the same secrets, so
# node identities and the cluster CA survive rebuild.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PATH="${REPO_ROOT}/.venv/bin:${PATH}"
source "${SCRIPT_DIR}/lib/prompt-color.sh"

TOFU_DIR="${REPO_ROOT}/providers/kvm/controlplane"
CACHE_DIR="${REPO_ROOT}/providers/kvm/.cache"

warn "This DESTROYS all controlplane cluster VMs and their disks on the KVM host."
warn "etcd data is lost unless a snapshot exists (make backup-controlplane-etcd)."
read -r -p "Type 'controlplane' to confirm: " CONFIRM
[ "${CONFIRM}" = "controlplane" ] || { error "confirmation mismatch — aborting"; exit 1; }

# Vars are structurally required by the root module but irrelevant to destroy.
UBUNTU_RAW=$(ls "${CACHE_DIR}"/*.raw 2>/dev/null | head -1 || echo "/dev/null")
tofu -chdir="${TOFU_DIR}" init -input=false >/dev/null
tofu -chdir="${TOFU_DIR}" destroy -input=false -auto-approve \
  -var "schematic_id=destroy" \
  -var "nat64_image_path=${UBUNTU_RAW}"

rm -rf "${TOFU_DIR}/.rendered"
success "Destroyed. Rebuild with .bin/create-controlplane-cluster.sh"
