#!/bin/bash
set -euo pipefail
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}

CLUSTER=${CLUSTER:?CLUSTER is required. Usage: make bootstrap-cluster-catalog CLUSTER=<name> KUBECONFIG=<path>}
KUBECONFIG=${KUBECONFIG:?KUBECONFIG is required. Usage: make bootstrap-cluster-catalog CLUSTER=<name> KUBECONFIG=<path>}

CLUSTER_DIR="${BASE_DIR}/clusters/${CLUSTER}"
CATALOG="${CLUSTER_DIR}/catalog.yaml"

mkdir -p "${CLUSTER_DIR}"

if [ -f "${CATALOG}" ]; then
  echo "catalog.yaml already exists for ${CLUSTER} — skipping."
  exit 0
fi

cat > "${CATALOG}" <<EOF
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: ${CLUSTER}
  annotations:
    github.com/project-slug: estenrye/flux-platform-rendered-${CLUSTER}
    rye.ninja/flux-source-repo: estenrye/flux-platform-src
    rye.ninja/kubeconfig: ${KUBECONFIG}
spec:
  owner: group:platform-engineering
  domain: platform
EOF

echo "Created ${CATALOG}"
