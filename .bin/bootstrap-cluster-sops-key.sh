#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP_ACCOUNT="ryefamily.1password.com"
VAULT_USERS=${VAULT_USERS:?VAULT_USERS is required. Set it to a space-separated list of 1Password user emails.}

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"

# ── Step 1: Create 1Password vault ──────────────────────────────────────────
info "Creating 1Password vault '${CLUSTER_NAME}' ..."
VAULT_ID=$(op vault get "${CLUSTER_NAME}" --account "${OP_ACCOUNT}" --format json 2>/dev/null \
  | jq -r '.id // empty' || true)

if [ -z "${VAULT_ID}" ]; then
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

# ── Step 2: Create 1Password service account ────────────────────────────────
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

# ── Step 3: Generate age key ──────────────────────────────────────────────────
AGE_KEY_FILE="${CLUSTER_PATH}/.sops.age-key"
SOPS_CONFIG="${CLUSTER_PATH}/.sops.yaml"

info "Checking age key for '${CLUSTER_NAME}' ..."
if [ -f "${AGE_KEY_FILE}" ]; then
  info "Age key already exists at ${AGE_KEY_FILE} — skipping generation."
else
  info "Generating new age key pair ..."
  age-keygen -o "${AGE_KEY_FILE}"
  success "Age key generated: ${AGE_KEY_FILE}"
fi

AGE_PUBLIC_KEY=$(age-keygen -y "${AGE_KEY_FILE}")

# Store private key in 1Password for recovery
if ! op item get "sops-age-key" \
    --vault "${CLUSTER_NAME}" \
    --account "${OP_ACCOUNT}" >/dev/null 2>&1; then
  op item create \
    --category "API Credential" \
    --title "sops-age-key" \
    --vault "${CLUSTER_NAME}" \
    --account "${OP_ACCOUNT}" \
    "private-key[concealed]=$(cat "${AGE_KEY_FILE}")"
  success "Age private key stored in 1Password vault '${CLUSTER_NAME}'."
else
  info "sops-age-key already in 1Password — skipping."
fi

# Write .sops.yaml
if [ ! -f "${SOPS_CONFIG}" ]; then
  cat > "${SOPS_CONFIG}" <<EOF
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: ^(data|stringData)$
    age: >-
      ${AGE_PUBLIC_KEY}
EOF
  success ".sops.yaml written."
else
  info ".sops.yaml already exists — skipping."
fi

# ── Step 4: Apply sops-age Kubernetes secret ──────────────────────────────────
info "Ensuring flux-system namespace exists ..."
kubectl create namespace flux-system \
  --kubeconfig="${KUBECONFIG}" \
  --dry-run=client -o yaml \
  | kubectl apply --server-side -f - --kubeconfig="${KUBECONFIG}"

info "Applying sops-age Kubernetes secret ..."
# Use --from-file so kubectl handles the multiline key content correctly.
# The age key file includes comment lines; embedding it in a YAML heredoc would break parsing.
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey="${AGE_KEY_FILE}" \
  --dry-run=client -o yaml \
  | kubectl apply --server-side --force-conflicts \
      -f - --kubeconfig="${KUBECONFIG}"
success "sops-age secret applied to cluster."

# ── Step 5: Generate cluster resource files ───────────────────────────────────
RESOURCES_DIR="${CLUSTER_PATH}/resources"
mkdir -p "${RESOURCES_DIR}"

# Always overwrite generated resource files — they contain no user-modified content
# and must stay in sync with the bootstrap template. The encrypted secret
# (eso.service-account-secret.yaml) is handled separately in Step 6.
write_resource() {
  local path="$1"
  local content="$2"
  printf '%s\n' "${content}" > "${path}"
  success "Written: $(basename "${path}")"
}

write_resource "${RESOURCES_DIR}/eso.cluster-secret-store.yaml" \
"apiVersion: external-secrets.io/v1
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
        version: v1"

write_resource "${RESOURCES_DIR}/flux.ssh-key-generator.yaml" \
"apiVersion: generators.external-secrets.io/v1alpha1
kind: SSHKey
metadata:
  name: ecdsa-key
  namespace: flux-system
spec:
  keyType: \"ecdsa\"
  keySize: 521
  comment: \"flux@${CLUSTER_NAME}\""

write_resource "${RESOURCES_DIR}/flux.ssh-key-secret.yaml" \
'apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: flux-ssh-key-secret
  namespace: flux-system
spec:
  refreshInterval: 1h0m0s
  refreshPolicy: CreatedOnce
  target:
    name: flux-ssh-key-secret
    template:
      metadata:
        annotations:
          description: "Managed by External Secrets Operator"
      data:
        identity: "{{ .privateKey }}"
        identity.pub: "{{ .publicKey }}"
        known_hosts: |
          github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: SSHKey
          name: ecdsa-key'

write_resource "${RESOURCES_DIR}/flux.source.git.yaml" \
"apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-platform-rendered
  namespace: flux-system
spec:
  interval: 1m0s
  ref:
    branch: main
  url: ssh://git@github.com/${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME}.git
  secretRef:
    name: flux-ssh-key-secret"

write_resource "${RESOURCES_DIR}/flux.kustomization.yaml" \
"apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-platform
  namespace: flux-system
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  interval: 10m0s
  path: ./clusters/${CLUSTER_NAME}
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-platform-rendered
  wait: false"

cat > "${CLUSTER_PATH}/kustomization.yaml" <<'KEOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../applications/priority-classes/v0.0.1
- ../../applications/prometheus-operator-crds/v28.0.1
- ../../applications/external-secrets-operator/v2.4.1
- ../../applications/flux/v2.7.5
- resources/eso.service-account-secret.yaml
- resources/eso.cluster-secret-store.yaml
- resources/flux.ssh-key-generator.yaml
- resources/flux.ssh-key-secret.yaml
- resources/flux.source.git.yaml
- resources/flux.kustomization.yaml
KEOF
success "Written: kustomization.yaml"

# ── Step 6: Encrypt service account token ────────────────────────────────────
ESO_SECRET="${RESOURCES_DIR}/eso.service-account-secret.yaml"

if [ -f "${ESO_SECRET}" ]; then
  info "eso.service-account-secret.yaml already exists — skipping encryption."
else
  info "Encrypting service account token with SOPS ..."
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

  sops --encrypt \
    --config "${SOPS_CONFIG}" \
    --input-type yaml \
    --output-type yaml \
    "${SECRET_TMPFILE}" > "${ESO_SECRET}"
  success "eso.service-account-secret.yaml encrypted and written."
fi

# ── Step 7: Commit ────────────────────────────────────────────────────────────
info "Staging cluster files ..."
git -C "${REPO_ROOT}" add "${CLUSTER_DIR}/"

if git -C "${REPO_ROOT}" diff --cached --quiet; then
  info "No changes to commit — all files already existed."
else
  git -C "${REPO_ROOT}" commit \
    -m "feat: bootstrap cluster ${CLUSTER_NAME} — SOPS key, 1Password resources, and cluster manifests"
  success "Committed."
fi

echo ""
success "Phase 1 bootstrap complete for ${CLUSTER_NAME}."
echo ""
info "Next steps:"
info "  1. Push this branch and open a PR so CI renders the cluster manifests."
info "  2. Merge the PR so the rendered repo is updated."
info "  3. Install Flux on the cluster."
info "  4. Deploy the cluster configuration:"
info "       make deploy-cluster CLUSTER=${CLUSTER}"
info "  5. Once ESO is running and has created flux-ssh-key-secret, run:"
info "       make bootstrap-cluster-deploy-key CLUSTER=${CLUSTER}"
