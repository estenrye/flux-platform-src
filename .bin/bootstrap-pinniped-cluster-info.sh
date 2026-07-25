#!/usr/bin/env bash
# M3 step 10: Talos does not create the kube-public/cluster-info ConfigMap
# that kubeadm-based clusters get for free. Pinniped Concierge's
# kube-cert-agent-controller hard-depends on it (sequentially, before it
# even inspects the kube-cert-agent pod it deploys) to learn the cluster's
# public CA bundle + apiserver address for CredentialIssuer.status -- found
# live: CredentialIssuer stuck on "CouldNotGetClusterInfo" indefinitely
# with no other symptom, even once the kube-cert-agent pod itself was
# healthy.
#
# Contents mirror exactly what kubeadm itself writes: a bare kubeconfig
# (no user/context) with just the cluster CA + server URL, both public,
# non-sensitive -- safe to keep in kube-public, but generated fresh from
# the live cluster's own kubeconfig rather than committed statically,
# since a rebuilt Talos cluster mints a new CA and this would go stale.
#
# Idempotent: safe to re-run (kubectl apply).
#
# Requires: kubectl (KUBECONFIG for controlplane).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/prompt-color.sh"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/homelab/controlplane.yaml}"
export KUBECONFIG="${KUBECONFIG_PATH}"

info "Reading CA + server from the live cluster's kubeconfig ..."
CA_DATA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SERVER=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')

if [[ -z "${CA_DATA}" || -z "${SERVER}" ]]; then
  echo "Could not read CA data / server from the current kubeconfig context." >&2
  exit 1
fi

info "Applying kube-public/cluster-info (server: ${SERVER}) ..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-info
  namespace: kube-public
data:
  kubeconfig: |
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        certificate-authority-data: ${CA_DATA}
        server: ${SERVER}
      name: ""
    contexts: null
    current-context: ""
    preferences: {}
    users: null
EOF

success "kube-public/cluster-info applied."
echo ""
info "Verify with:"
info "  kubectl get credentialissuer pinniped-concierge-config -o jsonpath='{.status.strategies}'"
