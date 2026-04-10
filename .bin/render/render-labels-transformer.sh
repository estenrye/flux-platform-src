#!/bin/bash
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
WORKING_DIR=${WORKING_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)}
LABEL_ZONE=${LABEL_ZONE:-rye.ninja}
RELATIVE_PATH=${1:-}

REPO=$(${SCRIPTS_DIR}/render/render-get-source-repository.sh)
COMMIT_HASH=$(${SCRIPTS_DIR}/render/render-get-source-repository-commit-hash.sh)

COMPONENT_NAME="unknown"
COMPONENT_OWNER="unknown"
COMPONENT_CHART_NAME="N/A"
COMPONENT_CHART_REPO="N/A"
COMPONENT_CHART_VERSION="N/A"

if [ -z "$RELATIVE_PATH" ] || [ -z "$WORKING_DIR" ]; then
  echo "Usage: $0 <relative-path> <working-dir>"
  exit 1
fi

if [ -f catalog.yaml ]; then
  COMPONENT_NAME=$(yq e '.metadata.name' catalog.yaml)
  COMPONENT_OWNER=$(yq e '.spec.owner' catalog.yaml)
fi

pushd "${WORKING_DIR}/${RELATIVE_PATH}" > /dev/null || exit 1

cat > "${WORKING_DIR}/${RELATIVE_PATH}/labels.yaml" <<EOF
apiVersion: builtin
kind: LabelTransformer
metadata:
  name: global-labels
labels:
  ${LABEL_ZONE}/flux-src-repository: ${REPO}
  ${LABEL_ZONE}/flux-src-commit-hash: ${COMMIT_HASH}
  ${LABEL_ZONE}/component: ${COMPONENT_NAME}
  ${LABEL_ZONE}/owner: ${COMPONENT_OWNER}
fieldSpecs:
- path: metadata/labels
  create: true
- path: spec/template/metadata/labels
  create: true
  kind: Deployment
EOF

popd > /dev/null || exit 1