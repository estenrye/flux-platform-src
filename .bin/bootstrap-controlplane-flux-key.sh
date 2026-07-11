#!/usr/bin/env bash
# Bootstrap Flux credentials on the controlplane cluster (M1 design step 9/10).
# The crossplane cluster generates its Flux SSH key in-cluster via ESO; the
# controlplane cluster has no ESO in M1, so this script fills the same
# contract out-of-band:
#   1. Generates (or reuses) an ed25519 keypair for Flux -> rendered repo.
#   2. Applies flux-ssh-key-secret and the sops-age secret to flux-system.
#   3. Registers the public half as a read-only deploy key on the rendered
#      repo (same title convention as bootstrap-cluster-deploy-key.sh).
#
# Requires: the rendered repo exists (human step: create
# estenrye/flux-platform-rendered-controlplane, or the renamed slug in
# clusters/controlplane/catalog.yaml), gh authenticated, kubeconfig fetched by
# create-controlplane-cluster.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PATH="${REPO_ROOT}/.venv/bin:${PATH}"
source "${SCRIPT_DIR}/lib/prompt-color.sh"

CLUSTER_DIR="${REPO_ROOT}/clusters/controlplane"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/homelab/controlplane.yaml}"
AGE_KEY_FILE="${CLUSTER_DIR}/.sops.age-key"
KEY_DIR="${KEY_DIR:-${HOME}/.ssh}"
KEY_FILE="${KEY_DIR}/flux-controlplane-ed25519"

PROJECT_SLUG=$(yq -r '.metadata.annotations["github.com/project-slug"]' "${CLUSTER_DIR}/catalog.yaml")
[ -f "${KUBECONFIG_PATH}" ] || { error "kubeconfig not found: ${KUBECONFIG_PATH} — run create-controlplane-cluster.sh first"; exit 1; }
[ -f "${AGE_KEY_FILE}" ] || { error "age key not found: ${AGE_KEY_FILE} — restore it from 1Password (vault controlplane, item sops-age-key)"; exit 1; }

# ── 1. Keypair ────────────────────────────────────────────────────────────────
if [ ! -f "${KEY_FILE}" ]; then
  info "Generating Flux deploy keypair ..."
  ssh-keygen -t ed25519 -N "" -C "flux@controlplane" -f "${KEY_FILE}"
fi

# ── 2. Secrets ────────────────────────────────────────────────────────────────
kubectl create namespace flux-system --kubeconfig="${KUBECONFIG_PATH}" \
  --dry-run=client -o yaml | kubectl apply --server-side -f - --kubeconfig="${KUBECONFIG_PATH}"

kubectl create secret generic flux-ssh-key-secret \
  --namespace=flux-system \
  --from-file=identity="${KEY_FILE}" \
  --from-file=identity.pub="${KEY_FILE}.pub" \
  --from-literal=known_hosts="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" \
  --dry-run=client -o yaml \
  | kubectl apply --server-side --force-conflicts -f - --kubeconfig="${KUBECONFIG_PATH}"
success "flux-ssh-key-secret applied."

kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey="${AGE_KEY_FILE}" \
  --dry-run=client -o yaml \
  | kubectl apply --server-side --force-conflicts -f - --kubeconfig="${KUBECONFIG_PATH}"
success "sops-age secret applied."

# ── 3. Deploy key ─────────────────────────────────────────────────────────────
KEY_TITLE="flux@controlplane"
EXISTING_KEY_ID=$(gh api "repos/${PROJECT_SLUG}/keys" \
  --jq ".[] | select(.title == \"${KEY_TITLE}\") | .id" 2>/dev/null || true)
if [ -n "${EXISTING_KEY_ID}" ]; then
  info "Deploy key '${KEY_TITLE}' already exists on ${PROJECT_SLUG} (id: ${EXISTING_KEY_ID}) — skipping."
else
  gh api "repos/${PROJECT_SLUG}/keys" --method POST \
    -f title="${KEY_TITLE}" \
    -f key="$(cat "${KEY_FILE}.pub")" \
    -F read_only=true >/dev/null
  success "Read-only deploy key '${KEY_TITLE}' added to ${PROJECT_SLUG}."
fi

echo
success "Flux credentials bootstrapped."
info "Next: make deploy-cluster CLUSTER=controlplane   # installs flux + baseline, then flux reconciles from the rendered repo"
