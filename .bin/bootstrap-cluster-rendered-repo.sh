#!/bin/bash
set -euo pipefail
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}
CLUSTER=${CLUSTER:?CLUSTER is required. Usage: make bootstrap-cluster-rendered-repo CLUSTER=<cluster-dir-name>}

CATALOG="${BASE_DIR}/clusters/${CLUSTER}/catalog.yaml"
[ -f "${CATALOG}" ] || { echo "Error: ${CATALOG} not found"; exit 1; }

PROJECT_SLUG=$(yq e '.metadata.annotations["github.com/project-slug"]' "${CATALOG}")
REPO_OWNER=$(echo "${PROJECT_SLUG}" | cut -d'/' -f1)
REPO_NAME=$(echo "${PROJECT_SLUG}" | cut -d'/' -f2)

echo "Creating rendered repository: ${REPO_OWNER}/${REPO_NAME} ..."

if ! gh api "repos/${REPO_OWNER}/${REPO_NAME}" >/dev/null 2>&1; then
  gh repo create "${REPO_OWNER}/${REPO_NAME}" \
    --private \
    --description "Rendered Flux manifests for ${CLUSTER} (machine-generated — do not commit directly)" \
    --disable-wiki \
    --disable-issues

  echo "Initialising repository with first commit ..."
  README_CONTENT=$(printf '# %s\n\nMachine-generated rendered manifests. Do not commit directly.\n\nSource: [estenrye/flux-platform-src](https://github.com/estenrye/flux-platform-src)' \
    "${REPO_NAME}" | base64 | tr -d '\n')
  gh api "repos/${REPO_OWNER}/${REPO_NAME}/contents/README.md" \
    --method PUT \
    -f message="chore: initialise rendered repository" \
    -f content="${README_CONTENT}"

  echo "Enabling auto-merge ..."
  gh api "repos/${REPO_OWNER}/${REPO_NAME}" \
    --method PATCH \
    -F allow_auto_merge=true >/dev/null
else
  echo "Repository ${REPO_OWNER}/${REPO_NAME} already exists — skipping creation."
fi

echo ""
echo "Bootstrap complete."
echo "  Repo: https://github.com/${REPO_OWNER}/${REPO_NAME}"
