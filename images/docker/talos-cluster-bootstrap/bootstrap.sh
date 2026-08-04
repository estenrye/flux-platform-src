#!/usr/bin/env bash
# M4 step 2: Talos-bootstrap Job entrypoint. Runs in-cluster (on
# `controlplane`, created by the `cluster-talos-kvm` Composition, M4 step 3)
# once provider-terraform has created the target cluster's VMs. Ports
# .bin/create-controlplane-cluster.sh's imperative half (schematic ID,
# machine secrets, machine-config render, apply-config in maintenance mode,
# etcd bootstrap, kubeconfig fetch) for unattended, per-claim execution:
#
#   - No YAML files (network.yaml/versions.yaml/hosts.yaml) -- every input
#     is an env var, templated by the composition from the claim + the
#     provider-terraform Workspace's `nodes` output.
#   - Machine secrets go to OpenBao (kv-v2), not SOPS -- there's no
#     workstation age key to decrypt with here.
#   - Kubeconfig/talosconfig become K8s Secrets on controlplane (the
#     composition's "connection secret" contract, spec 5.2 item 3), not
#     local files.
#   - VM creation itself (original script's step 5, `tofu apply`) is NOT
#     here -- that already happened via provider-terraform before this Job
#     runs. See docs/superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md.
#
# Idempotent: safe to re-run (same guarantee the original script makes).
set -euo pipefail

for var in CLUSTER_NAME TALOS_VERSION KUBERNETES_VERSION SCHEMATIC_ID \
  APISERVER_VIP ADDITIONAL_SANS INFRA_SUBNET NAT64_ULA NAT64_PREFIX \
  POD_CIDR SVC_CIDR NODES_JSON KUBECONFIG_SECRET_NAME \
  KUBECONFIG_SECRET_NAMESPACE TALOSCONFIG_SECRET_NAME TALOSCONFIG_SECRET_NAMESPACE \
  OPENBAO_ADDR OPENBAO_CACERT OPENBAO_KV_MOUNT OPENBAO_KV_PATH OPENBAO_K8S_AUTH_ROLE; do
  [ -n "${!var:-}" ] || { echo "ERROR: required env var ${var} is not set" >&2; exit 1; }
done
TALOS_INSTALL_DISK="${TALOS_INSTALL_DISK:-/dev/vda}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "==> Checking NAT64 path to the image factory ..."
if ! curl -fsS --max-time 10 -o /dev/null https://factory.talos.dev/ 2>/dev/null; then
  echo "ERROR: cannot reach factory.talos.dev via NAT64 (${NAT64_ULA})" >&2
  exit 1
fi
echo "OK."

echo "==> Authenticating to OpenBao (kubernetes auth, role ${OPENBAO_K8S_AUTH_ROLE}) ..."
export BAO_ADDR="${OPENBAO_ADDR}"
export BAO_CACERT="${OPENBAO_CACERT}"
SA_JWT="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
BAO_TOKEN="$(bao write -field=token auth/kubernetes/login role="${OPENBAO_K8S_AUTH_ROLE}" jwt="${SA_JWT}")"
export BAO_TOKEN
echo "OK."

echo "==> Using schematic: ${SCHEMATIC_ID}"
# M4 step 3: computed once by the talos-cluster Terraform module's own
# data.tf (same factory.talos.dev POST, moved upstream) and passed straight
# through here as SCHEMATIC_ID -- this Job no longer recomputes it, so the
# VM's installed image and this Job's machine-config `install.image` field
# can never independently drift out of sync.

echo "==> Talos machine secrets (OpenBao) ..."
SECRETS_PLAIN="${WORK_DIR}/secrets.yaml"
if bao kv get -mount="${OPENBAO_KV_MOUNT}" -field=secrets.yaml "${OPENBAO_KV_PATH}" >"${SECRETS_PLAIN}" 2>/dev/null; then
  echo "Existing machine secrets found in OpenBao."
else
  echo "Generating new machine secrets (first run) ..."
  # CORRECTED 2026-08-01 (M4 step 5, caught live): the `>` redirection
  # above creates/truncates SECRETS_PLAIN as a side effect even when
  # `bao kv get` fails (e.g. the normal first-run "no value found" case)
  # -- `talosctl gen secrets` then refuses to write to a path that
  # already exists ("file ... already exists, use --force to
  # overwrite"), even though it's empty. Remove the stray file first.
  rm -f "${SECRETS_PLAIN}"
  talosctl gen secrets -o "${SECRETS_PLAIN}"
  bao kv put -mount="${OPENBAO_KV_MOUNT}" "${OPENBAO_KV_PATH}" "secrets.yaml=@${SECRETS_PLAIN}" >/dev/null
  echo "Machine secrets written to OpenBao: ${OPENBAO_KV_MOUNT}/${OPENBAO_KV_PATH}"
