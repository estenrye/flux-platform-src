#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP_ACCOUNT="ryefamily.1password.com"

if [ -z "${CLUSTER_PATH:-}" ] || [ -z "${CLUSTER_DIR:-}" ] || [ -z "${CLUSTER_NAME:-}" ] || [ -z "${REPO_ROOT:-}" ] || [ -z "${KUBECONFIG:-}" ]; then
  source "${SCRIPT_DIR}/lib/prompt-color.sh"
  source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
  source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"
else
  source "${SCRIPT_DIR}/lib/prompt-color.sh"
fi

AGE_KEY_FILE="${CLUSTER_PATH}/.sops.age-key"
SOPS_CONFIG="${CLUSTER_PATH}/.sops.yaml"

# ── Step 1: Read old private key from 1Password ───────────────────────────────
info "Reading old SOPS age key from 1Password ..."
OLD_PRIVATE_KEY=$(op item get "sops-age-key" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  --field private-key)
[ -n "${OLD_PRIVATE_KEY}" ] || { error "sops-age-key not found in vault '${CLUSTER_NAME}'"; exit 1; }
success "Old private key read."

# ── Step 2: Generate new age key pair ─────────────────────────────────────────
info "Generating new age key pair ..."
rm -f "${AGE_KEY_FILE}"
age-keygen -o "${AGE_KEY_FILE}"
NEW_PUBLIC_KEY=$(age-keygen -y "${AGE_KEY_FILE}")
success "New age key generated. Public key: ${NEW_PUBLIC_KEY}"

# ── Step 3: Update .sops.yaml with new public key ─────────────────────────────
info "Updating .sops.yaml with new public key ..."
cat > "${SOPS_CONFIG}" <<EOF
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: ^(data|stringData)$
    age: >-
      ${NEW_PUBLIC_KEY}
EOF
success ".sops.yaml updated."

# ── Step 4: Re-encrypt all SOPS-encrypted files ───────────────────────────────
ENCRYPTED_FILES=$(grep -rl "ENC\[" "${CLUSTER_PATH}/" 2>/dev/null || true)
if [ -z "${ENCRYPTED_FILES}" ]; then
  info "No SOPS-encrypted files found in ${CLUSTER_DIR}/ — skipping re-encryption."
else
  info "Re-encrypting SOPS files with new key ..."
  echo "${ENCRYPTED_FILES}" | while read -r f; do
    info "  updatekeys: ${f}"
    SOPS_AGE_KEY="${OLD_PRIVATE_KEY}" SOPS_CONFIG="${SOPS_CONFIG}" sops updatekeys --yes "${f}"
  done
  success "All SOPS files re-encrypted."
fi

# ── Step 5: Update sops-age Kubernetes secret (BEFORE pushing) ───────────────
info "Updating sops-age Kubernetes secret (must happen before git push) ..."
NEW_PRIVATE_KEY=$(cat "${AGE_KEY_FILE}")
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-literal=age.agekey="${NEW_PRIVATE_KEY}" \
  --dry-run=client -o yaml \
  | kubectl apply --server-side --force-conflicts \
      -f - --kubeconfig="${KUBECONFIG}"
success "sops-age Kubernetes secret updated."

# ── Step 6: Update 1Password sops-age-key item ───────────────────────────────
info "Updating 1Password sops-age-key with new private key ..."
op item edit "sops-age-key" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  "private-key[concealed]=${NEW_PRIVATE_KEY}"
success "1Password updated."

# ── Step 7: Commit and push ───────────────────────────────────────────────────
info "Committing and pushing ..."
git -C "${REPO_ROOT}" add "${CLUSTER_DIR}/.sops.yaml"
git -C "${REPO_ROOT}" add "${CLUSTER_DIR}/resources/"
if git -C "${REPO_ROOT}" diff --cached --quiet; then
  info "No changes to commit."
else
  git -C "${REPO_ROOT}" commit \
    -m "chore: rotate SOPS age key for ${CLUSTER_NAME}"
  git -C "${REPO_ROOT}" push
  success "Committed and pushed."
fi

echo ""
success "SOPS age key rotation complete for ${CLUSTER_NAME}."
