#!/usr/bin/env bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"

info "Generating an age key pair for SOPS encryption..."
AGE_KEY_FILE_PRIVATE="${SCRIPT_DIR}/../${CLUSTER_DIR}/.sops.age-key"
SOPS_CONFIG_FILE_PUBLIC="${SCRIPT_DIR}/../${CLUSTER_DIR}/.sops.yaml"

if [[ -f "${AGE_KEY_FILE_PRIVATE}" || -f "${SOPS_CONFIG_FILE_PUBLIC}" ]]; then
    warn "SOPS age key pair already exists in cluster directory: ${CLUSTER_DIR}"
    read -p "Do you want to overwrite the existing keys? [y/N]: " OVERWRITE_KEYS
    OVERWRITE_KEYS=${OVERWRITE_KEYS:-n}
    if [[ ! "${OVERWRITE_KEYS}" =~ ^[Yy]$ ]]; then
        info "Aborting. No changes made."
        exit 0
    fi
    warn "Deleting existing age key files..."
    rm -f "${AGE_KEY_FILE_PRIVATE}" "${SOPS_CONFIG_FILE_PUBLIC}"
    info "Existing age key files deleted."
fi

# Generate age key pair
info "Generating new age key pair..."

age-keygen -o "${AGE_KEY_FILE_PRIVATE}" 

info "Private key written to: ${AGE_KEY_FILE_PRIVATE}"
info "Generating public key from private key..."

cat > "${SOPS_CONFIG_FILE_PUBLIC}" <<EOF
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: ^(data|stringData)$
    age: >-
      $(age-keygen -y "${AGE_KEY_FILE_PRIVATE}")
EOF

info "Public key written to: ${SOPS_CONFIG_FILE_PUBLIC}"
info "✓ SOPS age key pair generated successfully."
echo ""
info "Generating SOPS secret manifest..."

SOPS_SECRET_FILE="${SCRIPT_DIR}/../${CLUSTER_DIR}/flux-sops-secret.yaml"
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey="${AGE_KEY_FILE_PRIVATE}" \
  --dry-run=client -o yaml > "${SOPS_SECRET_FILE}"

info "SOPS secret manifest written to: ${SOPS_SECRET_FILE}"

info "Applying unencrypted SOPS secret to the cluster..."
kubectl apply --force-conflicts --server-side -f "${SOPS_SECRET_FILE}" --kubeconfig="${KUBECONFIG}"

info "✓ SOPS secret applied successfully."
echo ""

info "Encrypting SOPS secret manifest with SOPS..."

pushd "${SCRIPT_DIR}/../${CLUSTER_DIR}"
sops --encrypt --in-place "flux-sops-secret.yaml"
popd

info "✓ SOPS secret manifest encrypted successfully."
echo ""

info "Adding SOPS secret manifest to kustomization.yaml..."

yq '(.resources // []) |= (. + ["flux-sops-secret.yaml"] | unique)' -i "${SCRIPT_DIR}/../${CLUSTER_DIR}/kustomization.yaml"

info "✓ SOPS secret manifest added to kustomization.yaml successfully."
echo ""
info "✓ Cluster directory structure updated successfully"
echo ""
info "Cluster details:"
info "  Directory: ${CLUSTER_DIR}"
info "  .sops.yaml file: ${SOPS_CONFIG_FILE_PUBLIC}"
echo ""
info "Next steps:"
info "  1. Bootstrap the GitHub deploy key by running: ./bootstrap/003_bootstrap_flux_git_secret.sh"
info "  2. Open a PR against the main branch with the new cluster overlay."
info "  3. Pull pull your branch after GitHub Actions registers the deploy key and creates your GroundCover ingestion key."
echo ""
