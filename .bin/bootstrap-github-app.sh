#!/bin/bash
set -euo pipefail
ORG=${ORG:-estenrye}
OP_ACCOUNT=${OP_ACCOUNT:-ryefamily.1password.com}
VAULT=${VAULT:-flux-platform-src}
ITEM_NAME=${ITEM_NAME:-render-flux-platform-src-app}

echo "=== GitHub App Bootstrap for flux-platform-src ==="
echo ""
echo "This is a one-time setup. It cannot be fully automated because GitHub"
echo "requires the web UI to create a GitHub App."
echo ""

# ── Step 1: Create the app ──────────────────────────────────────────────────
echo "Step 1: Create the GitHub App"
echo ""
echo "Open this URL in your browser if you are using a personal account:"
echo "  https://github.com/settings/apps/new"
echo ""
echo "Open this URL if you are using an org account:"
echo "  https://github.com/organizations/${ORG}/settings/apps/new"
echo ""
echo "Fill in the form with exactly these values:"
echo ""
echo "  GitHub App name:  render-flux-platform-src-app"
echo "  Description:      Renders Flux manifests from flux-platform-src to per-cluster rendered repos"
echo "  Homepage URL:     https://github.com/${ORG}/flux-platform-src"
echo ""
echo "  Webhook: Uncheck 'Active' (no webhook needed)"
echo ""
echo "  Repository permissions:"
echo "    Contents:      Read and write"
echo "    Metadata:      Read-only (mandatory, pre-selected)"
echo "    Pull requests: Read and write"
echo ""
echo "  Where can this app be installed?"
echo "    Select: Only on this account"
echo ""
echo "Click 'Create GitHub App'."
echo ""
read -rp "Press Enter when the app has been created..."

# ── Step 2: Collect App ID ──────────────────────────────────────────────────
echo ""
echo "Step 2: Collect credentials"
echo ""
echo "Navigate to the app settings page:"
echo ""
echo "Open this URL in your browser if you are using a personal account:"
echo "  https://github.com/settings/apps/new"
echo ""
echo "Open this URL if you are using an org account:"
echo "  https://github.com/organizations/${ORG}/settings/apps/new"
echo ""
echo "On the app settings page, click on 'render-flux-platform-src-app'."
echo "The App ID is shown near the top."
echo ""
read -rp "Enter the App ID: " APP_ID
[[ "${APP_ID}" =~ ^[0-9]+$ ]] || { echo "Error: App ID must be a number"; exit 1; }

# ── Step 3: Generate and collect private key ────────────────────────────────
echo ""
echo "Step 3: Generate a private key"
echo ""
echo "On the same app settings page, scroll to 'Private keys' and click"
echo "'Generate a private key'. A .pem file will be downloaded."
echo ""
read -rp "Enter the full path to the downloaded .pem file: " KEY_PATH
[ -f "${KEY_PATH}" ] || { echo "Error: file not found: ${KEY_PATH}"; exit 1; }

# ── Step 4: Store in 1Password ──────────────────────────────────────────────
echo ""
echo "Step 4: Storing credentials in 1Password (vault: ${VAULT}, item: ${ITEM_NAME})..."

EXISTING_ID=$(op item get --account "${OP_ACCOUNT}" "${ITEM_NAME}" --vault "${VAULT}" --format json 2>/dev/null \
  | jq -r '.id' 2>/dev/null || true)

if [ -n "${EXISTING_ID}" ]; then
  echo "Updating existing item..."
  op item edit "${ITEM_NAME}" \
    --account "${OP_ACCOUNT}" \
    --vault "${VAULT}" \
    "app-id[text]=${APP_ID}" \
    "private-key[concealed]=$(cat "${KEY_PATH}")"
else
  echo "Creating new item..."
  op item create \
    --account "${OP_ACCOUNT}" \
    --category "API Credential" \
    --title "${ITEM_NAME}" \
    --vault "${VAULT}" \
    "app-id[text]=${APP_ID}" \
    "private-key[concealed]=$(cat "${KEY_PATH}")"
fi

echo "Credentials stored."

# ── Step 5: Install the app on the org ─────────────────────────────────────
echo ""
echo "Step 5: Install the app on the ${ORG} org"
echo ""
echo "On the app settings page, click 'Install App' in the left sidebar."
echo "Click 'Install' next to '${ORG}'."
echo "Select 'Only select repositories', then select 'flux-platform-src' as a"
echo "placeholder (GitHub requires at least one repo to proceed)."
echo "Click 'Install'."
echo ""
echo "Rendered repos are added individually by 'make bootstrap-cluster-rendered-repo'."
echo ""
read -rp "Press Enter when the app has been installed on the ${ORG} org..."

# ── Step 6: Verify ─────────────────────────────────────────────────────────
echo ""
echo "Step 6: Verifying installation..."

INSTALL_ID=$(gh api "/orgs/${ORG}/installations" \
  --jq ".installations[] | select(.app_id == (${APP_ID}|tonumber)) | .id" 2>/dev/null || true)

if [ -n "${INSTALL_ID}" ]; then
  echo "Persisting installation ID to 1Password ..."
  op item edit "${ITEM_NAME}" \
    --account "${OP_ACCOUNT}" \
    --vault "${VAULT}" \
    "installation-id[text]=${INSTALL_ID}"
  echo ""
  echo "✓ GitHub App installed on ${ORG} (installation ID: ${INSTALL_ID})"
  echo "✓ Credentials stored in 1Password (app-id, private-key, installation-id)"
  echo ""
  echo "Bootstrap complete. You can now run:"
  echo "  make bootstrap-cluster CLUSTER=<cluster-dir-name>"
else
  echo ""
  echo "Warning: could not find app ID ${APP_ID} in ${ORG} installations."
  echo "Verify at: https://github.com/organizations/${ORG}/settings/installations"
  echo ""
  echo "Once confirmed, manually store the installation ID:"
  echo "  op item edit ${ITEM_NAME} --account ${OP_ACCOUNT} --vault ${VAULT} 'installation-id[text]=<id>'"
  echo "Then 'make bootstrap-cluster-rendered-repo' will work without org Owner rights."
fi
