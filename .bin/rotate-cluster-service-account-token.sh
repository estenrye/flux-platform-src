#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP_ACCOUNT="ryefamily.1password.com"

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"

# ── Step 1: Prompt — delete old service account first ────────────────────────
echo ""
warn "Action required before continuing:"
warn "  1. Go to https://ryefamily.1password.com"
warn "  2. Navigate to Settings → Service Accounts"
warn "  3. Find the service account named '${CLUSTER_NAME}' and delete it"
echo ""
read -rp "Press Enter when deleted..."

# ── Step 2: Create new 1Password service account ──────────────────────────────
info "Creating new 1Password service account '${CLUSTER_NAME}' ..."
SA_TOKEN=$(op service-account create "${CLUSTER_NAME}" \
  --vault "${CLUSTER_NAME}":read_items \
  --account "${OP_ACCOUNT}" \
  --raw)
success "Service account created."

# ── Step 3: Store new token in 1Password vault ────────────────────────────────
info "Storing new token in 1Password vault '${CLUSTER_NAME}' ..."
op item edit "service-account-token" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  "credential[password]=${SA_TOKEN}"
success "Token stored in 1Password."

# ── Step 4: Patch Kubernetes secret immediately ───────────────────────────────
info "Patching onepassword-sdk-token in external-secrets-operator ..."
kubectl create secret generic "onepassword-sdk-token" \
  --namespace external-secrets-operator \
  --from-literal=token="${SA_TOKEN}" \
  --dry-run=client -o yaml \
  | kubectl apply --server-side --force-conflicts \
      -f - --kubeconfig="${KUBECONFIG}"
success "Kubernetes secret updated. ESO is now using the new token."

# ── Step 5: Re-encrypt eso.service-account-secret.yaml and commit ─────────────
info "Reading SOPS age key from 1Password ..."
AGE_PRIVATE_KEY=$(op item get "sops-age-key" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  --field private-key)

ESO_SECRET="${CLUSTER_PATH}/resources/eso.service-account-secret.yaml"
SECRET_TMPFILE=$(mktemp /tmp/eso-secret-XXXXXX.yaml)
trap "rm -f ${SECRET_TMPFILE}" EXIT

cat > "${SECRET_TMPFILE}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: onepassword-sdk-token
  namespace: external-secrets-operator
  annotations:
    ignore-check.kube-linter.io/schema-validation: "SOPS-encrypted secret; top-level sops field is expected and non-standard by design"
type: Opaque
stringData:
  token: ${SA_TOKEN}
EOF

info "Encrypting service account secret with SOPS ..."
SOPS_AGE_KEY="${AGE_PRIVATE_KEY}" sops --encrypt \
  --config "${CLUSTER_PATH}/.sops.yaml" \
  --input-type yaml \
  --output-type yaml \
  "${SECRET_TMPFILE}" > "${ESO_SECRET}"
success "eso.service-account-secret.yaml re-encrypted."

info "Committing and pushing ..."
git -C "${REPO_ROOT}" add "${CLUSTER_DIR}/resources/eso.service-account-secret.yaml"
git -C "${REPO_ROOT}" commit \
  -m "chore: rotate service account token for ${CLUSTER_NAME}"
git -C "${REPO_ROOT}" push
success "Committed and pushed."

echo ""
success "Service account token rotation complete for ${CLUSTER_NAME}."
