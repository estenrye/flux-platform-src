#!/usr/bin/env bash
# Provision and bootstrap the `controlplane` Talos cluster on the KVM host
# (M1 design §8 step 8). Idempotent: safe to re-run after a partial failure.
#
# Prerequisites (M1 design §8 steps 1-4):
#   - KVM host prepped (providers/kvm/scripts/prep-kvm-host.sh) — pools vms/appliances exist
#   - UniFi BGP config uploaded; static route for the ULA /64 toward VLAN 100
#   - clusters/controlplane/.sops.yaml present with the controlplane age key
#   - ssh-agent holds the automation-user key for the KVM host
#
# Flow:
#   1. Compute the image factory schematic ID from providers/kvm/versions.yaml
#   2. Download + convert the Ubuntu cloud image for the NAT64 appliance
#   3. Decrypt (or generate + encrypt) Talos machine secrets via SOPS
#   4. Render machine configs from providers/kvm/network.yaml
#   5. tofu apply (VMs boot the factory ISO into maintenance mode)
#   6. Apply configs over the network at MAC-derived EUI-64 SLAAC addresses
#   7. Bootstrap etcd, fetch kubeconfig, report health
#
# Expected end state per the design: `talosctl health` etcd/apid clean, nodes
# NotReady (CNI arrives with Flux/Calico in step 10).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PATH="${REPO_ROOT}/.venv/bin:${PATH}"

source "${SCRIPT_DIR}/lib/prompt-color.sh"

KVM_DIR="${REPO_ROOT}/providers/kvm"
TOFU_DIR="${KVM_DIR}/controlplane"
CACHE_DIR="${KVM_DIR}/.cache"
RENDER_DIR="${TOFU_DIR}/.rendered"
CLUSTER_DIR="${REPO_ROOT}/clusters/controlplane"
SOPS_CONFIG="${CLUSTER_DIR}/.sops.yaml"
SECRETS_FILE="${CLUSTER_DIR}/secrets/talos-secrets.sops.yaml"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/homelab/controlplane.yaml}"
TALOSCONFIG_PATH="${TALOSCONFIG_PATH:-${HOME}/.talos/homelab-controlplane.yaml}"

for tool in tofu talosctl yq jq curl sops qemu-img; do
  command -v "${tool}" >/dev/null || { error "missing tool: ${tool} (see .bin/install-*.sh; qemu-img: brew install qemu)"; exit 1; }
done
[ -f "${SOPS_CONFIG}" ] || { error "${SOPS_CONFIG} not found — run the SOPS key setup first (M1 design step 4)"; exit 1; }

# ── Values from the single sources of truth ──────────────────────────────────
VERSIONS="${KVM_DIR}/versions.yaml"
NETWORK="${KVM_DIR}/network.yaml"

TALOS_VERSION=$(yq -r '.talos.version' "${VERSIONS}")
K8S_VERSION=$(yq -r '.talos.kubernetes_version' "${VERSIONS}")
UBUNTU_IMG_URL=$(yq -r '.nat64_appliance.image_url' "${VERSIONS}")
APISERVER_VIP=$(yq -r '.allocations.apiserver_vip' "${NETWORK}")
INFRA_SUBNET=$(yq -r '.allocations.infra_subnet' "${NETWORK}")
NAT64_ULA=$(yq -r '.allocations.nat64_appliance.ula' "${NETWORK}")
NAT64_PREFIX=$(yq -r '.allocations.nat64_appliance.nat64_prefix' "${NETWORK}")
POD_CIDR=$(yq -r '.allocations.pod_cidr' "${NETWORK}")
SVC_CIDR=$(yq -r '.allocations.service_cidr' "${NETWORK}")
GUA_PREFIX=$(yq -r '.gua_prefix' "${NETWORK}" | sed 's|::/64$||') # e.g. 2607:3640:1064:270

CLIENT_TALOS_VERSION=$(talosctl version --client --short 2>/dev/null | awk '/Talos v/{print $2}' || true)
if [ "${CLIENT_TALOS_VERSION}" != "${TALOS_VERSION}" ]; then
  warn "talosctl client ${CLIENT_TALOS_VERSION:-unknown} != pinned ${TALOS_VERSION}; run .bin/install-talosctl.sh to match before proceeding."
  exit 1
fi

mkdir -p "${CACHE_DIR}" "${RENDER_DIR}" && chmod 700 "${RENDER_DIR}"

# ── 1. Schematic ID ──────────────────────────────────────────────────────────
info "Computing image factory schematic ID ..."
SCHEMATIC_ID=$(yq -o=yaml '.talos.schematic' "${VERSIONS}" \
  | curl -fsS -X POST --data-binary @- https://factory.talos.dev/schematics \
  | jq -r '.id')
success "schematic: ${SCHEMATIC_ID}"

