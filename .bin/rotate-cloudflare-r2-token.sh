#!/usr/bin/env bash
# Rotate the Cloudflare R2 API token for a provisioned bucket:
#   1. Read old token ID from 1Password
#   2. Create a new scoped R2 token with the same bucket permissions
#   3. Update 1Password with the new credentials
#   4. Re-encrypt the SOPS Secret with the new values (unless SOPS_ENCRYPT=false)
#   5. Delete the old token via the Cloudflare API
#
# Usage:
#   CLUSTER=controlplane \
#   BUCKET_NAME=openbao-snapshots \
#   CF_API_TOKEN=<admin-token> \
#   .bin/rotate-cloudflare-r2-token.sh
#
# Required env:
#   CLUSTER        — cluster name (must match a clusters/<name>/ directory)
#   BUCKET_NAME    — R2 bucket whose token is being rotated
#   CF_API_TOKEN   — Cloudflare API token with R2 Edit + Account Read perms
#                    (admin-level, one-time human credential; not stored)
#
# Optional env:
#   OP_ACCOUNT     — 1Password account (default: ryefamily.1password.com)
#   SOPS_ENCRYPT   — "true" (default) or "false". Must match how the bucket was
#                    provisioned. When false there is no SOPS Secret: the sops
#                    CLI is not required, nothing is re-encrypted, and only
#                    1Password is updated (consumers read it via ExternalSecret).
#
# The Cloudflare account ID and R2 endpoint are read from 1Password;
# CF_ACCOUNT_ID does not need to be set.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OP_ACCOUNT="${OP_ACCOUNT:-ryefamily.1password.com}"
SOPS_ENCRYPT="${SOPS_ENCRYPT:-true}"

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"

: "${BUCKET_NAME:?BUCKET_NAME is required (e.g. openbao-snapshots)}"
: "${CF_API_TOKEN:?CF_API_TOKEN is required (Cloudflare API token with R2 Edit + Account Read)}"

OP_ITEM_NAME="cloudflare-r2-${BUCKET_NAME}"
SECRET_NAME="cloudflare-r2-${BUCKET_NAME}"
SECRET_OUT="${CLUSTER_PATH}/secrets/${SECRET_NAME}.sops.yaml"

case "${SOPS_ENCRYPT}" in
  true|false) ;;
  *) error "SOPS_ENCRYPT must be 'true' or 'false' (got '${SOPS_ENCRYPT}')"; exit 1 ;;
esac

# ── Prereqs ───────────────────────────────────────────────────────────────────
PREREQS="curl jq op openssl"
[ "${SOPS_ENCRYPT}" = "true" ] && PREREQS="${PREREQS} sops"
for cmd in ${PREREQS}; do
  command -v "${cmd}" >/dev/null || { error "Required command not found: ${cmd}"; exit 1; }
done

# Checked before anything is created, so a forgotten SOPS_ENCRYPT=false on a
# bucket provisioned without SOPS fails fast instead of mid-rotation.
if [ "${SOPS_ENCRYPT}" = "true" ]; then
  [ -f "${SECRET_OUT}" ] \
    || { error "SOPS secret not found at ${SECRET_OUT} — has this bucket been provisioned? (If it was provisioned with SOPS_ENCRYPT=false, rotate with SOPS_ENCRYPT=false.)"; exit 1; }
fi

info "Cluster:    ${CLUSTER_NAME}"
info "Bucket:     ${BUCKET_NAME}"
info "1Password:  ${OP_ITEM_NAME} in vault ${CLUSTER_NAME}"
if [ "${SOPS_ENCRYPT}" = "true" ]; then
  info "SOPS:       ${SECRET_OUT}"
else
  info "SOPS:       disabled (SOPS_ENCRYPT=false) — only 1Password will be updated"
fi

# ── Read old credentials from 1Password ──────────────────────────────────────
# --reveal: recent op CLIs print a placeholder instead of the value for fields
# stored as concealed, which would otherwise be used as the token id/account id.
info "Reading existing credentials from 1Password..."
OLD_TOKEN_ID=$(op item get "${OP_ITEM_NAME}" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  --reveal --field "token-id" 2>/dev/null || true)
[ -n "${OLD_TOKEN_ID}" ] \
  || { error "token-id not found in 1Password item '${OP_ITEM_NAME}' — was this bucket provisioned with provision-cloudflare-r2-bucket.sh?"; exit 1; }

CF_ACCOUNT_ID=$(op item get "${OP_ITEM_NAME}" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  --reveal --field "account-id")
CF_R2_ENDPOINT=$(op item get "${OP_ITEM_NAME}" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  --reveal --field "endpoint")

success "Old token ID: ${OLD_TOKEN_ID}"
info "Account ID:   ${CF_ACCOUNT_ID}"

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

