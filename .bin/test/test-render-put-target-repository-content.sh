#!/bin/bash
set -e
SCRIPTS_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

# Setup source artifact structure
mkdir -p "${TEMP_DIR}/.render/flux-platform-rendered/applications/my-app/v1.0"
echo "app: rendered" > "${TEMP_DIR}/.render/flux-platform-rendered/applications/my-app/v1.0/rendered.yaml"

mkdir -p "${TEMP_DIR}/.render/flux-platform-rendered/clusters/spot.us-central-dfw-2.test.crossplane"
echo "cluster: rendered" > "${TEMP_DIR}/.render/flux-platform-rendered/clusters/spot.us-central-dfw-2.test.crossplane/rendered.yaml"

mkdir -p "${TEMP_DIR}/.render/flux-platform-rendered/clusters/spot.us-central-dfw-2.test.family-services"
echo "other: rendered" > "${TEMP_DIR}/.render/flux-platform-rendered/clusters/spot.us-central-dfw-2.test.family-services/rendered.yaml"

# Setup target (cloned rendered repo directory) with files from an earlier render
# that the fresh render no longer produces, plus another cluster's directory.
T="${TEMP_DIR}/.render/flux-platform-rendered-spot.us-central-dfw-2.test.crossplane"
mkdir -p "${T}/applications/removed-app/v1.0" "${T}/applications/my-app/v1.0/resources" \
  "${T}/clusters/spot.us-central-dfw-2.test.crossplane/resources" \
  "${T}/clusters/spot.us-central-dfw-2.test.family-services"
echo stale > "${T}/applications/removed-app/v1.0/rendered.yaml"
echo stale > "${T}/applications/my-app/v1.0/resources/v1_configmap_gone.yaml"
echo stale > "${T}/clusters/spot.us-central-dfw-2.test.crossplane/resources/v1_configmap_gone.yaml"
echo keep > "${T}/clusters/spot.us-central-dfw-2.test.family-services/kept.yaml"

RENDER_DIR="${TEMP_DIR}/.render" \
TARGET_REPO_NAME="flux-platform-rendered-spot.us-central-dfw-2.test.crossplane" \
CLUSTER_NAME="spot.us-central-dfw-2.test.crossplane" \
bash "${SCRIPTS_DIR}/render/render-put-target-repository-content.sh"

TARGET="${TEMP_DIR}/.render/flux-platform-rendered-spot.us-central-dfw-2.test.crossplane"

[ -f "${TARGET}/applications/my-app/v1.0/rendered.yaml" ] || \
  { echo "FAIL: applications/ not copied"; exit 1; }

[ -f "${TARGET}/clusters/spot.us-central-dfw-2.test.crossplane/rendered.yaml" ] || \
  { echo "FAIL: cluster dir not copied"; exit 1; }

[ ! -f "${TARGET}/clusters/spot.us-central-dfw-2.test.family-services/rendered.yaml" ] || \
  { echo "FAIL: other cluster dir should not be copied"; exit 1; }

# Stale files from an earlier render are pruned ...
[ ! -e "${TARGET}/applications/removed-app" ] || \
  { echo "FAIL: removed application directory was not pruned"; exit 1; }
[ ! -e "${TARGET}/applications/my-app/v1.0/resources/v1_configmap_gone.yaml" ] || \
  { echo "FAIL: stale file under applications/ was not pruned"; exit 1; }
[ ! -e "${TARGET}/clusters/spot.us-central-dfw-2.test.crossplane/resources/v1_configmap_gone.yaml" ] || \
  { echo "FAIL: stale file under the cluster directory was not pruned"; exit 1; }
# ... but another cluster's directory in the clone is not touched.
[ -f "${TARGET}/clusters/spot.us-central-dfw-2.test.family-services/kept.yaml" ] || \
  { echo "FAIL: other cluster's directory must not be pruned"; exit 1; }

echo "PASS: render-put-target-repository-content"
