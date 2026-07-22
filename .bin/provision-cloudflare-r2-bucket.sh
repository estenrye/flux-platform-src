#!/usr/bin/env bash
# Provision a Cloudflare R2 bucket and a scoped S3 API token for it, then
# SOPS-encrypt the credentials as a Kubernetes Secret and store them in
# 1Password. Safe to run for multiple buckets on the same cluster; each
# bucket gets its own Secret and 1Password item.
#
# Usage:
#   CLUSTER=controlplane \
#   BUCKET_NAME=openbao-snapshots \
#   SECRET_NS=openbao \
#   CF_API_TOKEN=<admin-token> \
#   .bin/provision-cloudflare-r2-bucket.sh
#
# Required env:
#   CLUSTER        — cluster name (must match a clusters/<name>/ directory)
#   BUCKET_NAME    — R2 bucket to create (e.g. openbao-snapshots)
#   SECRET_NS      — Kubernetes namespace the Secret will live in
#   CF_API_TOKEN   — Cloudflare API token with R2 Edit + Account Read perms
#                    (admin-level, one-time human credential; not stored)
#
# Optional env:
#   CF_ACCOUNT_ID  — auto-detected from the API if not set
#   OP_ACCOUNT     — 1Password account (default: ryefamily.1password.com)
#
# Outputs:
#   clusters/${CLUSTER}/secrets/cloudflare-r2-${BUCKET_NAME}.sops.yaml
#   1Password item "cloudflare-r2-${BUCKET_NAME}" in vault "${CLUSTER_NAME}"
#
# Cloudflare R2 API endpoints used:
#   GET  /accounts                                    — account ID detection
#   GET  /accounts/{id}/r2/buckets/{name}             — existence check
#   PUT  /accounts/{id}/r2/buckets/{name}             — bucket creation
#   POST /accounts/{id}/r2/tokens                     — scoped S3 token
#   (see rotate-cloudflare-r2-token.sh for token deletion during rotation)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OP_ACCOUNT="${OP_ACCOUNT:-ryefamily.1password.com}"

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"

: "${BUCKET_NAME:?BUCKET_NAME is required (e.g. openbao-snapshots)}"
: "${SECRET_NS:?SECRET_NS is required (Kubernetes namespace for the credential Secret)}"
: "${CF_API_TOKEN:?CF_API_TOKEN is required (Cloudflare API token with R2 Edit + Account Read)}"

OP_ITEM_NAME="cloudflare-r2-${BUCKET_NAME}"
SECRET_NAME="cloudflare-r2-${BUCKET_NAME}"
SECRET_OUT="${CLUSTER_PATH}/secrets/${SECRET_NAME}.sops.yaml"

# ── Prereqs ───────────────────────────────────────────────────────────────────
for cmd in curl jq sops op openssl; do
  command -v "${cmd}" >/dev/null || { error "Required command not found: ${cmd}"; exit 1; }
done

info "Cluster:       ${CLUSTER_NAME}"
info "Bucket:        ${BUCKET_NAME}"
info "Secret:        ${SECRET_NAME} in namespace ${SECRET_NS}"
info "1Password:     ${OP_ITEM_NAME} in vault ${CLUSTER_NAME}"
info "Output:        ${SECRET_OUT}"

# ── Guard: abort if 1Password item already exists ─────────────────────────────
EXISTING=$(op item get "${OP_ITEM_NAME}" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  --format json 2>/dev/null | jq -r '.id // empty' || true)
if [ -n "${EXISTING}" ]; then
  error "1Password item '${OP_ITEM_NAME}' already exists in vault '${CLUSTER_NAME}'."
  error "To rotate the token, run: CLUSTER=${CLUSTER} BUCKET_NAME=${BUCKET_NAME} .bin/rotate-cloudflare-r2-token.sh"
  exit 1
fi