CF_R2_JURISDICTION="${CF_R2_JURISDICTION:-default}"
RESOURCE_KEY="com.cloudflare.edge.r2.bucket.${CF_ACCOUNT_ID}_${CF_R2_JURISDICTION}_${BUCKET_NAME}"

# ── Create new scoped R2 token ────────────────────────────────────────────────
info "Creating new R2 API token for bucket '${BUCKET_NAME}'..."
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

NEW_TOKEN_ID=$(jq -r '.result.id' "${TMP}/token-response.json")
NEW_TOKEN_VALUE=$(jq -r '.result.value' "${TMP}/token-response.json")

[ -n "${NEW_TOKEN_ID}" ]    && [ "${NEW_TOKEN_ID}" != "null" ]    \
  || { error "Token response missing 'id' — API shape may have changed"; exit 1; }
[ -n "${NEW_TOKEN_VALUE}" ] && [ "${NEW_TOKEN_VALUE}" != "null" ] \
  || { error "Token response missing 'value' — API shape may have changed"; exit 1; }

NEW_ACCESS_KEY_ID="${NEW_TOKEN_ID}"
NEW_SECRET_ACCESS_KEY=$(printf '%s' "${NEW_TOKEN_VALUE}" | openssl dgst -sha256 | awk '{print $NF}')

success "New token created (access-key-id: ${NEW_ACCESS_KEY_ID})"

# ── Update 1Password ──────────────────────────────────────────────────────────
info "Updating 1Password item '${OP_ITEM_NAME}'..."
op item edit "${OP_ITEM_NAME}" \
  --vault "${CLUSTER_NAME}" \
  --account "${OP_ACCOUNT}" \
  "token-id=${NEW_TOKEN_ID}" \
  "access-key-id=${NEW_ACCESS_KEY_ID}" \
  "secret-access-key[concealed]=${NEW_SECRET_ACCESS_KEY}" \
  >/dev/null
success "1Password updated."

# ── Re-encrypt SOPS Secret with new values ────────────────────────────────────
if [ "${SOPS_ENCRYPT}" = "true" ]; then
  AGE_RECIPIENTS="$(grep -o 'age1[a-z0-9]*' "${CLUSTER_PATH}/.sops.yaml" | sort -u | paste -sd, -)"
  [ -n "${AGE_RECIPIENTS}" ] \
    || { error "No age recipients found in ${CLUSTER_PATH}/.sops.yaml"; exit 1; }

  cat > "${TMP}/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: $(sops -d "${SECRET_OUT}" | grep '^\s*namespace:' | awk '{print $2}')
stringData:
  access-key-id: ${NEW_ACCESS_KEY_ID}
  secret-access-key: ${NEW_SECRET_ACCESS_KEY}
  endpoint: ${CF_R2_ENDPOINT}
  bucket: ${BUCKET_NAME}
EOF

  info "Re-encrypting SOPS Secret..."
  sops --config /dev/null \
    -e \
    --age "${AGE_RECIPIENTS}" \
    --encrypted-regex '^(data|stringData)$' \
    "${TMP}/secret.yaml" > "${SECRET_OUT}"

  grep -q 'ENC\[' "${SECRET_OUT}" \
    || { error "Re-encryption produced no ENC[ markers — aborting"; exit 1; }
  success "SOPS Secret re-encrypted at ${SECRET_OUT}."
else
  warn "SOPS_ENCRYPT=false — skipping SOPS Secret; credentials updated only in 1Password."
fi

# ── Delete old token ──────────────────────────────────────────────────────────
info "Deleting old R2 token (id: ${OLD_TOKEN_ID})..."
DELETE_RESULT=$(curl -sf -X DELETE \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/tokens/${OLD_TOKEN_ID}")
echo "${DELETE_RESULT}" | jq -r '.success' | grep -q '^true$' \
  || { error "Old token deletion failed: $(echo "${DELETE_RESULT}" | jq -r '.errors')"; exit 1; }
success "Old token deleted."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
success "Token rotation complete for bucket '${BUCKET_NAME}'."
info "New token ID:  ${NEW_TOKEN_ID}"
info "1Password:     ${OP_ITEM_NAME} in vault ${CLUSTER_NAME} — updated"
if [ "${SOPS_ENCRYPT}" = "true" ]; then
  info "Secret file:   ${SECRET_OUT} — re-encrypted"
fi
echo ""
info "Next steps:"
if [ "${SOPS_ENCRYPT}" = "true" ]; then
  info "  1. Commit the updated SOPS secret:"
  info "       git add ${SECRET_OUT}"
  info "       git commit -m 'chore: rotate cloudflare-r2-${BUCKET_NAME} token for ${CLUSTER_NAME}'"
  info "  2. After merge, force-sync ESO to pick up the new credentials:"
else
  info "  1. Force-sync ESO to pick up the new credentials (nothing to commit):"
fi
info "       kubectl annotate externalsecret <name> -n ${BUCKET_NAME%%\-*} \\"
info "         force-sync=\$(date +%s) --overwrite"