fi

echo "==> Rendering machine configs ..."
# CORRECTED 2026-08-05, caught live (5th stacked bug blocking
# observability's bootstrap, same root cause class as the NAT64-route
# fix above): time.cloudflare.com has both real A and AAAA records, so
# DNS resolution succeeds (confirmed live -- the node's resolver at
# NAT64_ULA works fine cross-VLAN) but the NTP client is then left
# trying to reach genuinely-unreachable global v4/v6 addresses -- this
# VLAN has neither a real internet v4 stack nor a GUA/PD, by design
# (XNetworkSegment, ULA-only). Talos's time.SyncController fails this
# forever, and (per the same investigation as the NAT64 route bug)
# never-synced time appears to gate cri/etcd from ever starting.
# Fixed by pointing off-VLAN-100 nodes at a NAT64-synthesized literal
# address instead of a hostname -- same "avoid the DNS64/NAT64 hostname
# trap with a literal" pattern as provider-config.unifi.yaml's api_url.
# 162.159.200.1 is one of time.cloudflare.com's own real IPv4 addresses
# (confirmed via the DNS resolution that did succeed), so this is the
# same NTP service, just addressed in a way this VLAN can actually
# route to.
TIME_SERVER="time.cloudflare.com"
if [ "${NAT64_ULA%%::*}" != "${INFRA_SUBNET%%::*}" ]; then
  TIME_SERVER="${NAT64_PREFIX%/*}a29f:c801"
fi
cat >"${WORK_DIR}/patch-all.yaml" <<EOF
machine:
  install:
    disk: ${TALOS_INSTALL_DISK}
    image: factory.talos.dev/installer/${SCHEMATIC_ID}:${TALOS_VERSION}
  network:
    nameservers:
      - ${NAT64_ULA}
  time:
    servers:
      - ${TIME_SERVER}
  kubelet:
    nodeIP:
      validSubnets:
        - ${INFRA_SUBNET}
    extraMounts:
      - destination: /etc/iscsi
        type: bind
        source: /etc/iscsi
        options: [bind, rshared, rw]
cluster:
  network:
    cni:
      name: none
    podSubnets:
      - ${POD_CIDR}
    serviceSubnets:
      - ${SVC_CIDR}
EOF

cat >"${WORK_DIR}/patch-cp.yaml" <<EOF
cluster:
  etcd:
    advertisedSubnets:
      - ${INFRA_SUBNET}
  apiServer:
    # Same reasoning as controlplane (M3 step 10, docs/memory/m3-step-tracker.md):
    # Pinniped's TokenCredentialRequest flow needs anonymous-auth open.
    extraArgs:
      anonymous-auth: "true"
EOF

talosctl gen config "${CLUSTER_NAME}" "https://[${APISERVER_VIP}]:6443" \
  --with-secrets "${SECRETS_PLAIN}" \
  --talos-version "${TALOS_VERSION}" \
  --kubernetes-version "${KUBERNETES_VERSION}" \
  --additional-sans "${ADDITIONAL_SANS}" \
  --config-patch "@${WORK_DIR}/patch-all.yaml" \
  --config-patch-control-plane "@${WORK_DIR}/patch-cp.yaml" \
  --output-dir "${WORK_DIR}" \
  --force

for f in "${WORK_DIR}/controlplane.yaml" "${WORK_DIR}/worker.yaml"; do
  yq ea -i 'select(.kind != "HostnameConfig")' "${f}"
done

