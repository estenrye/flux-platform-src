#!/usr/bin/env bash
# Provision the NAT64/DNS64 appliance (nat64-01) — shared infrastructure the
# IPv6-only controlplane cluster depends on to reach IPv4-only endpoints
# (factory.talos.dev, ghcr.io). SEPARATE lifecycle from the cluster: bring
# this up once and leave it; the cluster can be destroyed/rebuilt underneath
# it (docs/runbooks/nat64-appliance-rebuild.md, M1 design §4.3).
#
# Idempotent. Run before .bin/create-controlplane-cluster.sh — the cluster
# bootstrap reaches the Talos image factory THROUGH this appliance, so it
# must exist first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PATH="${REPO_ROOT}/.venv/bin:${PATH}"
source "${SCRIPT_DIR}/lib/prompt-color.sh"

KVM_DIR="${REPO_ROOT}/providers/kvm"
TOFU_DIR="${KVM_DIR}/nat64"
CACHE_DIR="${KVM_DIR}/.cache"
VERSIONS="${KVM_DIR}/versions.yaml"
NETWORK="${KVM_DIR}/network.yaml"

for tool in tofu yq curl qemu-img; do
  command -v "${tool}" >/dev/null || { error "missing tool: ${tool}"; exit 1; }
done

UBUNTU_IMG_URL=$(yq -r '.nat64_appliance.image_url' "${VERSIONS}")
NAT64_ULA=$(yq -r '.allocations.nat64_appliance.ula' "${NETWORK}")
mkdir -p "${CACHE_DIR}"

# ── Ubuntu cloud image (cached, converted to raw for the file-backed disk) ───
UBUNTU_QCOW="${CACHE_DIR}/$(basename "${UBUNTU_IMG_URL}")"
UBUNTU_RAW="${UBUNTU_QCOW%.img}.raw"
if [ ! -f "${UBUNTU_RAW}" ]; then
  [ -f "${UBUNTU_QCOW}" ] || { info "Downloading Ubuntu cloud image ..."; curl -fsSL -o "${UBUNTU_QCOW}" "${UBUNTU_IMG_URL}"; }
  info "Converting to raw ..."
  qemu-img convert -O raw "${UBUNTU_QCOW}" "${UBUNTU_RAW}.tmp"
  mv "${UBUNTU_RAW}.tmp" "${UBUNTU_RAW}"
fi
success "NAT64 base image: ${UBUNTU_RAW}"

# ── Apply ────────────────────────────────────────────────────────────────────
info "Applying NAT64 appliance (tofu) ..."
tofu -chdir="${TOFU_DIR}" init -input=false >/dev/null
tofu -chdir="${TOFU_DIR}" apply -input=false -auto-approve \
  -var "nat64_image_path=${UBUNTU_RAW}"
success "NAT64 appliance provisioned."

# ── Wait for it to actually translate (cloud-init installs tayga+unbound) ─────
info "Waiting for NAT64/DNS64 to come up (cloud-init: tayga + unbound) ..."
for attempt in $(seq 1 40); do
  # github.com has no AAAA — reaching it over v6 proves DNS64 + NAT64 both work.
  if curl -6 -sf --max-time 6 -o /dev/null "https://github.com/" 2>/dev/null; then
    success "NAT64 verified: reached an IPv4-only host over IPv6."
    echo
    info "NAT64 resolver/next-hop: ${NAT64_ULA}"
    info "Next: .bin/create-controlplane-cluster.sh"
    exit 0
  fi
  sleep 15
done
warn "Appliance provisioned but NAT64 not verified after 10m."
warn "Check: ssh nat64admin@${NAT64_ULA} 'systemctl status tayga unbound'"
warn "Runbook: docs/runbooks/nat64-appliance-rebuild.md"
exit 1
