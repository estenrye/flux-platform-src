#!/usr/bin/env bash
# M4 completion step B6: enable OpenBao's cert auth backend (fleet-wide,
# idempotent, one-time) and register a named-certificate role for one
# remote cluster's ESO client identity. Parameterized by CLUSTER_NAME/
# TRUST_DOMAIN so this same script covers observability today and any
# future workload cluster (M6+ cloud substrates) without rewriting --
# see docs/superpowers/specs/2026-08-16-openbao-cross-cluster-auth-design.md.
#
# This is the controlplane-side half. Each remote cluster ALSO needs its
# own ESO client Certificate + Bundle (applications/external-secrets-
# operator/<cluster>/) before its ExternalSecrets can actually authenticate
# -- that's GitOps-managed, not this script's job.
#
# Requires the OpenBao root token -- see
# .bin/configure-openbao-crossplane-secrets.sh's header for why this never
# touches a committed file or a rendered manifest.
#
# Idempotent: safe to re-run (auth enable is a no-op if already enabled;
# policy/cert-role writes overwrite cleanly).
#
# Requires: op (authenticated, controlplane vault), kubectl (KUBECONFIG for
# controlplane). Run AFTER applications/openbao's B6 changes (the new 8443
# listener + chain-bundle ConfigMap mount) are live -- this script reads
# the chain bundle from inside the running pod, it doesn't need its own
# copy.
#
# Usage:
#   CLUSTER_NAME=observability TRUST_DOMAIN=obs.rye.ninja \
#     .bin/configure-openbao-cert-auth.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/prompt-color.sh"

: "${CLUSTER_NAME:?Set CLUSTER_NAME, e.g. observability}"
: "${TRUST_DOMAIN:?Set TRUST_DOMAIN, e.g. obs.rye.ninja (ADR-16 value for this cluster)}"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/homelab/controlplane.yaml}"
export KUBECONFIG="${KUBECONFIG_PATH}"
OP_VAULT="controlplane"
NAMESPACE="openbao"
POD="openbao-0"
CONTAINER="openbao"

KV_MOUNT="secret"
POLICY_NAME="remote-${CLUSTER_NAME}-secrets-read"
CERT_ROLE_NAME="remote-${CLUSTER_NAME}-eso"
# ESO's ServiceAccount identity on the remote cluster, matching the SPIFFE
# URI SAN convention already established (ADR-16's trustDomain formula,
# same URI shape the CSI driver mints for every workload).
ALLOWED_URI_SAN="spiffe://${TRUST_DOMAIN}/ns/external-secrets-operator/sa/external-secrets"

info "Reading credentials from 1Password (vault: ${OP_VAULT}) ..."
ROOT_TOKEN=$(op read "op://${OP_VAULT}/openbao-root-token/password")
success "Credentials read."

info "Configuring OpenBao cert auth for ${CLUSTER_NAME} (${ALLOWED_URI_SAN}) ..."
cat <<SCRIPT | kubectl exec -i -n "${NAMESPACE}" "${POD}" -c "${CONTAINER}" -- sh
set -eu
export BAO_ADDR="https://openbao.openbao.svc:8200"
export BAO_CACERT=/openbao/tls/ca.crt
export BAO_TOKEN="${ROOT_TOKEN}"

# Sanity check the token before touching anything.
bao token lookup >/dev/null

# ── Backend: enable once, fleet-wide. Checks current state directly
# rather than parsing enable's error text -- a prior cluster's run may
# already have done this. ──
if bao auth list | grep -q '^cert/'; then
  echo "auth/cert already enabled."
else
  bao auth enable cert
  echo "auth/cert enabled."
fi

# ── Policy: read-only on secret/{data,metadata}/remote/${CLUSTER_NAME}/* ──
# Reserved, empty KV namespace for now -- nothing writes here yet (B6 is
# built ahead of a concrete consumer, see the design doc). Narrow from day
# one rather than widening later.
bao policy write ${POLICY_NAME} - <<POLICY
path "${KV_MOUNT}/data/remote/${CLUSTER_NAME}/*" {
  capabilities = ["read"]
}
path "${KV_MOUNT}/metadata/remote/${CLUSTER_NAME}/*" {
  capabilities = ["read", "list"]
}
POLICY
echo "Policy '${POLICY_NAME}' written."

# ── Named certificate role: matches ONLY this cluster's ESO SPIFFE ID.
# certificate= is the CA bundle the 8443 listener already enforces at the
# transport level (tls_client_ca_file) -- set here too for the auth
# backend's own independent check, not solely relying on the listener.
# UNVERIFIED against this OpenBao version's real behavior (flagged in the
# design doc) -- confirm allowed_uri_sans glob matching works as expected
# on first real login attempt, don't assume upstream Vault docs apply
# verbatim to this fork/version. ──
bao write auth/cert/certs/${CERT_ROLE_NAME} \
  display_name="${CERT_ROLE_NAME}" \
  policies=${POLICY_NAME} \
  certificate=@/openbao/client-ca/chain.crt \
  allowed_uri_sans="${ALLOWED_URI_SAN}" \
  ttl=15m
echo "Cert role '${CERT_ROLE_NAME}' written."
SCRIPT

success "OpenBao cert auth configured for ${CLUSTER_NAME}."
echo ""
info "Next: this cluster's own ESO client Certificate + Bundle +"
info "ClusterSecretStore (GitOps, see the design doc's remote-cluster"
info "steps) before any ExternalSecret against this path will resolve."
info "Verify with: kubectl exec -n openbao openbao-0 -- bao list auth/cert/certs"
