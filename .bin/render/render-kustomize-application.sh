#!/bin/bash
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
RENDER_DIR=${RENDER_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")/.render" && pwd)}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}
RELATIVE_PATH=${1}

REPO_OWNER=$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)
REPO_NAME=$(${SCRIPTS_DIR}/render/render-get-source-repository-name.sh)

if [ -z "$RELATIVE_PATH" ]; then
  echo "Usage: $0 <relative-path>"
  exit 1
fi

mkdir -p ${RENDER_DIR}/${REPO_NAME}/${RELATIVE_PATH}

TMP_DIR="$(mktemp -d)"
cp ${BASE_DIR}/${RELATIVE_PATH}/* ${TMP_DIR}
pushd ${BASE_DIR}/${RELATIVE_PATH}
${SCRIPTS_DIR}/render/render-labels-transformer.sh > ${TMP_DIR}/labels.yaml
ls -l ${TMP_DIR}
popd

kustomize build --enable-helm ${TMP_DIR} > ${RENDER_DIR}/${REPO_NAME}/${RELATIVE_PATH}/rendered.yaml

cat > ${RENDER_DIR}/${REPO_NAME}/${RELATIVE_PATH}/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- rendered.yaml
EOF

rm -rf ${TMP_DIR}