node_names=()
node_addrs=()
node_macs=()
render_node() {
  local name="$1" ula="$2" role="$3" mac="$4" base vip_block="" routes_block=""
  base="${WORK_DIR}/controlplane.yaml"
  [ "${role}" = "worker" ] && base="${WORK_DIR}/worker.yaml"
  if [ "${role}" = "controlplane" ]; then
    vip_block="
        vip:
          ip: ${APISERVER_VIP}"
  fi
  # CORRECTED 2026-08-05, caught live (4th stacked bug blocking
  # observability's bootstrap): NAT64_ULA is nat64-01's fixed address on
  # controlplane's own VLAN 100 -- there's only one nat64-01, it isn't
  # per-cluster like INFRA_SUBNET/POD_CIDR. An explicit route to it is
  # only installable when it's actually on-link for this node's own
  # subnet; for any other cluster's VLAN, the gateway address isn't
  # reachable via any route the node already has, and Talos's route
  # config has no `onlink` escape hatch (confirmed against
  # pkg/machinery/config/types/v1alpha1's Route struct) -- the kernel
  # rejects the route outright ("no route to host"), and that failure
  # loops forever, which blocks cri/kubelet/etcd from ever starting
  # (confirmed live: `talosctl service` showed etcd not registered at
  # all, not just stopped). Skip the explicit route off-VLAN-100 and let
  # the existing default route (already required, RA-derived) carry
  # NAT64-bound traffic to the gateway instead -- ordinary inter-VLAN
  # forwarding, not new infrastructure, and doesn't touch controlplane's
  # own already-working on-link path at all.
  if [ "${NAT64_ULA%%::*}" = "${INFRA_SUBNET%%::*}" ]; then
    routes_block="
        routes:
          - network: ${NAT64_PREFIX}
            gateway: ${NAT64_ULA}"
  fi
  cat >"${WORK_DIR}/patch-${name}.yaml" <<EOF
machine:
  network:
    hostname: ${name}
    interfaces:
      - deviceSelector:
          physical: true
        dhcp: false
        addresses:
          - ${ula}/64${vip_block}${routes_block}
EOF
  talosctl machineconfig patch "${base}" \
    --patch "@${WORK_DIR}/patch-${name}.yaml" \
    -o "${WORK_DIR}/${name}.yaml"
  node_names+=("${name}")
  node_addrs+=("${ula}")
  node_macs+=("${mac}")
}

while IFS=$'\t' read -r name role ula mac; do
  render_node "${name}" "${ula}" "${role}" "${mac}"
done < <(echo "${NODES_JSON}" | jq -r 'to_entries[] | [.key, .value.role, .value.ula, .value.mac] | @tsv')
echo "machine configs rendered for: ${node_names[*]}"

echo "==> Applying configs in maintenance mode ..."
# Same deterministic EUI-64 SLAAC derivation as create-controlplane-cluster.sh,
# sourced from each node's MAC (already known from the Terraform module's
# `nodes` output) instead of re-deriving it from the ULA.
#
# CORRECTED 2026-08-05 (M4, caught live): this used to take a separate
# GUA_PREFIX env var, hardcoded in the Composition to controlplane's own
# VLAN 100 GUA prefix rather than derived per-cluster. That only "worked"
# for observability by accident, while its VMs were still physically
# misattached to br0/VLAN 100 (a since-fixed libvirt bridge bug -- see
# dmacvicar-libvirt-bridge-inplace-update-bug memory). Once correctly on
# its own dedicated, ULA-only VLAN (no GUA/PD at all -- see XNetworkSegment),
# the node's real maintenance-mode SLAAC address is under INFRA_SUBNET's own
# prefix instead, confirmed live via rdisc6 (Autonomous address conf: Yes
# advertised for INFRA_SUBNET) and a direct ping to the predicted address.
# INFRA_SUBNET is already correct and per-cluster (unlike the old
# GUA_PREFIX), so derive from it instead of carrying a second, redundant
# prefix value.
maintenance_addr() {
  local mac="$1" octet prefix
  octet="${mac##*:}"
  prefix="${INFRA_SUBNET%%::*}"
  echo "${prefix}:5054:ff:feb3:a1${octet}"
}

for i in "${!node_names[@]}"; do
  name="${node_names[$i]}"; ula="${node_addrs[$i]}"; mac="${node_macs[$i]}"
  if talosctl --talosconfig "${WORK_DIR}/talosconfig" -n "${ula}" -e "${ula}" version >/dev/null 2>&1; then
    echo "${name}: already configured at ${ula} — skipping"
    continue
  fi
  addr="$(maintenance_addr "${mac}")"
  echo "${name}: waiting for maintenance mode at ${addr} ..."
  for attempt in $(seq 1 60); do
    if talosctl apply-config --insecure --nodes "${addr}" --file "${WORK_DIR}/${name}.yaml" 2>/dev/null; then
      echo "${name}: config applied — installing to disk"
      break
    fi
    if talosctl --talosconfig "${WORK_DIR}/talosconfig" apply-config \
        --nodes "${addr}" --endpoints "${addr}" --file "${WORK_DIR}/${name}.yaml" 2>/dev/null; then
      echo "${name}: corrected config applied over TLS at ${addr}"
      break
    fi
    [ "${attempt}" -eq 60 ] && { echo "ERROR: ${name} never reachable at ${addr}" >&2; exit 1; }
    sleep 10
  done
