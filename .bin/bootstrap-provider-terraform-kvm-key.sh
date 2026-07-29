#!/usr/bin/env bash
# M4 step 1: mint a dedicated SSH keypair for provider-terraform's libvirt
# access to the KVM host fleet, authorize it on the host(s), and store the
# private key in OpenBao so ESO can serve it to the
# provider-terraform-kvm-ssh-key Secret (see applications/crossplane-providers/
# provider-terraform/provider-config/provider-config.yaml).
#
# This is deliberately a NEW, dedicated credential -- not the human
# operator's own key used interactively via ssh-agent for `tofu`/`talosctl`
# runs today (providers/kvm/README.md). provider-terraform's pod has no
# ssh-agent and needs a private key it can read from a file.
#
# Requires real network access to every host in providers/kvm/hosts.yaml
# (this repo's dev/CI sandbox does not have this -- run from a workstation
# on the home lab network), plus: ssh-keygen, ssh, op (authenticated,
# controlplane vault), kubectl (KUBECONFIG for controlplane).
#
# Idempotent: re-running regenerates nothing if a key already exists at
# KEY_PATH; re-appends to authorized_keys only if the exact public key line
# is missing; re-running the OpenBao section overwrites the stored value
# (safe -- it's the same key).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/prompt-color.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KEY_COMMENT="provider-terraform@controlplane"
KEY_DIR="${HOME}/.ssh"
KEY_PATH="${KEY_DIR}/provider-terraform-kvm-key"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/homelab/controlplane.yaml}"
export KUBECONFIG="${KUBECONFIG_PATH}"
OP_VAULT="controlplane"
NAMESPACE="openbao"
POD="openbao-0"
CONTAINER="openbao"

KV_MOUNT="secret"
POLICY_NAME="provider-terraform-secrets-read"
ROLE_NAME="eso-provider-terraform"
ESO_SA_NAME="external-secrets"
ESO_SA_NAMESPACE="external-secrets-operator"

if [ ! -f "${KEY_PATH}" ]; then
  info "Generating a new ed25519 keypair at ${KEY_PATH} ..."
  ssh-keygen -t ed25519 -N "" -C "${KEY_COMMENT}" -f "${KEY_PATH}"
  success "Keypair generated."
else
  info "Reusing existing keypair at ${KEY_PATH}."
fi

info "Authorizing the public key on each host in providers/kvm/hosts.yaml ..."
PUB_KEY="$(cat "${KEY_PATH}.pub")"
while IFS= read -r host_fqdn; do
  info "  ${host_fqdn} ..."
  ssh "automation-user@${host_fqdn}" "grep -qF '${PUB_KEY}' ~/.ssh/authorized_keys 2>/dev/null || echo '${PUB_KEY}' >> ~/.ssh/authorized_keys"
done < <(yq -r '.hosts[].fqdn' "${REPO_ROOT}/providers/kvm/hosts.yaml")
success "Public key authorized."

info "Reading OpenBao root token from 1Password (vault: ${OP_VAULT}) ..."
ROOT_TOKEN=$(op read "op://${OP_VAULT}/openbao-root-token/password")
success "Root token read."

info "Configuring OpenBao (policy, role, kv data for provider-terraform) ..."
cat <<SCRIPT | kubectl exec -i -n "${NAMESPACE}" "${POD}" -c "${CONTAINER}" -- sh
set -eu
export BAO_ADDR="https://openbao.openbao.svc:8200"
export BAO_CACERT=/openbao/tls/ca.crt
export BAO_TOKEN="${ROOT_TOKEN}"

bao token lookup >/dev/null

# ── Policy: read-only on secret/{data,metadata}/provider-terraform/* ───
bao policy write ${POLICY_NAME} - <<'POLICY'
path "${KV_MOUNT}/data/provider-terraform/*" {
  capabilities = ["read"]
}
path "${KV_MOUNT}/metadata/provider-terraform/*" {
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
SCRIPT

# Private key piped straight from disk to bao kv put -- never lands in a
# shell history entry or an intermediate variable holding the raw PEM.
kubectl exec -i -n "${NAMESPACE}" "${POD}" -c "${CONTAINER}" -- sh -c \
  "BAO_ADDR=https://openbao.openbao.svc:8200 BAO_CACERT=/openbao/tls/ca.crt BAO_TOKEN=${ROOT_TOKEN} \
   bao kv put -mount=${KV_MOUNT} provider-terraform/kvm-ssh-key id_ed25519=-" \
  < "${KEY_PATH}"
echo "provider-terraform/kvm-ssh-key written."

success "OpenBao configured for the provider-terraform ExternalSecret."
echo ""
info "Next: apply the ClusterSecretStore + ExternalSecret + provider-terraform"
info "install (GitOps-managed, M4 step 1 PR), then verify with:"
info "  kubectl get clustersecretstore openbao-provider-terraform"
info "  kubectl -n crossplane-system get externalsecret provider-terraform-kvm-ssh-key"
info "  kubectl -n crossplane-system get secret provider-terraform-kvm-ssh-key"
