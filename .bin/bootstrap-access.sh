#!/bin/bash
set -euo pipefail

VAULT_NAME=${VAULT_NAME:-flux-platform-src}
OP_ACCOUNT=${OP_ACCOUNT:-ryefamily.1password.com}
VAULT_USERS=${VAULT_USERS:?VAULT_USERS is required. Set it to a space-separated list of 1Password user emails.}

echo "=== Access Bootstrap for flux-platform-src ==="
echo ""

# ── Step 1: Create 1Password vault ──────────────────────────────────────────
echo "Step 1: Creating 1Password vault '${VAULT_NAME}' ..."

VAULT_ID=$(op vault get "${VAULT_NAME}" --account "${OP_ACCOUNT}" --format json 2>/dev/null \
  | jq -r '.id' || true)

if [ -n "${VAULT_ID}" ]; then
  echo "  Already exists (id: ${VAULT_ID}) — skipping."
else
  VAULT_ID=$(op vault create "${VAULT_NAME}" \
    --description "Secrets for flux-platform-src CI/CD pipeline" \
    --account "${OP_ACCOUNT}" \
    --format json | jq -r '.id')
  echo "  Created (id: ${VAULT_ID})"
fi

# ── Step 2: Grant Manager access to each user ───────────────────────────────
echo ""
echo "Step 2: Granting Manager access to vault '${VAULT_NAME}' ..."

# shellcheck disable=SC2086
for USER in ${VAULT_USERS}; do
  op vault user grant \
    --vault "${VAULT_NAME}" \
    --user "${USER}" \
    --account "${OP_ACCOUNT}" \
    --no-input \
    --permissions "allow_viewing,allow_editing,allow_managing"
  echo "  ✓ ${USER}"
done

echo ""
echo "Bootstrap complete."
echo ""
echo "  1Password vault: ${VAULT_NAME} (id: ${VAULT_ID})"
echo "  Manager access granted to:"
# shellcheck disable=SC2086
for USER in ${VAULT_USERS}; do
  echo "    ${USER}"
done
echo ""
echo "Next steps:"
echo "  make bootstrap-github-app"
echo "  make bootstrap-cluster CLUSTER=<cluster-dir-name>"
