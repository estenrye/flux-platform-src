#!/bin/bash
set -e
SCRIPTS_DIR=$(cd "$(dirname "$0")/../.." && pwd)
TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

TARGET_REPO_NAME="flux-platform-rendered"
mkdir -p "${TEMP_DIR}/${TARGET_REPO_NAME}/applications/my-app/v1.0"

# Write a rendered.yaml with three resources:
#  1. Namespaced, grouped API (apps/v1 Deployment)
#  2. Namespaced, core API (v1 ConfigMap — no group)
#  3. Cluster-scoped, grouped API (rbac.authorization.k8s.io/v1 ClusterRole)
cat > "${TEMP_DIR}/${TARGET_REPO_NAME}/applications/my-app/v1.0/rendered.yaml" <<'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: source-controller
  namespace: flux-system
spec:
  replicas: 1
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: flux-config
  namespace: flux-system
data:
  key: value
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: flux-system
rules: []
EOF

# Write the existing kustomization.yaml that render-split-resources.sh will replace
cat > "${TEMP_DIR}/${TARGET_REPO_NAME}/applications/my-app/v1.0/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- rendered.yaml
EOF

# Run the script under test
RENDER_DIR="${TEMP_DIR}" TARGET_REPO_NAME="${TARGET_REPO_NAME}" \
  bash "${SCRIPTS_DIR}/.bin/render/render-split-resources.sh"

BASE="${TEMP_DIR}/${TARGET_REPO_NAME}/applications/my-app/v1.0"

# Assert: rendered.yaml is deleted
[ ! -f "${BASE}/rendered.yaml" ] || { echo "FAIL: rendered.yaml was not deleted"; exit 1; }

# Assert: namespaced grouped resource exists
[ -f "${BASE}/resources/flux-system/apps_v1_deployment_source-controller.yaml" ] || \
  { echo "FAIL: missing apps_v1_deployment_source-controller.yaml"; exit 1; }

# Assert: namespaced core resource exists (no apiGroup in filename)
[ -f "${BASE}/resources/flux-system/v1_configmap_flux-config.yaml" ] || \
  { echo "FAIL: missing v1_configmap_flux-config.yaml"; exit 1; }

# Assert: cluster-scoped resource exists (no namespace directory)
[ -f "${BASE}/resources/rbac.authorization.k8s.io_v1_clusterrole_flux-system.yaml" ] || \
  { echo "FAIL: missing rbac.authorization.k8s.io_v1_clusterrole_flux-system.yaml"; exit 1; }

# Assert: kustomization.yaml lists all three files (sorted)
KUSTOMIZATION="${BASE}/kustomization.yaml"
grep -q "resources/flux-system/apps_v1_deployment_source-controller.yaml" "${KUSTOMIZATION}" || \
  { echo "FAIL: kustomization.yaml missing apps_v1_deployment path"; exit 1; }
grep -q "resources/flux-system/v1_configmap_flux-config.yaml" "${KUSTOMIZATION}" || \
  { echo "FAIL: kustomization.yaml missing v1_configmap path"; exit 1; }
grep -q "resources/rbac.authorization.k8s.io_v1_clusterrole_flux-system.yaml" "${KUSTOMIZATION}" || \
  { echo "FAIL: kustomization.yaml missing clusterrole path"; exit 1; }

# Assert: resource file content is valid YAML containing the original document
python3 -c "
import yaml, sys
with open('${BASE}/resources/flux-system/apps_v1_deployment_source-controller.yaml') as f:
    doc = yaml.safe_load(f)
assert doc['kind'] == 'Deployment', f'expected Deployment, got {doc[\"kind\"]}'
assert doc['metadata']['name'] == 'source-controller'
assert doc['metadata']['namespace'] == 'flux-system'
print('PASS: resource content verified')
"

echo "PASS: render-split-resources"
