#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP_ACCOUNT="ryefamily.1password.com"
VAULT="flux-platform-src"
SA_NAME="flux-platform-src-ci"
SOURCE_REPO="estenrye/flux-platform-src"

source "${SCRIPT_DIR}/lib/prompt-color.sh"

# ── Step 1: Prompt — delete old service account first ────────────────────────
echo ""
warn "Action required before continuing:"
warn "  1. Go to https://ryefamily.1password.com"
warn "  2. Navigate to Settings → Service Accounts"
warn "  3. Find the service account named '${SA_NAME}' and delete it"
echo ""
read -rp "Press Enter when deleted..."

# ── Step 2: Create new 1Password service account ──────────────────────────────
info "Creating new 1Password service account '${SA_NAME}' ..."
SA_TOKEN=$(op service-account create "${SA_NAME}" \
  --vault "${VAULT}":read_items \
  --account "${OP_ACCOUNT}" \
  --raw)
success "Service account created."

# ── Step 3: Store new token in 1Password vault ────────────────────────────────
info "Storing new token in 1Password vault '${VAULT}' ..."
op item edit "${SA_NAME}-op-token" \
  --vault "${VAULT}" \
  --account "${OP_ACCOUNT}" \
  "credential[password]=${SA_TOKEN}"
success "Token stored in 1Password."

# ── Step 4: Update OP_SERVICE_ACCOUNT_TOKEN GitHub secret ────────────────────
info "Updating OP_SERVICE_ACCOUNT_TOKEN secret on ${SOURCE_REPO} ..."
gh secret set OP_SERVICE_ACCOUNT_TOKEN \
  --repo "${SOURCE_REPO}" \
  --body "${SA_TOKEN}"
success "OP_SERVICE_ACCOUNT_TOKEN updated."

echo ""
success "CI service account rotation complete."
info "GitHub Actions workflows will use the new token on the next run."