# ── 2. NAT64 appliance base image ────────────────────────────────────────────
UBUNTU_QCOW="${CACHE_DIR}/$(basename "${UBUNTU_IMG_URL}")"
UBUNTU_RAW="${UBUNTU_QCOW%.img}.raw"
if [ ! -f "${UBUNTU_RAW}" ]; then
  [ -f "${UBUNTU_QCOW}" ] || { info "Downloading Ubuntu cloud image ..."; curl -fsSL -o "${UBUNTU_QCOW}" "${UBUNTU_IMG_URL}"; }
  info "Converting to raw (zvol upload requires raw) ..."
  # Convert to a temp name and move into place atomically: a partial .raw
  # from an interrupted run must never be mistaken for a valid cache hit.
  qemu-img convert -O raw "${UBUNTU_QCOW}" "${UBUNTU_RAW}.tmp"
  mv "${UBUNTU_RAW}.tmp" "${UBUNTU_RAW}"
fi
success "NAT64 base image: ${UBUNTU_RAW}"

# ── 3. Talos machine secrets (SOPS) ──────────────────────────────────────────
# Whole-file encryption with explicit recipients. Do NOT rely on .sops.yaml
# creation rules here: sops matches path_regex against the plaintext INPUT
# path (a temp file), which would silently fall through to the
# data/stringData rule and leave Talos secrets in plaintext.
SECRETS_PLAIN="${RENDER_DIR}/secrets.yaml"
AGE_RECIPIENTS=$(yq -r '.creation_rules[0].age' "${SOPS_CONFIG}" | tr -d ' \n')
AGE_KEY_FILE="${CLUSTER_DIR}/.sops.age-key"
if [ -f "${AGE_KEY_FILE}" ]; then
  export SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}"
elif [ -f "${SECRETS_FILE}" ]; then
  error "cannot decrypt ${SECRETS_FILE}: ${AGE_KEY_FILE} missing — restore it from 1Password (vault controlplane, item sops-age-key)"
  exit 1
fi
if [ -f "${SECRETS_FILE}" ]; then
  info "Decrypting existing machine secrets ..."
  sops --config /dev/null -d "${SECRETS_FILE}" > "${SECRETS_PLAIN}"
else
  info "Generating new machine secrets (first run) ..."
  mkdir -p "$(dirname "${SECRETS_FILE}")"
  talosctl gen secrets -o "${SECRETS_PLAIN}"
  sops --config /dev/null -e --age "${AGE_RECIPIENTS}" "${SECRETS_PLAIN}" > "${SECRETS_FILE}"
  grep -q 'ENC\[' "${SECRETS_FILE}" || { error "encryption produced no ENC values — refusing to continue"; rm -f "${SECRETS_FILE}"; exit 1; }
  success "Encrypted secrets written: ${SECRETS_FILE} — commit this file."
fi

# ── 4. Machine configs ───────────────────────────────────────────────────────
info "Rendering machine configs ..."
cat > "${RENDER_DIR}/patch-all.yaml" <<EOF
machine:
  install:
    disk: /dev/vda
    image: factory.talos.dev/installer/${SCHEMATIC_ID}:${TALOS_VERSION}
  network:
    nameservers:
      - ${NAT64_ULA}
  time:
    servers:
      - time.cloudflare.com
  kubelet:
    nodeIP:
      validSubnets:
        - ${INFRA_SUBNET}
cluster:
  network:
    cni:
      name: none
    podSubnets:
      - ${POD_CIDR}
    serviceSubnets:
      - ${SVC_CIDR}
EOF

cat > "${RENDER_DIR}/patch-cp.yaml" <<EOF
cluster:
  etcd:
    advertisedSubnets:
      - ${INFRA_SUBNET}
EOF

talosctl gen config controlplane "https://[${APISERVER_VIP}]:6443" \
  --with-secrets "${SECRETS_PLAIN}" \
  --talos-version "${TALOS_VERSION}" \
  --kubernetes-version "${K8S_VERSION}" \
  --additional-sans "api.controlplane.rye.ninja,${APISERVER_VIP}" \
  --config-patch "@${RENDER_DIR}/patch-all.yaml" \
  --config-patch-control-plane "@${RENDER_DIR}/patch-cp.yaml" \
  --output-dir "${RENDER_DIR}" \
  --force

# Per-node patches: hostname + static ULA + NAT64 route (+ shared VIP on CPs).
node_names=()
node_addrs=()
render_node() {
  local name="$1" ula="$2" role="$3" base vip_block=""
  base="${RENDER_DIR}/controlplane.yaml"
  [ "${role}" = "worker" ] && base="${RENDER_DIR}/worker.yaml"
  if [ "${role}" = "controlplane" ]; then
    vip_block="
        vip:
          ip: ${APISERVER_VIP}"
  fi
  cat > "${RENDER_DIR}/patch-${name}.yaml" <<EOF
machine:
  network:
    hostname: ${name}
    interfaces:
      - interface: eth0
        dhcp: false
        addresses:
          - ${ula}/64
        routes:
          - network: ${NAT64_PREFIX}
            gateway: ${NAT64_ULA}${vip_block}
EOF
  talosctl machineconfig patch "${base}" \
    --patch "@${RENDER_DIR}/patch-${name}.yaml" \
    -o "${RENDER_DIR}/${name}.yaml"
  node_names+=("${name}")
  node_addrs+=("${ula}")
}

