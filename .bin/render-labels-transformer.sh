#!/bin/bash
COMMIT_ID=$(gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/commits/$(git branch --show-current)" --jq '.sha')
LABEL_ZONE=${LABEL_ZONE:-com.example}
COMPONENT_NAME="unknown"
COMPONENT_OWNER="unknown"
COMPONENT_CHART_NAME="N/A"
COMPONENT_CHART_REPO="N/A"
COMPONENT_CHART_VERSION="N/A"

if [ -f catalog.yaml ]; then
  COMPONENT_NAME=$(yq e '.metadata.name' catalog.yaml)
  COMPONENT_OWNER=$(yq e '.spec.owner' catalog.yaml)
fi

cat <<EOF
apiVersion: builtin
kind: LabelTransformer
metadata:
  name: global-labels
labels:
  ${LABEL_ZONE}/flux-src-commit-hash: ${COMMIT_ID}
  ${LABEL_ZONE}/component: ${COMPONENT_NAME}
  ${LABEL_ZONE}/owner: ${COMPONENT_OWNER}
fieldSpecs:
- path: metadata/labels
  create: true
- path: spec/template/metadata/labels
  create: true
  kind: Deployment
EOF