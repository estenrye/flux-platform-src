#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP_ACCOUNT="ryefamily.1password.com"

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"

# Provisions (or reuses) the 1Password vault + service account ESO needs to
# reach it, encrypts the resulting token as this cluster's
# eso.service-account-secret.yaml, and writes eso.cluster-secret-store.yaml
# pointed at that vault. Extracted out of bootstrap-cluster-sops-key.sh's
# Steps 2/6 so it can run standalone and idempotently on a cluster whose
# SOPS key already exists but whose ESO ClusterSecretStore was never wired
# up (e.g. controlplane, M2 step 9) -- unlike bootstrap-cluster-sops-key.sh,
# this script never touches clusters/<name>/kustomization.yaml.
#
# Does NOT duplicate shared credential items (github-auth-app,
# cloudflare-api-token, ...) into the new vault -- that is a distinct,
# one-time manual step. Print instructions for it at the end.

RESOURCES_DIR="${CLUSTER_PATH}/resources"
mkdir -p "${RESOURCES_DIR}"

# ── Step 1: 1Password vault ──────────────────────────────────────────────────
info "Checking 1Password vault '${CLUSTER_NAME}' ..."
VAULT_ID=$(op vault get "${CLUSTER_NAME}" --account "${OP_ACCOUNT}" --format json 2>/dev/null \
  | jq -r '.id // empty' || true)

if [ -z "${VAULT_ID}" ]; then
  : "${VAULT_USERS:?VAULT_USERS is required to create a new vault. Set it to a space-separated list of 1Password user emails.}"
  VAULT_ID=$(op vault create "${CLUSTER_NAME}" --account "${OP_ACCOUNT}" --format json | jq -r '.id')
  success "Vault created: ${CLUSTER_NAME} (${VAULT_ID})"

  info "Granting Manager access to vault '${CLUSTER_NAME}' ..."
  # shellcheck disable=SC2086
  for USER in ${VAULT_USERS}; do
    op vault user grant \
      --vault "${CLUSTER_NAME}" \
      --user "${USER}" \
      --permissions "allow_viewing,allow_editing,allow_managing" \
      --account "${OP_ACCOUNT}"
    success "  Access granted: ${USER}"
  done
else
  info "Vault '${CLUSTER_NAME}' already exists (${VAULT_ID}) — skipping."
fi

# ── Step 2: 1Password service account ────────────────────────────────────────
info "Checking for service account token in vault '${CLUSTER_NAME}' ..."
SA_TOKEN=$(op item get "service-account-token" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  --field credential 2>/dev/null || true)

if [ -z "${SA_TOKEN}" ]; then
  info "Creating service account '${CLUSTER_NAME}' ..."
  SA_TOKEN=$(op service-account create "${CLUSTER_NAME}" \
    --vault "${CLUSTER_NAME}":read_items \
    --account "${OP_ACCOUNT}" \
    --raw)

  op item create \
    --category "API Credential" \
    --title "service-account-token" \
    --vault "${CLUSTER_NAME}" \
    --account "${OP_ACCOUNT}" \
    "credential[password]=${SA_TOKEN}"
  success "Service account created and token stored in 1Password."
else
  info "Service account token already exists in vault — skipping."
fi

# ── Step 3: Encrypt onepassword-sdk-token with this cluster's SOPS key ──────
ESO_SECRET="${RESOURCES_DIR}/eso.service-account-secret.yaml"

if [ -f "${ESO_SECRET}" ]; then
  info "eso.service-account-secret.yaml already exists — skipping encryption."
else
  info "Encrypting service account token with SOPS ..."
  SECRET_TMPFILE=$(mktemp /tmp/eso-secret-XXXXXX.yaml)
  trap 'rm -f "${SECRET_TMPFILE}"' EXIT

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

  sops --encrypt \
    --config "${CLUSTER_PATH}/.sops.yaml" \
    --input-type yaml \
    --output-type yaml \
    "${SECRET_TMPFILE}" > "${ESO_SECRET}"
  success "eso.service-account-secret.yaml encrypted and written."
fi

# ── Step 4: ClusterSecretStore ───────────────────────────────────────────────
CLUSTER_SECRET_STORE="${RESOURCES_DIR}/eso.cluster-secret-store.yaml"

if [ -f "${CLUSTER_SECRET_STORE}" ]; then
  info "eso.cluster-secret-store.yaml already exists — leaving as-is."
else
  cat > "${CLUSTER_SECRET_STORE}" <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: 1password-sdk
  namespace: external-secrets-operator
spec:
  conditions:
    - namespaces:
      - crossplane-system
  provider:
    onepasswordSDK:
      vault: ${CLUSTER_NAME}
      auth:
        serviceAccountSecretRef:
          name: onepassword-sdk-token
          namespace: external-secrets-operator
          key: token
      integrationInfo:
        name: integration-info
        version: v1
EOF
  success "eso.cluster-secret-store.yaml written."
fi

# ── Step 5: Apply immediately so ESO doesn't wait for a Flux reconcile ──────
info "Applying onepassword-sdk-token to the live cluster ..."
kubectl create namespace external-secrets-operator \
  --kubeconfig="${KUBECONFIG}" \
  --dry-run=client -o yaml \
  | kubectl apply --server-side -f - --kubeconfig="${KUBECONFIG}"

kubectl create secret generic "onepassword-sdk-token" \
  --namespace external-secrets-operator \
  --from-literal=token="${SA_TOKEN}" \
  --dry-run=client -o yaml \
  | kubectl apply --server-side --force-conflicts \
      -f - --kubeconfig="${KUBECONFIG}"
success "onepassword-sdk-token applied to the cluster."

echo ""
success "Secret store bootstrap complete for ${CLUSTER_NAME}."
echo ""
info "Next steps:"
info "  1. Add resources/eso.service-account-secret.yaml and"
info "     resources/eso.cluster-secret-store.yaml to"
info "     clusters/${CLUSTER_NAME}/kustomization.yaml if not already present."
info "  2. This vault ('${CLUSTER_NAME}') is empty except for its own"
info "     service-account-token item. Any ExternalSecret that reads a"
info "     shared credential (e.g. github-auth-app, cloudflare-api-token)"
info "     needs that item duplicated into this vault first -- 'op item get"
info "     <item> --vault <source>' then 'op item create' into"
info "     '${CLUSTER_NAME}', or share the item across vaults from the"
info "     1Password UI."
info "  3. Commit and push:"
info "       git add ${CLUSTER_DIR}/resources/eso.service-account-secret.yaml ${CLUSTER_DIR}/resources/eso.cluster-secret-store.yaml"
