#!/usr/bin/env bash
# Tear down the NAT64/DNS64 appliance (nat64-01).
#
# This is rarely what you want: the appliance is shared infrastructure the
# IPv6-only cluster (and this workstation) rely on to reach IPv4-only
# endpoints. Destroying it breaks Talos image pulls and factory access until
# recreated. To REBUILD (the common case), just re-run .bin/create-nat64.sh —
# tofu replaces it in place. Only use this to retire the appliance entirely
# (e.g. UniFi ships native NAT64).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PATH="${REPO_ROOT}/.venv/bin:${PATH}"
source "${SCRIPT_DIR}/lib/prompt-color.sh"

TOFU_DIR="${REPO_ROOT}/providers/kvm/nat64"
CACHE_DIR="${REPO_ROOT}/providers/kvm/.cache"

warn "This DESTROYS the NAT64/DNS64 appliance. The IPv6-only cluster and this"
warn "workstation lose their path to IPv4-only endpoints (factory.talos.dev,"
warn "ghcr.io) until it is recreated. To rebuild instead, run create-nat64.sh."
read -r -p "Type 'nat64' to confirm: " CONFIRM
[ "${CONFIRM}" = "nat64" ] || { error "confirmation mismatch — aborting"; exit 1; }

UBUNTU_RAW=$(ls "${CACHE_DIR}"/*.raw 2>/dev/null | head -1 || echo "/dev/null")
tofu -chdir="${TOFU_DIR}" init -input=false >/dev/null
tofu -chdir="${TOFU_DIR}" destroy -input=false -auto-approve \
  -var "nat64_image_path=${UBUNTU_RAW}"
success "NAT64 appliance destroyed. Recreate with .bin/create-nat64.sh"
