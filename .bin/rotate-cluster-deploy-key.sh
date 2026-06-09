#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_INTERVAL=15
TIMEOUT_SECONDS=600  # 10 minutes

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"

KEY_TITLE="flux@${CLUSTER_NAME}"

# ── Step 1: Record current deploy key ID ──────────────────────────────────────
info "Looking up current deploy key '${KEY_TITLE}' on ${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME} ..."
OLD_KEY_ID=$(gh api "repos/${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME}/keys" \
  --jq ".[] | select(.title == \"${KEY_TITLE}\") | .id" 2>/dev/null || true)

[ -n "${OLD_KEY_ID}" ] || { error "Deploy key '${KEY_TITLE}' not found — is this cluster bootstrapped?"; exit 1; }
success "Recorded old deploy key id: ${OLD_KEY_ID}"

# ── Step 2: Delete flux-ssh-key-secret ────────────────────────────────────────
info "Deleting flux-ssh-key-secret to trigger ESO regeneration ..."
kubectl delete secret flux-ssh-key-secret \
  -n flux-system \
  --kubeconfig="${KUBECONFIG}"
success "Secret deleted. ESO will regenerate it with a fresh key pair."

# ── Step 3: Wait for flux-ssh-key-secret to reappear ─────────────────────────
info "Waiting for ESO to recreate flux-ssh-key-secret ..."
info "(Timeout: $((TIMEOUT_SECONDS / 60)) minutes, polling every ${POLL_INTERVAL}s)"

elapsed=0
while true; do
  if kubectl get secret flux-ssh-key-secret \
      -n flux-system \
      --kubeconfig="${KUBECONFIG}" >/dev/null 2>&1; then
    success "flux-ssh-key-secret recreated."
    break
  fi

  if [ "${elapsed}" -ge "${TIMEOUT_SECONDS}" ]; then
    error "Timed out after ${elapsed}s waiting for flux-ssh-key-secret."
    error "Check ESO is running and the SSHKey generator is healthy."
    exit 1
  fi

  info "  Not ready. Elapsed: ${elapsed}s / ${TIMEOUT_SECONDS}s. Retrying in ${POLL_INTERVAL}s ..."
  sleep "${POLL_INTERVAL}"
  elapsed=$(( elapsed + POLL_INTERVAL ))
done

# ── Step 4: Read new public key ───────────────────────────────────────────────
info "Reading new SSH public key ..."
NEW_PUBLIC_KEY=$(kubectl get secret flux-ssh-key-secret \
  -n flux-system \
  --kubeconfig="${KUBECONFIG}" \
  -o jsonpath='{.data.identity\.pub}' | base64 -d)

[ -n "${NEW_PUBLIC_KEY}" ] || { error "identity.pub is empty in flux-ssh-key-secret"; exit 1; }
success "New public key read."

# ── Step 5: Add new deploy key to GitHub ─────────────────────────────────────
info "Adding new deploy key '${KEY_TITLE}' to ${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME} ..."
RESPONSE=$(gh api "repos/${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME}/keys" \
  --method POST \
  -f title="${KEY_TITLE}" \
  -f key="${NEW_PUBLIC_KEY}" \
  -F read_only=true)

NEW_KEY_ID=$(echo "${RESPONSE}" | jq -r '.id')
success "New deploy key added (id: ${NEW_KEY_ID})."

# ── Step 6: Delete old deploy key ────────────────────────────────────────────
info "Deleting old deploy key (id: ${OLD_KEY_ID}) ..."
gh api "repos/${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME}/keys/${OLD_KEY_ID}" \
  --method DELETE
success "Old deploy key deleted."

echo ""
success "Deploy key rotation complete for ${CLUSTER_NAME}."
info "Flux will resume syncing once the new key is active (typically within 1 reconcile interval)."
