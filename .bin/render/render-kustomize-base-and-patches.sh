#!/bin/bash
set -e
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
WORKING_DIR=${WORKING_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)}
RENDER_DIR=${RENDER_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")/.render" && pwd)}
TARGET_REPO_OWNER=${TARGET_REPO_OWNER:-$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)}
TARGET_REPO_NAME=${TARGET_REPO_NAME:-flux-platform-rendered}
LABEL_ZONE=${LABEL_ZONE:-rye.ninja}
COMMIT_HASH=${COMMIT_HASH:-$(${SCRIPTS_DIR}/render/render-get-source-repository-commit-hash.sh)}
RELATIVE_PATH=${1:-}
REPO=$(${SCRIPTS_DIR}/render/render-get-source-repository.sh)
export WORKING_DIR
export LABEL_ZONE
mkdir -p "${RENDER_DIR}/${TARGET_REPO_NAME}"

find "${WORKING_DIR}/${RELATIVE_PATH}" -name "kustomization.yaml" -exec dirname {} \; | sed "s|${WORKING_DIR}/${RELATIVE_PATH}/||" | while read -r directory; do
  echo "Rendering '${WORKING_DIR}/${RELATIVE_PATH}/${directory}' ..."
  mkdir -p "${RENDER_DIR}/${TARGET_REPO_NAME}"/${RELATIVE_PATH}/${directory}
  pushd "${WORKING_DIR}/${RELATIVE_PATH}/${directory}" > /dev/null || exit 1
  kustomize build --enable-helm . > "${RENDER_DIR}/${TARGET_REPO_NAME}/${RELATIVE_PATH}/${directory}/rendered.yaml"
  cp catalog.yaml "${RENDER_DIR}/${TARGET_REPO_NAME}/${RELATIVE_PATH}/${directory}/catalog.yaml"
  pushd "${RENDER_DIR}/${TARGET_REPO_NAME}/${RELATIVE_PATH}/${directory}" > /dev/null || exit 1
  ${SCRIPTS_DIR}/render/render-labels-transformer.sh "${REPO}" "${COMMIT_HASH}" "${LABEL_ZONE}" > labels.yaml
  popd > /dev/null || exit 1
  popd > /dev/null || exit 1
  cat > "${RENDER_DIR}/${TARGET_REPO_NAME}/${RELATIVE_PATH}/${directory}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- rendered.yaml
transformers:
- labels.yaml
EOF
  if [ -f .env-template ]; then
    cp .env-template "${RENDER_DIR}/${TARGET_REPO_NAME}/${RELATIVE_PATH}/${directory}/.env-template"
  fi
  echo "Successfully Rendered '${WORKING_DIR}/${RELATIVE_PATH}/${directory}'"
done
