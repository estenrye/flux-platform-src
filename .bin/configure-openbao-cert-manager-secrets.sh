#!/usr/bin/env bash
# M3 step 9a: configure OpenBao so ESO can serve cert-manager-acme's
# Cloudflare API token (used for the letsencrypt-* ClusterIssuers' DNS-01
# solver) from OpenBao instead of 1Password.
#
# Scope, per docs/memory/m3-step6-secret-migration-eligibility.md: the
# letsencrypt-* ClusterIssuers are entirely separate from the
# csi-driver-spiffe-ca issuer OpenBao's own Certificate uses, and nothing
# on OpenBao's boot chain depends on ACME/DNS-01 -- one-directional
# dependency (cert-manager-acme -> OpenBao), same shape as step 6's
# crossplane secrets. Uses a separate KV path / policy / role from
# step 6's crossplane-secrets-read, even though the same ESO ServiceAccount
# authenticates for both, to keep the least-privilege boundary explicit
# and auditable per-consumer (same reasoning as the dedicated Garage keys
# minted per bucket/consumer this session).
#
# Requires the OpenBao root token -- see
# .bin/configure-openbao-crossplane-secrets.sh's header for why this never
# touches a committed file or a rendered manifest.
#
# Idempotent: safe to re-run.
#
# Requires: op (authenticated, controlplane vault), kubectl (KUBECONFIG for
# controlplane), the cloudflare-api-token item already in the controlplane
# 1Password vault (same item the crossplane cloudflare-creds ExternalSecret
# already reads via a different OpenBao path).
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
POLICY_NAME="cert-manager-secrets-read"
ROLE_NAME="eso-cert-manager"
ESO_SA_NAME="external-secrets"
ESO_SA_NAMESPACE="external-secrets-operator"

info "Reading credentials from 1Password (vault: ${OP_VAULT}) ..."
ROOT_TOKEN=$(op read "op://${OP_VAULT}/openbao-root-token/password")
CF_API_TOKEN=$(op read "op://${OP_VAULT}/cloudflare-api-token/credential")
success "Credentials read."

info "Configuring OpenBao (policy, role, kv data for cert-manager) ..."
cat <<SCRIPT | kubectl exec -i -n "${NAMESPACE}" "${POD}" -c "${CONTAINER}" -- sh
set -eu
export BAO_ADDR="https://openbao.openbao.svc:8200"
export BAO_CACERT=/openbao/tls/ca.crt
export BAO_TOKEN="${ROOT_TOKEN}"

# Sanity check the token before touching anything.
bao token lookup >/dev/null

# kv-v2 mount and kubernetes auth method are already enabled (step 6) --
# this script only adds the cert-manager-scoped policy/role/data on top.

# ── Policy: read-only on secret/{data,metadata}/cert-manager/* ─────────
bao policy write ${POLICY_NAME} - <<'POLICY'
path "${KV_MOUNT}/data/cert-manager/*" {
  capabilities = ["read"]
}
path "${KV_MOUNT}/metadata/cert-manager/*" {
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
bao kv put -mount=${KV_MOUNT} cert-manager/cloudflare-api-token \
  api_token="${CF_API_TOKEN}"
echo "cert-manager/cloudflare-api-token written."
SCRIPT

success "OpenBao configured for the cert-manager-acme ExternalSecret."
echo ""
info "Next: apply the ClusterSecretStore + ExternalSecret + cert-manager-acme"
info "app changes (GitOps-managed, see the M3 step 9a PR), then verify with:"
info "  kubectl get clustersecretstore openbao-cert-manager"
info "  kubectl get externalsecret -n cert-manager cloudflare-api-token-secret"
info "  kubectl get clusterissuer letsencrypt-staging letsencrypt-prod"
