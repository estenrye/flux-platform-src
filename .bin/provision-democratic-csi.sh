#!/usr/bin/env bash
# Create SOPS-encrypted democratic-csi driver config secrets for a cluster.
# Reads the TrueNAS API key from 1Password and writes:
#   clusters/${CLUSTER}/resources/democratic-csi-nfs.driver-config.sops.yaml
#   clusters/${CLUSTER}/resources/democratic-csi-iscsi.driver-config.sops.yaml
#
# Usage:
#   CLUSTER=controlplane .bin/provision-democratic-csi.sh
#
# Required env:
#   CLUSTER  — cluster name (must match clusters/<name>/ directory)
#
# Optional env (defaults derived from TrueNAS 1Password item):
#   TRUENAS_HOST          — TrueNAS HTTPS hostname (default: from 1Password hostname field)
#   TRUENAS_PORT          — TrueNAS HTTPS port (default: 443)
#   NFS_SERVER_ULA        — NFS server ULA IPv6 (default: from 1Password notes or prompted)
#   ISCSI_PORTAL          — iSCSI portal in [IPv6]:port form (default: derived from NFS_SERVER_ULA)
#   ZFS_POOL              — ZFS pool name (default: flash-pool)
#   ISCSI_PORTAL_GROUP    — TrueNAS iSCSI portal group ID (default: 1)
#   ISCSI_INITIATOR_GROUP — TrueNAS iSCSI initiator group ID (default: 1)
#   OP_ACCOUNT            — 1Password account (default: ryefamily.1password.com)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP_ACCOUNT="${OP_ACCOUNT:-ryefamily.1password.com}"

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"

OP_ITEM_NAME="truenas-api-key"

for cmd in sops op; do
  command -v "${cmd}" >/dev/null || { error "Required command not found: ${cmd}"; exit 1; }
done

# ── Read TrueNAS credentials from 1Password ───────────────────────────────────
info "Reading TrueNAS credentials from 1Password (vault: ${CLUSTER_NAME}, item: ${OP_ITEM_NAME})..."

TRUENAS_API_KEY=$(op item get "${OP_ITEM_NAME}" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  --field credential \
  --reveal 2>/dev/null || true)
[ -n "${TRUENAS_API_KEY}" ] \
  || { error "Could not read 'credential' from 1Password item '${OP_ITEM_NAME}' in vault '${CLUSTER_NAME}'."; exit 1; }

TRUENAS_HOST="${TRUENAS_HOST:-$(op item get "${OP_ITEM_NAME}" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  --field hostname 2>/dev/null || echo "")}"
[ -n "${TRUENAS_HOST}" ] \
  || { error "TRUENAS_HOST not set and 'hostname' field not found in 1Password item '${OP_ITEM_NAME}'."; exit 1; }

success "TrueNAS host: ${TRUENAS_HOST}"

TRUENAS_PORT="${TRUENAS_PORT:-443}"
ZFS_POOL="${ZFS_POOL:-flash-pool}"
ISCSI_PORTAL_GROUP="${ISCSI_PORTAL_GROUP:-1}"
ISCSI_INITIATOR_GROUP="${ISCSI_INITIATOR_GROUP:-1}"

if [ -z "${NFS_SERVER_ULA:-}" ]; then
  error "NFS_SERVER_ULA is required (the NAS's site-local ULA IPv6 address for NFS mounts)."
  error "Example: NFS_SERVER_ULA=fd97:45c2:b3a1:100::1000 CLUSTER=${CLUSTER} .bin/provision-democratic-csi.sh"
  exit 1
fi

ISCSI_PORTAL="${ISCSI_PORTAL:-[${NFS_SERVER_ULA}]:3260}"

info "NFS server ULA: ${NFS_SERVER_ULA}"
info "iSCSI portal:   ${ISCSI_PORTAL}"
info "ZFS pool:       ${ZFS_POOL}"

# ── AGE recipients ────────────────────────────────────────────────────────────
AGE_RECIPIENTS="$(grep -o 'age1[a-z0-9]*' "${CLUSTER_PATH}/.sops.yaml" | sort -u | paste -sd, -)"
[ -n "${AGE_RECIPIENTS}" ] \
  || { error "No age recipients found in ${CLUSTER_PATH}/.sops.yaml"; exit 1; }
info "age recipients: ${AGE_RECIPIENTS}"

# ── Temp dir ──────────────────────────────────────────────────────────────────
umask 077
TMP="$(mktemp -d)"
cleanup() {
  find "${TMP}" -type f -exec sh -c \
    'dd if=/dev/urandom of="$1" bs=1k count=4 conv=notrunc 2>/dev/null || true' _ {} \;
  rm -rf "${TMP}"
}
trap cleanup EXIT

RESOURCES_DIR="${CLUSTER_PATH}/resources"
mkdir -p "${RESOURCES_DIR}"

# ── NFS driver config ─────────────────────────────────────────────────────────
NFS_OUT="${RESOURCES_DIR}/democratic-csi-nfs.driver-config.sops.yaml"

info "Writing NFS driver config secret..."
cat > "${TMP}/nfs-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: democratic-csi-nfs-driver-config
  namespace: democratic-csi
  annotations:
    ignore-check.kube-linter.io/schema-validation: "SOPS-encrypted secret; top-level sops field is expected and non-standard by design"
