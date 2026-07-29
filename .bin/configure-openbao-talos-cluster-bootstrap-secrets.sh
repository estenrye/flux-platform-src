#!/usr/bin/env bash
# M4 step 2: configure OpenBao so the talos-cluster-bootstrap Job (M4 step 3)
# can read/write Talos machine secrets at secret/talos-clusters/<cluster>/* --
# unlike every other ESO-fronted consumer in this repo, this Job talks to
# OpenBao directly (via `bao` CLI + its own kubernetes-auth login), not
# through an ExternalSecret, since it needs to WRITE a new secret on a
# cluster's first bootstrap, not just read one ESO already knows about.
#
# Requires the OpenBao root token -- see
# .bin/configure-openbao-crossplane-secrets.sh's header for why this never
# touches a committed file or a rendered manifest.
#
# Idempotent: safe to re-run.
#
# Requires: op (authenticated, controlplane vault), kubectl (KUBECONFIG for
# controlplane).
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
POLICY_NAME="talos-cluster-bootstrap-secrets"
ROLE_NAME="talos-cluster-bootstrap"
JOB_SA_NAME="talos-cluster-bootstrap"
JOB_SA_NAMESPACE="crossplane-system"

info "Reading OpenBao root token from 1Password (vault: ${OP_VAULT}) ..."
ROOT_TOKEN=$(op read "op://${OP_VAULT}/openbao-root-token/password")
success "Root token read."

info "Configuring OpenBao (policy, role for talos-cluster-bootstrap) ..."
cat <<SCRIPT | kubectl exec -i -n "${NAMESPACE}" "${POD}" -c "${CONTAINER}" -- sh
set -eu
export BAO_ADDR="https://openbao.openbao.svc:8200"
export BAO_CACERT=/openbao/tls/ca.crt
export BAO_TOKEN="${ROOT_TOKEN}"

bao token lookup >/dev/null

# ── Policy: create/read/list on secret/{data,metadata}/talos-clusters/* ──
# (create, not just read -- the Job generates a cluster's machine secrets
# on its first bootstrap, it doesn't just consume a pre-existing value)
bao policy write ${POLICY_NAME} - <<'POLICY'
path "${KV_MOUNT}/data/talos-clusters/*" {
  capabilities = ["create", "read", "update"]
}
path "${KV_MOUNT}/metadata/talos-clusters/*" {
  capabilities = ["read", "list"]
}
POLICY
echo "Policy '${POLICY_NAME}' written."

# ── Role: binds the Job's own ServiceAccount to the policy above ───────
bao write auth/kubernetes/role/${ROLE_NAME} \
  bound_service_account_names=${JOB_SA_NAME} \
  bound_service_account_namespaces=${JOB_SA_NAMESPACE} \
  policies=${POLICY_NAME} \
  ttl=15m
echo "Role '${ROLE_NAME}' written."
SCRIPT

success "OpenBao configured for the talos-cluster-bootstrap Job."
echo ""
info "Next: apply the talos-cluster-bootstrap app (GitOps-managed, M4 step 2"
info "PR) so the ServiceAccount this role binds to actually exists, then"
info "verify with:"
info "  kubectl -n crossplane-system get serviceaccount talos-cluster-bootstrap"
