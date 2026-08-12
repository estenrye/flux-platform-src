#!/bin/bash
set -euo pipefail
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}

CLUSTER=${CLUSTER:?CLUSTER is required. Usage: make bootstrap-cluster-catalog CLUSTER=<name> KUBECONFIG=<path>}
KUBECONFIG=${KUBECONFIG:?KUBECONFIG is required. Usage: make bootstrap-cluster-catalog CLUSTER=<name> KUBECONFIG=<path>}
# controlplane, not this cluster's own KUBECONFIG above -- XKubernetesCluster
# claims (M4) live on controlplane. Same env-var convention as
# bootstrap-provider-terraform-kvm-key.sh's KUBECONFIG_PATH.
CONTROLPLANE_KUBECONFIG_PATH="${CONTROLPLANE_KUBECONFIG_PATH:-${HOME}/.kube/homelab/controlplane.yaml}"

CLUSTER_DIR="${BASE_DIR}/clusters/${CLUSTER}"
CATALOG="${CLUSTER_DIR}/catalog.yaml"

mkdir -p "${CLUSTER_DIR}"

if [ -f "${CATALOG}" ]; then
  echo "catalog.yaml already exists for ${CLUSTER} — skipping."
  exit 0
fi

# Best-effort enrichment from this cluster's own XKubernetesCluster claim on
# controlplane, if one exists -- controlplane itself predates XKubernetesCluster
# and is script-bootstrapped, not claim-managed (ADR-14), so a missing claim
# (or an unreachable controlplane) just means these two fields stay blank,
# same as before this enrichment existed.
TRUST_DOMAIN=""
if [ -f "${CONTROLPLANE_KUBECONFIG_PATH}" ]; then
  TRUST_DOMAIN=$(kubectl --kubeconfig "${CONTROLPLANE_KUBECONFIG_PATH}" \
    get xkubernetesclusters.platform.rye.ninja "${CLUSTER}" -n crossplane-system \
    -o jsonpath='{.status.trustDomain}' 2>/dev/null || true)
fi

{
  echo "apiVersion: backstage.io/v1alpha1"
  echo "kind: System"
  echo "metadata:"
  echo "  name: ${CLUSTER}"
  echo "  annotations:"
  echo "    github.com/project-slug: estenrye/flux-platform-rendered-${CLUSTER}"
  echo "    rye.ninja/flux-source-repo: estenrye/flux-platform-src"
  echo "    rye.ninja/kubeconfig: ${KUBECONFIG}"
  if [ -n "${TRUST_DOMAIN}" ]; then
    echo "    rye.ninja/trust-domain: ${TRUST_DOMAIN}"
    echo "  description: >-"
    echo "    ${CLUSTER} cluster -- Talos-on-KVM (M4), trust domain ${TRUST_DOMAIN}."
  fi
  echo "spec:"
  echo "  owner: platform-engineering"
  echo "  domain: platform"
} > "${CATALOG}"

echo "Created ${CATALOG}"
