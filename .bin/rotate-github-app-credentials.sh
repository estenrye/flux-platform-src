#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP_ACCOUNT="ryefamily.1password.com"
OP_VAULT="flux-platform-src"
OP_ITEM="render-flux-platform-src-app"

source "${SCRIPT_DIR}/lib/prompt-color.sh"

# ── JWT helper ──────────────────────────────────────────────────────────────
_make_jwt() {
  local private_key="$1"
  local app_id="$2"
  local now exp header payload signing_input sig

  now=$(date +%s)
  exp=$(( now + 540 ))  # 9 minutes (GitHub max is 10)

  header=$(printf '{"alg":"RS256","typ":"JWT"}' \
    | base64 | tr -d '=\n' | tr '+/' '-_')

  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "${now}" "${exp}" "${app_id}" \
    | base64 | tr -d '=\n' | tr '+/' '-_')

  signing_input="${header}.${payload}"

  sig=$(printf '%s' "${signing_input}" \
    | openssl dgst -sha256 -sign <(printf '%s' "${private_key}") -binary \
    | base64 | tr -d '=\n' | tr '+/' '-_')

  printf '%s.%s.%s' "${header}" "${payload}" "${sig}"
}

# ── Step 1: Read current credentials from 1Password ──────────────────────────
info "Reading current credentials from 1Password ..."
APP_ID=$(op item get "${OP_ITEM}" --vault "${OP_VAULT}" --account "${OP_ACCOUNT}" \
  --field app-id)
OLD_PRIVATE_KEY=$(op item get "${OP_ITEM}" --vault "${OP_VAULT}" --account "${OP_ACCOUNT}" \
  --field private-key)
success "Credentials read (app-id: ${APP_ID})."

# ── Step 2: List current keys — record old key ID ─────────────────────────────
info "Listing current GitHub App keys ..."
JWT=$(_make_jwt "${OLD_PRIVATE_KEY}" "${APP_ID}")

KEY_COUNT=$(gh api /app/keys \
  --header "Authorization: Bearer ${JWT}" \
  --header "Accept: application/vnd.github+json" \
  --jq 'length')

if [ "${KEY_COUNT}" -eq 0 ]; then
  error "No private keys found for app ${APP_ID}. Cannot rotate."
  exit 1
fi

if [ "${KEY_COUNT}" -gt 1 ]; then
  error "Multiple private keys found (${KEY_COUNT}). Clean up extras before rotating:"
  gh api /app/keys \
    --header "Authorization: Bearer ${JWT}" \
    --header "Accept: application/vnd.github+json" \
    --jq '.[] | "  id: \(.id)  created: \(.created_at)"'
  exit 1
fi

OLD_KEY_ID=$(gh api /app/keys \
  --header "Authorization: Bearer ${JWT}" \
  --header "Accept: application/vnd.github+json" \
  --jq '.[0].id')
success "Old key id: ${OLD_KEY_ID}"

# ── Step 3: Generate new private key ──────────────────────────────────────────
info "Generating new private key via GitHub API ..."
JWT=$(_make_jwt "${OLD_PRIVATE_KEY}" "${APP_ID}")

NEW_KEY_RESPONSE=$(gh api /app/keys \
  --method POST \
  --header "Authorization: Bearer ${JWT}" \
  --header "Accept: application/vnd.github+json")

NEW_PRIVATE_KEY=$(echo "${NEW_KEY_RESPONSE}" | jq -r '.pem')
NEW_KEY_ID=$(echo "${NEW_KEY_RESPONSE}" | jq -r '.id')
success "New key generated (id: ${NEW_KEY_ID})."

# ── Step 4: Update 1Password ───────────────────────────────────────────────────
info "Updating 1Password with new private key ..."
op item edit "${OP_ITEM}" \
  --vault "${OP_VAULT}" \
  --account "${OP_ACCOUNT}" \
  "private-key[concealed]=${NEW_PRIVATE_KEY}"
success "1Password updated."

# ── Step 5: Verify new key works ──────────────────────────────────────────────
info "Verifying new key can authenticate ..."
NEW_JWT=$(_make_jwt "${NEW_PRIVATE_KEY}" "${APP_ID}")

APP_SLUG=$(gh api /app \
  --header "Authorization: Bearer ${NEW_JWT}" \
  --header "Accept: application/vnd.github+json" \
  --jq '.slug' 2>/dev/null || true)

if [ -z "${APP_SLUG}" ]; then
  error "New key verification failed. Old key has NOT been deleted."
  error "Check the new key in 1Password and retry Step 5 manually."
  exit 1
fi
success "New key verified (app: ${APP_SLUG})."

# ── Step 6: Delete old key ─────────────────────────────────────────────────────
info "Deleting old key (id: ${OLD_KEY_ID}) ..."
NEW_JWT=$(_make_jwt "${NEW_PRIVATE_KEY}" "${APP_ID}")

gh api "/app/keys/${OLD_KEY_ID}" \
  --method DELETE \
  --header "Authorization: Bearer ${NEW_JWT}" \
  --header "Accept: application/vnd.github+json"
success "Old key deleted."

echo ""
success "GitHub App credential rotation complete."
info "The new key is active in 1Password and will be used on the next CI workflow run."