stringData:
  driver-config-file.yaml: |
    driver: freenas-api-nfs
    instance_id: ${CLUSTER_NAME}-nfs

    httpConnection:
      protocol: https
      host: ${TRUENAS_HOST}
      port: ${TRUENAS_PORT}
      apiKey: ${TRUENAS_API_KEY}
      allowInsecure: true

    zfs:
      datasetParentName: ${ZFS_POOL}/k8s/${CLUSTER_NAME}/nfs-v
      detachedSnapshotsDatasetParentName: ${ZFS_POOL}/k8s/${CLUSTER_NAME}/nfs-snap
      datasetEnableQuotas: true
      datasetEnableReservation: false
      datasetPermissionsMode: "0777"
      # datasetPermissionsUser + datasetPermissionsGroup intentionally OMITTED:
      # broken on TrueNAS SCALE 25.10.x (democratic-csi#564 — silent race on
      # the global perm_change lock causes setperm calls to be coalesced, leaving
      # some datasets root:root 0755 while the API reports success).
      # fsGroupPolicy: File handles CNPG uid 26 ownership at mount time instead.

    nfs:
      shareHost: "${NFS_SERVER_ULA}"
      shareAlldirs: false
      shareAllowedHosts: []
      shareAllowedNetworks: []
      shareMaprootUser: root
      shareMaprootGroup: root
      shareMapallUser: ""
      shareMapallGroup: ""
EOF

sops --config /dev/null \
  -e \
  --age "${AGE_RECIPIENTS}" \
  --encrypted-regex '^(data|stringData)$' \
  "${TMP}/nfs-secret.yaml" > "${NFS_OUT}"

grep -q 'ENC\[' "${NFS_OUT}" \
  || { rm -f "${NFS_OUT}"; error "NFS secret encryption produced no ENC[ markers — aborting"; exit 1; }
success "NFS driver config written to: ${NFS_OUT}"

# ── iSCSI driver config ───────────────────────────────────────────────────────
ISCSI_OUT="${RESOURCES_DIR}/democratic-csi-iscsi.driver-config.sops.yaml"

info "Writing iSCSI driver config secret..."
cat > "${TMP}/iscsi-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: democratic-csi-iscsi-driver-config
  namespace: democratic-csi
  annotations:
    ignore-check.kube-linter.io/schema-validation: "SOPS-encrypted secret; top-level sops field is expected and non-standard by design"
stringData:
  driver-config-file.yaml: |
    driver: freenas-api-iscsi
    instance_id: ${CLUSTER_NAME}-iscsi

    httpConnection:
      protocol: https
      host: ${TRUENAS_HOST}
      port: ${TRUENAS_PORT}
      apiKey: ${TRUENAS_API_KEY}
      allowInsecure: true

    zfs:
      datasetParentName: ${ZFS_POOL}/k8s/${CLUSTER_NAME}/iscsi-v
      detachedSnapshotsDatasetParentName: ${ZFS_POOL}/k8s/${CLUSTER_NAME}/iscsi-snap
      zvolCompression: lz4
      zvolDedup: false
      zvolEnableReservation: false
      zvolBlocksize: "16K"

    iscsi:
      targetPortal: "${ISCSI_PORTAL}"
      targetPortals: []
      interface: ""
      namePrefix: csi-
      nameSuffix: "-${CLUSTER_NAME}"
      targetGroups:
        - targetGroupPortalGroup: ${ISCSI_PORTAL_GROUP}
          targetGroupInitiatorGroup: ${ISCSI_INITIATOR_GROUP}
          targetGroupAuthType: None
          targetGroupAuthGroup:
      extentInsecureTpc: true
      extentXenCompat: false
      extentDisablePhysicalBlocksize: true
      extentBlocksize: 4096
      extentRpm: SSD
      extentAvailThreshold: 0
EOF

sops --config /dev/null \
  -e \
  --age "${AGE_RECIPIENTS}" \
  --encrypted-regex '^(data|stringData)$' \
  "${TMP}/iscsi-secret.yaml" > "${ISCSI_OUT}"

grep -q 'ENC\[' "${ISCSI_OUT}" \
  || { rm -f "${ISCSI_OUT}"; error "iSCSI secret encryption produced no ENC[ markers — aborting"; exit 1; }
success "iSCSI driver config written to: ${ISCSI_OUT}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
success "democratic-csi driver config secrets created for cluster '${CLUSTER_NAME}'."
echo ""
info "Files written:"
info "  ${NFS_OUT}"
info "  ${ISCSI_OUT}"
echo ""
info "Next steps:"
info "  1. Add both files to clusters/${CLUSTER_NAME}/kustomization.yaml under resources."
info "  2. Commit and open a PR:"
info "       git add ${NFS_OUT} ${ISCSI_OUT}"
info "       git commit -m 'feat(m3/step1): democratic-csi driver config secrets for ${CLUSTER_NAME}'"
info "  3. Verify portal group (${ISCSI_PORTAL_GROUP}) and initiator group (${ISCSI_INITIATOR_GROUP})"
info "     IDs match the TrueNAS iSCSI configuration. Override with:"
info "     ISCSI_PORTAL_GROUP=<id> ISCSI_INITIATOR_GROUP=<id> to re-run."
