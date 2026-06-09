#!/bin/bash
set -e
SCRIPTS_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

# Setup: two valid clusters and one that belongs to a different source repo
mkdir -p "${TEMP_DIR}/clusters/spot.us-central-dfw-2.test.crossplane"
cat > "${TEMP_DIR}/clusters/spot.us-central-dfw-2.test.crossplane/catalog.yaml" <<'EOF'
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: spot.us-central-dfw-2.test.crossplane
  annotations:
    github.com/project-slug: estenrye/flux-platform-rendered-spot.us-central-dfw-2.test.crossplane
    rye.ninja/flux-source-repo: estenrye/flux-platform-src
spec:
  owner: group:platform-engineering
  domain: platform
EOF

mkdir -p "${TEMP_DIR}/clusters/spot.us-central-dfw-2.test.family-services"
cat > "${TEMP_DIR}/clusters/spot.us-central-dfw-2.test.family-services/catalog.yaml" <<'EOF'
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: spot.us-central-dfw-2.test.family-services
  annotations:
    github.com/project-slug: estenrye/flux-platform-rendered-spot.us-central-dfw-2.test.family-services
    rye.ninja/flux-source-repo: estenrye/flux-platform-src
spec:
  owner: group:platform-engineering
  domain: platform
EOF

mkdir -p "${TEMP_DIR}/clusters/foreign.cluster"
cat > "${TEMP_DIR}/clusters/foreign.cluster/catalog.yaml" <<'EOF'
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: foreign.cluster
  annotations:
    github.com/project-slug: estenrye/other-rendered-repo
    rye.ninja/flux-source-repo: estenrye/other-src-repo
spec:
  owner: group:other-team
  domain: platform
EOF

OUTPUT=$(BASE_DIR="${TEMP_DIR}" bash "${SCRIPTS_DIR}/render/render-discover-clusters.sh" 2>/dev/null)

COUNT=$(echo "${OUTPUT}" | jq 'length')
[ "${COUNT}" = "2" ] || { echo "FAIL: expected 2 clusters, got ${COUNT}"; echo "Output: ${OUTPUT}"; exit 1; }

NAME=$(echo "${OUTPUT}" | jq -r '.[].name' | grep -c "oci.us-phoenix-1.test")
[ "${NAME}" = "2" ] || { echo "FAIL: unexpected cluster names"; echo "Output: ${OUTPUT}"; exit 1; }

OWNER=$(echo "${OUTPUT}" | jq -r '.[0].rendered_repo_owner')
[ "${OWNER}" = "estenrye" ] || { echo "FAIL: expected owner estenrye, got ${OWNER}"; exit 1; }

REPO=$(echo "${OUTPUT}" | jq -r '.[0].rendered_repo_name')
echo "${REPO}" | grep -q "flux-platform-rendered" || { echo "FAIL: unexpected repo name ${REPO}"; exit 1; }

echo "PASS: render-discover-clusters"
