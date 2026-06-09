#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_INTERVAL=15
TIMEOUT_SECONDS=600  # 10 minutes

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"

# ── Step 1: Wait for flux-ssh-key-secret ──────────────────────────────────────
info "Waiting for flux-ssh-key-secret in flux-system namespace ..."
info "(Timeout: $((TIMEOUT_SECONDS / 60)) minutes, polling every ${POLL_INTERVAL}s)"

elapsed=0
while true; do
  if kubectl get secret flux-ssh-key-secret \
      -n flux-system \
      --kubeconfig="${KUBECONFIG}" >/dev/null 2>&1; then
    success "flux-ssh-key-secret found."
    break
  fi

  if [ "${elapsed}" -ge "${TIMEOUT_SECONDS}" ]; then
    error "Timed out after ${elapsed}s waiting for flux-ssh-key-secret."
    error "Ensure Flux and ESO are running on the cluster and the SSHKey generator has reconciled."
    exit 1
  fi

  info "  Not ready. Elapsed: ${elapsed}s / ${TIMEOUT_SECONDS}s. Retrying in ${POLL_INTERVAL}s ..."
  sleep "${POLL_INTERVAL}"
  elapsed=$(( elapsed + POLL_INTERVAL ))
done

# ── Step 2: Read SSH public key ────────────────────────────────────────────────
info "Reading SSH public key from flux-ssh-key-secret ..."
SSH_PUBLIC_KEY=$(kubectl get secret flux-ssh-key-secret \
  -n flux-system \
  --kubeconfig="${KUBECONFIG}" \
  -o jsonpath='{.data.identity\.pub}' | base64 -d)

[ -n "${SSH_PUBLIC_KEY}" ] || { error "identity.pub is empty in flux-ssh-key-secret"; exit 1; }
success "SSH public key read."

# ── Step 3: Add read-only deploy key ──────────────────────────────────────────
KEY_TITLE="flux@${CLUSTER_NAME}"
info "Checking for existing deploy key '${KEY_TITLE}' on ${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME} ..."

EXISTING_KEY_ID=$(gh api "repos/${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME}/keys" \
  --jq ".[] | select(.title == \"${KEY_TITLE}\") | .id" 2>/dev/null || true)

if [ -n "${EXISTING_KEY_ID}" ]; then
  info "Deploy key '${KEY_TITLE}' already exists (id: ${EXISTING_KEY_ID}) — skipping."
else
  info "Adding read-only deploy key '${KEY_TITLE}' ..."
  RESPONSE=$(gh api "repos/${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME}/keys" \
    --method POST \
    -f title="${KEY_TITLE}" \
    -f key="${SSH_PUBLIC_KEY}" \
    -F read_only=true)

  DEPLOY_KEY_ID=$(echo "${RESPONSE}" | jq -r '.id')
  success "Deploy key added (id: ${DEPLOY_KEY_ID})."
fi

echo ""
success "Phase 2 bootstrap complete for ${CLUSTER_NAME}."
info "Rendered repo: https://github.com/${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME}"
echo ""
info "Flux can now sync from the rendered repository."
info "    export KUBECONFIG=${KUBECONFIG}"
info "    flux reconcile source git flux-platform-rendered"
echo ""
info "To see reconciliation status:"
info "    export KUBECONFIG=${KUBECONFIG}"
info "    flux get kustomization flux-platform"
