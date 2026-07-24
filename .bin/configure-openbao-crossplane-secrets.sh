#!/usr/bin/env bash
# M3 step 6: configure OpenBao so ESO can serve the two Crossplane provider
# secrets (github-token, cloudflare-creds) from it instead of 1Password.
#
# Scope, per docs/memory/m3-step6-secret-migration-eligibility.md: these two
# secrets were confirmed to sit downstream of OpenBao's own dependency chain
# (Crossplane's only live managed resources are DNS delegation + Roles
# Anywhere IAM plumbing -- nothing OpenBao needs), so migrating them creates
# no circular bootstrap. Do not extend this script to any secret that
# OpenBao itself (or something on its boot path -- democratic-csi/TrueNAS,
# Garage, CNPG, cert-manager) depends on; re-run that analysis first.
#
# Requires the OpenBao root token, which by design (see
# docs/runbooks/openbao-unseal.md "Post-ceremony hygiene") never touches a
# committed file or a rendered manifest. This script reads it from 1Password
# (op://controlplane/openbao-root-token/password) and passes it to the
# openbao-0 pod purely over kubectl exec's stdin -- never as a CLI arg on
# this machine, never written to local disk.
#
# Idempotent: safe to re-run. Skips the KV mount / auth method enable if
# already present; KV writes and policy/role writes are upserts.
#
# Requires: op (authenticated, controlplane vault), kubectl (KUBECONFIG for
# controlplane), the github-auth-app and cloudflare-api-token items already
# in the controlplane 1Password vault (same items the existing 1Password-SDK
# ExternalSecrets already read).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/prompt-color.sh"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/homelab/controlplane.yaml}"
export KUBECONFIG="${KUBECONFIG_PATH}"
OP_VAULT="controlplane"
NAMESPACE="openbao"
POD="openbao-0"
CONTAINER="openbao"

KV_MOUNT="secret"
POLICY_NAME="crossplane-secrets-read"
ROLE_NAME="eso-crossplane"
ESO_SA_NAME="external-secrets"
ESO_SA_NAMESPACE="external-secrets-operator"

info "Reading credentials from 1Password (vault: ${OP_VAULT}) ..."
ROOT_TOKEN=$(op read "op://${OP_VAULT}/openbao-root-token/password")
GH_APP_ID=$(op read "op://${OP_VAULT}/github-auth-app/app_id")
GH_INSTALLATION_ID=$(op read "op://${OP_VAULT}/github-auth-app/installation_id")
GH_OWNER=$(op read "op://${OP_VAULT}/github-auth-app/owner")
GH_PRIVATE_KEY=$(op read "op://${OP_VAULT}/github-auth-app/private-key")
CF_API_TOKEN=$(op read "op://${OP_VAULT}/cloudflare-api-token/credential")
success "Credentials read."

info "Configuring OpenBao (kv-v2 mount, kubernetes auth, policy, role, kv data) ..."
cat <<SCRIPT | kubectl exec -i -n "${NAMESPACE}" "${POD}" -c "${CONTAINER}" -- sh
set -eu
export BAO_ADDR="https://openbao.openbao.svc:8200"
export BAO_CACERT=/openbao/tls/ca.crt
export BAO_TOKEN="${ROOT_TOKEN}"

# Sanity check the token before touching anything.
bao token lookup >/dev/null

# ── KV v2 mount ──────────────────────────────────────────────────────────
if bao secrets list -format=json | grep -q '"${KV_MOUNT}/"'; then
  echo "kv-v2 mount '${KV_MOUNT}/' already present -- skipping enable."
else
  bao secrets enable -path=${KV_MOUNT} -version=2 kv
  echo "kv-v2 mount '${KV_MOUNT}/' enabled."
fi

# ── Kubernetes auth method ──────────────────────────────────────────────
if bao auth list -format=json | grep -q '"kubernetes/"'; then
  echo "kubernetes auth method already enabled -- skipping enable."
else
  bao auth enable kubernetes
  echo "kubernetes auth method enabled."
fi

# In-cluster defaults (kubernetes_ca_cert / token_reviewer_jwt) are picked up
# from this pod's own mounted ServiceAccount, which already carries the
# system:auth-delegator binding the openbao-helm chart ships by default.
bao write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"
echo "kubernetes auth method configured."

# ── Policy: read-only on secret/{data,metadata}/crossplane/* ───────────
bao policy write ${POLICY_NAME} - <<'POLICY'
path "${KV_MOUNT}/data/crossplane/*" {
  capabilities = ["read"]
}
path "${KV_MOUNT}/metadata/crossplane/*" {
  capabilities = ["read", "list"]
}
POLICY
echo "Policy '${POLICY_NAME}' written."

# ── Role: binds the ESO ServiceAccount to the policy above ─────────────
bao write auth/kubernetes/role/${ROLE_NAME} \
  bound_service_account_names=${ESO_SA_NAME} \
  bound_service_account_namespaces=${ESO_SA_NAMESPACE} \
  policies=${POLICY_NAME} \
  ttl=15m
echo "Role '${ROLE_NAME}' written."

# ── Secret data ──────────────────────────────────────────────────────────
bao kv put -mount=${KV_MOUNT} crossplane/github-auth-app \
  app_id="${GH_APP_ID}" \
  installation_id="${GH_INSTALLATION_ID}" \
  owner="${GH_OWNER}" \
  private-key="${GH_PRIVATE_KEY}"
echo "crossplane/github-auth-app written."

bao kv put -mount=${KV_MOUNT} crossplane/cloudflare-api-token \
  api_token="${CF_API_TOKEN}"
echo "crossplane/cloudflare-api-token written."
SCRIPT

success "OpenBao configured for the crossplane-system ExternalSecret migration."
echo ""
info "Next: apply the ClusterSecretStore + NetworkPolicy + ExternalSecret changes"
info "(GitOps-managed, see the M3 step 6 PR), then verify with:"
info "  kubectl get clustersecretstore openbao"
info "  kubectl get externalsecret -n crossplane-system github-token cloudflare-creds"
