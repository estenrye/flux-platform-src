#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP_ACCOUNT="ryefamily.1password.com"

# Flags — also accept FULL and SKIP_K8S from environment (Makefile passthrough)
FULL="${FULL:-}"
SKIP_K8S="${SKIP_K8S:-}"

for arg in "$@"; do
  case "${arg}" in
    --full)     FULL=1 ;;
    --skip-k8s) SKIP_K8S=1 ;;
    *) echo "Unknown argument: ${arg}" >&2; exit 1 ;;
  esac
done

source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"

# KUBECONFIG is only required when the Kubernetes step is not skipped
if [ -z "${SKIP_K8S}" ]; then
  source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"
fi

# ── Step 2: Delete GitHub deploy key ──────────────────────────────────────────
KEY_TITLE="flux@${CLUSTER_NAME}"
info "Checking for deploy key '${KEY_TITLE}' on ${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME} ..."

KEY_ID=$(gh api "repos/${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME}/keys" \
  --jq ".[] | select(.title == \"${KEY_TITLE}\") | .id" 2>/dev/null || true)

if [ -n "${KEY_ID}" ]; then
  gh api "repos/${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME}/keys/${KEY_ID}" --method DELETE
  success "Deploy key '${KEY_TITLE}' deleted (id: ${KEY_ID})."
else
  info "Deploy key '${KEY_TITLE}' not found — skipping."
fi

# ── Step 3: Delete sops-age Kubernetes secret ─────────────────────────────────
if [ -n "${SKIP_K8S}" ]; then
  warn "Skipping Kubernetes secret deletion (SKIP_K8S is set)."
else
  info "Deleting sops-age Kubernetes secret ..."
  if kubectl delete secret sops-age \
      -n flux-system \
      --kubeconfig="${KUBECONFIG}" 2>/dev/null; then
    success "sops-age secret deleted."
  else
    warn "Could not delete sops-age secret (cluster unreachable or secret not found) — continuing."
  fi
fi

# ── Step 4: Delete local files ────────────────────────────────────────────────
info "Removing local SOPS files ..."
for f in "${CLUSTER_PATH}/.sops.yaml" "${CLUSTER_PATH}/.sops.age-key"; do
  if [ -f "${f}" ]; then
    rm -f "${f}"
    success "Deleted: $(basename "${f}")"
  else
    info "$(basename "${f}") not found — skipping."
  fi
done

# ── Step 5: Delete 1Password vault ────────────────────────────────────────────
info "Checking for 1Password vault '${CLUSTER_NAME}' ..."
if op vault get "${CLUSTER_NAME}" --account "${OP_ACCOUNT}" >/dev/null 2>&1; then
  op vault delete "${CLUSTER_NAME}" --account "${OP_ACCOUNT}"
  success "1Password vault '${CLUSTER_NAME}' deleted (includes service-account-token and sops-age-key)."
else
  info "1Password vault '${CLUSTER_NAME}' not found — skipping."
fi

echo ""
warn "Action required: the 1Password service account '${CLUSTER_NAME}' must be deleted manually."
warn "  1. Sign in to https://ryefamily.1password.com"
warn "  2. Go to Settings → Service Accounts"
warn "  3. Find '${CLUSTER_NAME}' and delete it"
echo ""

# ── Step 6: Remove cluster directory from git (re-bootstrap) ─────────────────
# In --full mode this runs AFTER the rendered repo is deleted (Step 8),
# so that a failed repo deletion doesn't leave the cluster directory gone.
_remove_cluster_dir() {
  info "Removing cluster directory from git ..."
  TRACKED=$(git -C "${REPO_ROOT}" ls-files "${CLUSTER_DIR}/" | head -1)
  if [ -n "${TRACKED}" ]; then
    git -C "${REPO_ROOT}" rm -r "${CLUSTER_DIR}/"
    git -C "${REPO_ROOT}" commit \
      -m "chore: remove cluster ${CLUSTER_NAME} — teardown"
    success "Cluster directory removed and committed."
  elif [ -d "${CLUSTER_PATH}" ]; then
    rm -rf "${CLUSTER_PATH}"
    info "Cluster directory removed (was not tracked in git)."
  else
    info "Cluster directory '${CLUSTER_DIR}' not found — skipping."
  fi
}

if [ -z "${FULL}" ]; then
  _remove_cluster_dir
  echo ""
  success "Re-bootstrap teardown complete for ${CLUSTER_NAME}."
  info "You can now re-run: make bootstrap-cluster CLUSTER=${CLUSTER}"
  exit 0
fi

# ── Step 7 (--full): Delete GitHub Environment ────────────────────────────────
info "Deleting GitHub Environment '${CLUSTER_NAME}' from estenrye/flux-platform-src ..."
if gh api "repos/estenrye/flux-platform-src/environments/${CLUSTER_NAME}" >/dev/null 2>&1; then
  gh api "repos/estenrye/flux-platform-src/environments/${CLUSTER_NAME}" --method DELETE
  success "GitHub Environment '${CLUSTER_NAME}' deleted."
else
  info "GitHub Environment '${CLUSTER_NAME}' not found — skipping."
fi

# ── Step 8 (--full): Delete rendered GitHub repository ────────────────────────
# Requires the 'delete_repo' OAuth scope. If missing, refresh with:
#   gh auth refresh -h github.com -s delete_repo
FULL_REPO="${RENDERED_REPO_OWNER}/${RENDERED_REPO_NAME}"
echo ""
warn "WARNING: This will permanently delete:"
warn "  https://github.com/${FULL_REPO}"
echo ""
read -rp "Type the repository name to confirm (${FULL_REPO}): " CONFIRM

if [ "${CONFIRM}" != "${FULL_REPO}" ]; then
  error "Confirmation did not match '${FULL_REPO}'. Repository NOT deleted."
  exit 1
fi

if gh api "repos/${FULL_REPO}" >/dev/null 2>&1; then
  if ! gh repo delete "${FULL_REPO}" --yes 2>/tmp/gh-delete-err; then
    if grep -q "403\|Forbidden\|Must have admin rights" /tmp/gh-delete-err 2>/dev/null; then
      error "Repository deletion failed (403 Forbidden)."
      error "The 'delete_repo' OAuth scope is required. Run:"
      error "  gh auth refresh -h github.com -s delete_repo"
      error "Then re-run teardown."
    else
      cat /tmp/gh-delete-err >&2
    fi
    exit 1
  fi
  success "Repository ${FULL_REPO} deleted."
else
  info "Repository ${FULL_REPO} not found — skipping."
fi

# ── Step 9 (--full): Remove cluster directory from git ────────────────────────
# Runs last so a failed repo deletion doesn't orphan the cluster directory.
_remove_cluster_dir

echo ""
success "Full decommission complete for ${CLUSTER_NAME}."