while IFS=$'\t' read -r name ula; do render_node "${name}" "${ula}" controlplane; done \
  < <(yq -r '.allocations.controlplane_nodes | to_entries[] | [.key, .value] | @tsv' "${NETWORK}")
while IFS=$'\t' read -r name ula; do render_node "${name}" "${ula}" worker; done \
  < <(yq -r '.allocations.worker_nodes | to_entries[] | [.key, .value] | @tsv' "${NETWORK}")
success "machine configs rendered for: ${node_names[*]}"

# ── 5. tofu apply ────────────────────────────────────────────────────────────
info "Applying infrastructure (tofu) ..."
tofu -chdir="${TOFU_DIR}" init -input=false >/dev/null
tofu -chdir="${TOFU_DIR}" apply -input=false -auto-approve \
  -var "schematic_id=${SCHEMATIC_ID}" \
  -var "nat64_image_path=${UBUNTU_RAW}"
success "VMs provisioned."

# ── 6. Apply configs in maintenance mode ─────────────────────────────────────
# Maintenance-mode nodes have only SLAAC/link-local addresses. MACs are fixed
# as 52:54:00:b3:a1:<ula-suffix>, so the EUI-64 SLAAC address under the GUA
# prefix is predictable: <gua>:5054:ff:feb3:a1<suffix>.
maintenance_addr() {
  local ula="$1" suffix
  suffix="${ula##*::}" # 11..13, 21..23
  echo "${GUA_PREFIX}:5054:ff:feb3:a1${suffix}"
}

for i in "${!node_names[@]}"; do
  name="${node_names[$i]}"; ula="${node_addrs[$i]}"
  # Already configured (re-run)? Secure port answering at the static ULA wins.
  if talosctl --talosconfig "${RENDER_DIR}/talosconfig" -n "${ula}" -e "${ula}" version >/dev/null 2>&1; then
    info "${name}: already configured at ${ula} — skipping"
    continue
  fi
  addr=$(maintenance_addr "${ula}")
  info "${name}: waiting for maintenance mode at ${addr} ..."
  for attempt in $(seq 1 60); do
    if talosctl apply-config --insecure --nodes "${addr}" --file "${RENDER_DIR}/${name}.yaml" 2>/dev/null; then
      success "${name}: config applied — installing to disk"
      break
    fi
    [ "${attempt}" -eq 60 ] && { error "${name}: never reachable at ${addr}. If SLAAC used stable-privacy instead of EUI-64, find the node via 'virsh domifaddr ${name} --source arp' on the host."; exit 1; }
    sleep 10
  done
done

# ── 7. Bootstrap + kubeconfig ────────────────────────────────────────────────
CP_ADDRS=$(yq -r '.allocations.controlplane_nodes | to_entries | map(.value) | join(",")' "${NETWORK}")
FIRST_CP=$(yq -r '.allocations.controlplane_nodes | to_entries | .[0].value' "${NETWORK}")

talosctl --talosconfig "${RENDER_DIR}/talosconfig" config endpoint ${CP_ADDRS//,/ }

info "Waiting for Talos API on ${FIRST_CP} (install + reboot takes a few minutes) ..."
for attempt in $(seq 1 90); do
  talosctl --talosconfig "${RENDER_DIR}/talosconfig" -n "${FIRST_CP}" version >/dev/null 2>&1 && break
  [ "${attempt}" -eq 90 ] && { error "Talos API never came up on ${FIRST_CP}"; exit 1; }
  sleep 10
done

info "Bootstrapping etcd ..."
if ! talosctl --talosconfig "${RENDER_DIR}/talosconfig" -n "${FIRST_CP}" bootstrap 2>/dev/null; then
  info "bootstrap returned non-zero — assuming already bootstrapped (re-run)"
fi

mkdir -p "$(dirname "${TALOSCONFIG_PATH}")" "$(dirname "${KUBECONFIG_PATH}")"
cp "${RENDER_DIR}/talosconfig" "${TALOSCONFIG_PATH}"

info "Fetching kubeconfig (via apiserver VIP) ..."
for attempt in $(seq 1 60); do
  if talosctl --talosconfig "${TALOSCONFIG_PATH}" -n "${FIRST_CP}" kubeconfig "${KUBECONFIG_PATH}" --force >/dev/null 2>&1; then
    break
  fi
  [ "${attempt}" -eq 60 ] && { error "could not fetch kubeconfig"; exit 1; }
  sleep 10
done
success "kubeconfig: ${KUBECONFIG_PATH} (catalog annotation rye.ninja/kubeconfig must match)"

info "etcd status:"
talosctl --talosconfig "${TALOSCONFIG_PATH}" -n "${CP_ADDRS}" etcd status || true

echo
success "Cluster bootstrapped. Expected state: all Talos services healthy, nodes NotReady (CNI=none)."
info "Next steps (M1 design §8):"
info "  9.  Create the rendered repo + deploy key (human)"
info "  10. Flux Operator bootstrap -> Calico reconciles -> nodes Ready"
info "  11. Confirm BGP peering on the UniFi gateway (human)"
info "  Verify now:  talosctl --talosconfig ${TALOSCONFIG_PATH} -n ${FIRST_CP} health --server=false"