done

echo "==> Bootstrap + kubeconfig ..."
CP_ADDRS="$(echo "${NODES_JSON}" | jq -r '[to_entries[] | select(.value.role == "controlplane") | .value.ula] | join(",")')"
FIRST_CP="$(echo "${NODES_JSON}" | jq -r '[to_entries[] | select(.value.role == "controlplane")][0].value.ula')"

talosctl --talosconfig "${WORK_DIR}/talosconfig" config endpoint ${CP_ADDRS//,/ }

echo "Waiting for Talos API on ${FIRST_CP} (install + reboot takes a few minutes) ..."
for attempt in $(seq 1 90); do
  VERSION_ERR=$(talosctl --talosconfig "${WORK_DIR}/talosconfig" -n "${FIRST_CP}" version 2>&1) && break
  # Surface the real error on the last attempt instead of a bare "never
  # came up" -- the original swallowed this entirely (>/dev/null 2>&1),
  # which made a real M4 step 5 failure much harder to diagnose than it
  # needed to be.
  [ "${attempt}" -eq 90 ] && { echo "ERROR: Talos API never came up on ${FIRST_CP}. Last error:" >&2; echo "${VERSION_ERR}" >&2; exit 1; }
  sleep 10
done

BOOT_ARGS=(-n "${FIRST_CP}" -e "${FIRST_CP}" bootstrap)
if [ -n "${RECOVER_FROM:-}" ]; then
  [ -f "${RECOVER_FROM}" ] || { echo "ERROR: RECOVER_FROM snapshot not found: ${RECOVER_FROM}" >&2; exit 1; }
  echo "Recovering etcd from snapshot: ${RECOVER_FROM}"
  BOOT_ARGS+=(--recover-from="${RECOVER_FROM}")
else
  echo "Bootstrapping etcd ..."
fi
for attempt in $(seq 1 30); do
  BOOT_OUT=$(talosctl --talosconfig "${WORK_DIR}/talosconfig" "${BOOT_ARGS[@]}" 2>&1) && { echo "etcd ${RECOVER_FROM:+recovery }bootstrap issued"; break; }
  if echo "${BOOT_OUT}" | grep -qiE "AlreadyExists|etcd data directory is not empty"; then
    echo "etcd already bootstrapped"
    break
  fi
  [ "${attempt}" -eq 30 ] && { echo "ERROR: bootstrap never succeeded: ${BOOT_OUT}" >&2; exit 1; }
  sleep 10
done

KUBECONFIG_OUT="${WORK_DIR}/kubeconfig"
echo "Fetching kubeconfig (via apiserver VIP) ..."
for attempt in $(seq 1 60); do
  if talosctl --talosconfig "${WORK_DIR}/talosconfig" -n "${FIRST_CP}" kubeconfig "${KUBECONFIG_OUT}" --force >/dev/null 2>&1; then
    break
  fi
  [ "${attempt}" -eq 60 ] && { echo "ERROR: could not fetch kubeconfig" >&2; exit 1; }
  sleep 10
done

echo "==> Writing connection secrets to controlplane ..."
kubectl create secret generic "${KUBECONFIG_SECRET_NAME}" \
  --namespace "${KUBECONFIG_SECRET_NAMESPACE}" \
  --from-file=kubeconfig="${KUBECONFIG_OUT}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic "${TALOSCONFIG_SECRET_NAME}" \
  --namespace "${TALOSCONFIG_SECRET_NAMESPACE}" \
  --from-file=talosconfig="${WORK_DIR}/talosconfig" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "OK: ${KUBECONFIG_SECRET_NAMESPACE}/${KUBECONFIG_SECRET_NAME}, ${TALOSCONFIG_SECRET_NAMESPACE}/${TALOSCONFIG_SECRET_NAME}"

echo "==> etcd status:"
talosctl --talosconfig "${WORK_DIR}/talosconfig" -n "${CP_ADDRS}" etcd status || true

echo
echo "Cluster bootstrapped. Expected state: all Talos services healthy, nodes NotReady (CNI=none) until the baseline layer (M4 step 4) lands."
