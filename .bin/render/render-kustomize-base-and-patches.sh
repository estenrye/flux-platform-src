#!/bin/bash
set -e
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
WORKING_DIR=${WORKING_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")" && pwd)}
RENDER_DIR=${RENDER_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")/.render" && pwd)}
TARGET_REPO_OWNER=${TARGET_REPO_OWNER:-$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)}
TARGET_REPO_NAME=${TARGET_REPO_NAME:-flux-platform-rendered}
COMMIT_HASH=${COMMIT_HASH:-$(${SCRIPTS_DIR}/render/render-get-source-repository-commit-hash.sh)}
RELATIVE_PATH=${1:-}
CLUSTER_FILTER=${CLUSTER_FILTER:-}
REPO=$(${SCRIPTS_DIR}/render/render-get-source-repository.sh)
export WORKING_DIR
export LABEL_ZONE
mkdir -p "${RENDER_DIR}/${TARGET_REPO_NAME}"

find "${WORKING_DIR}/${RELATIVE_PATH}" -name "kustomization.yaml" -exec dirname {} \; | sed "s|${WORKING_DIR}/${RELATIVE_PATH}/||" | while read -r directory; do
  if [ -n "${CLUSTER_FILTER}" ] && [ "${RELATIVE_PATH}" = "clusters" ]; then
    cluster_root=$(echo "$directory" | cut -d'/' -f1)
    if [ "$cluster_root" != "${CLUSTER_FILTER}" ]; then
      continue
    fi
  fi
  echo "Rendering '${WORKING_DIR}/${RELATIVE_PATH}/${directory}' ..."
  mkdir -p "${RENDER_DIR}/${TARGET_REPO_NAME}"/${RELATIVE_PATH}/${directory}
  pushd "${WORKING_DIR}/${RELATIVE_PATH}/${directory}" > /dev/null || exit 1
  # --helm-kube-version: kustomize's built-in helm invocation defaults to
  # an old Capabilities.KubeVersion (pre-1.30) unless told otherwise, which
  # trips charts with a kubeVersion gate (e.g. openbao-helm requires
  # >=1.30.0-0). Pin to controlplane's actual server version.
  kustomize build --enable-helm --helm-kube-version 1.36.2 . > "${RENDER_DIR}/${TARGET_REPO_NAME}/${RELATIVE_PATH}/${directory}/rendered.yaml"
  cp catalog.yaml "${RENDER_DIR}/${TARGET_REPO_NAME}/${RELATIVE_PATH}/${directory}/catalog.yaml"
  pushd "${RENDER_DIR}/${TARGET_REPO_NAME}/${RELATIVE_PATH}/${directory}" > /dev/null || exit 1
  popd > /dev/null || exit 1
  popd > /dev/null || exit 1
  cat > "${RENDER_DIR}/${TARGET_REPO_NAME}/${RELATIVE_PATH}/${directory}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- rendered.yaml
EOF
  if [ -f .env-template ]; then
    cp .env-template "${RENDER_DIR}/${TARGET_REPO_NAME}/${RELATIVE_PATH}/${directory}/.env-template"
  fi
  echo "Successfully Rendered '${WORKING_DIR}/${RELATIVE_PATH}/${directory}'"
done
