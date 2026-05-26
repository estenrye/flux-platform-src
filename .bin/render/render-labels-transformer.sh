#!/bin/bash
set -e
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
REPO=${1:-$REPO}
COMMIT_HASH=${2:-$COMMIT_HASH}
LABEL_ZONE=${3:-rye.ninja}

COMPONENT_NAME="unknown"
COMPONENT_OWNER="unknown"
COMPONENT_CHART_NAME="N/A"
COMPONENT_CHART_REPO="N/A"
COMPONENT_CHART_VERSION="N/A"

if [ -z "$REPO" ] || [ -z "$COMMIT_HASH" ] || [ -z "$LABEL_ZONE" ]; then
  echo "Usage: $0 <repo> <commit-hash> <label-zone>"
  exit 1
fi

if [ -f catalog.yaml ]; then
  COMPONENT_NAME=$(yq e '.metadata.name' catalog.yaml)
  COMPONENT_OWNER=$(yq e '.spec.owner' catalog.yaml)
fi

cat <<EOF
apiVersion: builtin
kind: AnnotationsTransformer
metadata:
  name: global-annotations
annotations:
  ${LABEL_ZONE}/flux-src-repository: ${REPO}
  ${LABEL_ZONE}/flux-src-commit-hash: ${COMMIT_HASH}
  ${LABEL_ZONE}/component: ${COMPONENT_NAME}
  ${LABEL_ZONE}/owner: ${COMPONENT_OWNER}
fieldSpecs:
- path: metadata/annotations
  create: true
- path: spec/template/metadata/annotations
  create: true
  kind: Deployment
EOF