# ── Cloudflare account ID ─────────────────────────────────────────────────────
if [ -z "${CF_ACCOUNT_ID:-}" ]; then
  info "Auto-detecting Cloudflare account ID..."
  CF_ACCOUNT_ID=$(curl -sf \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/accounts" \
    | jq -r '.result[0].id // empty')
  [ -n "${CF_ACCOUNT_ID}" ] || { error "Could not detect Cloudflare account ID — check CF_API_TOKEN permissions"; exit 1; }
  success "Account ID: ${CF_ACCOUNT_ID}"
fi

CF_R2_ENDPOINT="https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com"

# ── Create bucket (idempotent) ────────────────────────────────────────────────
info "Checking if bucket '${BUCKET_NAME}' already exists..."
BUCKET_EXISTS=$(curl -sf \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/r2/buckets/${BUCKET_NAME}" \
  | jq -r '.success' || echo "false")

if [ "${BUCKET_EXISTS}" = "true" ]; then
  warn "Bucket '${BUCKET_NAME}' already exists — skipping creation."
else
  info "Creating R2 bucket '${BUCKET_NAME}'..."
  CREATE_RESULT=$(curl -sf -X PUT \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/r2/buckets/${BUCKET_NAME}")
  echo "${CREATE_RESULT}" | jq -r '.success' | grep -q '^true$' \
    || { error "Bucket creation failed: $(echo "${CREATE_RESULT}" | jq -r '.errors')"; exit 1; }
  success "Bucket '${BUCKET_NAME}' created."
fi

# ── Temp dir for sensitive material ──────────────────────────────────────────
umask 077
TMP="$(mktemp -d)"
cleanup() {
  find "${TMP}" -type f -exec sh -c \
    'dd if=/dev/urandom of="$1" bs=1k count=4 conv=notrunc 2>/dev/null || true' _ {} \;
  rm -rf "${TMP}"
}
trap cleanup EXIT

# ── Look up R2 permission group IDs ──────────────────────────────────────────
# R2 S3-compatible tokens are standard Cloudflare API tokens with R2 permission
# policies. accessKeyId = token.id; secretAccessKey = SHA-256(token.value).
info "Looking up R2 bucket permission group IDs..."
PERM_GROUPS=$(curl -sf \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/tokens/permission_groups")
echo "${PERM_GROUPS}" | jq -r '.success' | grep -q '^true$' \
  || { error "Failed to list permission groups — check CF_API_TOKEN permissions"; exit 1; }

BUCKET_READ_ID=$(echo "${PERM_GROUPS}" | jq -r '.result[] | select(.name == "Workers R2 Storage Bucket Item Read") | .id')
BUCKET_WRITE_ID=$(echo "${PERM_GROUPS}" | jq -r '.result[] | select(.name == "Workers R2 Storage Bucket Item Write") | .id')

[ -n "${BUCKET_READ_ID}" ]  || { error "Could not find 'Workers R2 Storage Bucket Item Read' permission group"; exit 1; }
[ -n "${BUCKET_WRITE_ID}" ] || { error "Could not find 'Workers R2 Storage Bucket Item Write' permission group"; exit 1; }
info "Read group ID:  ${BUCKET_READ_ID}"
info "Write group ID: ${BUCKET_WRITE_ID}"

# Jurisdiction is "default" for buckets created without a location restriction.
CF_R2_JURISDICTION="${CF_R2_JURISDICTION:-default}"
RESOURCE_KEY="com.cloudflare.edge.r2.bucket.${CF_ACCOUNT_ID}_${CF_R2_JURISDICTION}_${BUCKET_NAME}"

# ── Create scoped R2 API token ────────────────────────────────────────────────
info "Creating scoped R2 API token for bucket '${BUCKET_NAME}'..."
TOKEN_RESPONSE=$(curl -sf -X POST \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "$(jq -n \
    --arg name "${CLUSTER_NAME}-${BUCKET_NAME}-rw" \
    --arg resource_key "${RESOURCE_KEY}" \
    --arg read_id "${BUCKET_READ_ID}" \
    --arg write_id "${BUCKET_WRITE_ID}" \
    '{
      name: $name,
      policies: [{
        effect: "allow",
        resources: {($resource_key): "*"},
        permission_groups: [{id: $read_id}, {id: $write_id}]
      }]
    }')" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/tokens")

echo "${TOKEN_RESPONSE}" > "${TMP}/token-response.json"

echo "${TOKEN_RESPONSE}" | jq -r '.success' | grep -q '^true$' \
  || { error "R2 token creation failed: $(echo "${TOKEN_RESPONSE}" | jq -r '.errors')"; exit 1; }

TOKEN_ID=$(jq -r '.result.id' "${TMP}/token-response.json")
TOKEN_VALUE=$(jq -r '.result.value' "${TMP}/token-response.json")

[ -n "${TOKEN_ID}" ]    && [ "${TOKEN_ID}" != "null" ]    \
  || { error "Token response missing 'id' — API shape may have changed"; exit 1; }
[ -n "${TOKEN_VALUE}" ] && [ "${TOKEN_VALUE}" != "null" ] \
  || { error "Token response missing 'value' — API shape may have changed"; exit 1; }

# S3 access key = token id; S3 secret = SHA-256 hex of token value
ACCESS_KEY_ID="${TOKEN_ID}"
SECRET_ACCESS_KEY=$(printf '%s' "${TOKEN_VALUE}" | openssl dgst -sha256 | awk '{print $NF}')

success "R2 token created (access-key-id: ${ACCESS_KEY_ID})"

# ── Store in 1Password ────────────────────────────────────────────────────────
info "Storing credentials in 1Password (vault: ${CLUSTER_NAME}, item: ${OP_ITEM_NAME})..."
op item create \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  --category "API Credential" \
  --title "${OP_ITEM_NAME}" \
  "token-id=${TOKEN_ID}" \
  "access-key-id=${ACCESS_KEY_ID}" \
  "secret-access-key[concealed]=${SECRET_ACCESS_KEY}" \
  "account-id=${CF_ACCOUNT_ID}" \
  "endpoint=${CF_R2_ENDPOINT}" \
  "bucket=${BUCKET_NAME}" \
  >/dev/null
success "1Password item '${OP_ITEM_NAME}' created in vault '${CLUSTER_NAME}'."

# ── SOPS-encrypt Kubernetes Secret ────────────────────────────────────────────
AGE_RECIPIENTS="$(grep -o 'age1[a-z0-9]*' "${CLUSTER_PATH}/.sops.yaml" | sort -u | paste -sd, -)"
[ -n "${AGE_RECIPIENTS}" ] \
  || { error "No age recipients found in ${CLUSTER_PATH}/.sops.yaml"; exit 1; }
info "age recipients: ${AGE_RECIPIENTS}"

cat > "${TMP}/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${SECRET_NS}
stringData:
  access-key-id: ${ACCESS_KEY_ID}
  secret-access-key: ${SECRET_ACCESS_KEY}
  endpoint: ${CF_R2_ENDPOINT}
  bucket: ${BUCKET_NAME}
EOF

info "SOPS-encrypting Secret..."
mkdir -p "$(dirname "${SECRET_OUT}")"
sops --config /dev/null \
  -e \
  --age "${AGE_RECIPIENTS}" \
  --encrypted-regex '^(data|stringData)$' \
  "${TMP}/secret.yaml" > "${SECRET_OUT}"

grep -q 'ENC\[' "${SECRET_OUT}" \
  || { rm -f "${SECRET_OUT}"; error "Encryption produced no ENC[ markers — aborting"; exit 1; }
success "SOPS-encrypted Secret written to: ${SECRET_OUT}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
success "Provisioning complete."
info "Bucket:        ${BUCKET_NAME}"
info "R2 endpoint:   ${CF_R2_ENDPOINT}"
info "Token ID:      ${TOKEN_ID}  (stored in 1Password for rotation)"
info "1Password:     ${OP_ITEM_NAME} in vault ${CLUSTER_NAME}"
info "Secret file:   ${SECRET_OUT}"
echo ""
info "Next steps:"
info "  1. Add ${SECRET_OUT} to clusters/${CLUSTER}/kustomization.yaml (or the"
info "     relevant sub-kustomization) and commit."
info "  2. Reference the Secret from your CronJob/Deployment via secretKeyRef:"
info "       access-key-id, secret-access-key, endpoint, bucket"
info "  3. Rotation: CLUSTER=${CLUSTER} BUCKET_NAME=${BUCKET_NAME} .bin/rotate-cloudflare-r2-token.sh"
