#!/bin/bash
set -euo pipefail

SOURCE_REPO=${SOURCE_REPO:-estenrye/flux-platform-src}
VAULT="flux-platform-src"
OP_ACCOUNT="ryefamily.1password.com"
SA_NAME="flux-platform-src-ci"

echo "=== CI Bootstrap for ${SOURCE_REPO} ==="
echo ""
echo "Provisions OP_SERVICE_ACCOUNT_TOKEN as a GitHub Actions secret."
echo "The 1Password service account grants the workflow read access to"
echo "the '${VAULT}' vault so it can resolve op:// references at runtime."
echo ""

# ── Step 1: Create 1Password service account ────────────────────────────────
echo "Step 1: Create 1Password service account '${SA_NAME}'"
echo ""

SA_TOKEN_STORED=$(op item get "${SA_NAME}-op-token" \
  --vault "${VAULT}" \
  --account "${OP_ACCOUNT}" \
  --field credential 2>/dev/null || true)

if [ -n "${SA_TOKEN_STORED}" ]; then
  echo "  Service account token already stored in 1Password — using existing."
  SA_TOKEN="${SA_TOKEN_STORED}"
else
  echo "  Creating service account with read access to vault '${VAULT}' ..."
  SA_TOKEN=$(op service-account create "${SA_NAME}" \
    --vault "${VAULT}":read_items \
    --account "${OP_ACCOUNT}" \
    --raw)

  op item create \
    --category "API Credential" \
    --title "${SA_NAME}-op-token" \
    --vault "${VAULT}" \
    --account "${OP_ACCOUNT}" \
    "credential[password]=${SA_TOKEN}"

  echo "  ✓ Service account created and token stored in 1Password for recovery."
fi

# ── Step 2: Set OP_SERVICE_ACCOUNT_TOKEN as a GitHub Actions secret ──────────
echo ""
echo "Step 2: Set OP_SERVICE_ACCOUNT_TOKEN secret on ${SOURCE_REPO}"
echo ""

gh secret set OP_SERVICE_ACCOUNT_TOKEN \
  --repo "${SOURCE_REPO}" \
  --body "${SA_TOKEN}"

echo "  ✓ OP_SERVICE_ACCOUNT_TOKEN set on ${SOURCE_REPO}"
echo ""
echo "Bootstrap complete."
echo ""
echo "Prerequisite: ensure op://${VAULT}/${SA_NAME}/token exists in 1Password"
echo "(a GitHub token the workflow uses for git operations)."
