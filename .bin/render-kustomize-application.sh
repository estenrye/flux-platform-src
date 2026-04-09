#!/bin/bash
REPO=${REPO:-estenrye/flux-platform-rendered}
SCRIPTS_DIR=$(cd "$(dirname "$0")" && pwd)
RENDER_DIR=$(dirname "$SCRIPTS_DIR")/.render
BASE_DIR=$(dirname "$SCRIPTS_DIR")
RELATIVE_PATH=${1}

if [ -z "$RELATIVE_PATH" ]; then
  echo "Usage: $0 <relative-path>"
  exit 1
fi

mkdir -p ${RENDER_DIR}/$(basename ${REPO})/${RELATIVE_PATH}

TMP_DIR="$(mktemp -d)"
cp ${BASE_DIR}/${RELATIVE_PATH}/* ${TMP_DIR}
pushd ${BASE_DIR}/${RELATIVE_PATH}
${SCRIPTS_DIR}/render-labels-transformer.sh > ${TMP_DIR}/labels.yaml
popd

ls -l ${TMP_DIR}
kustomize build --enable-helm ${TMP_DIR} > ${RENDER_DIR}/$(basename ${REPO})/${RELATIVE_PATH}/rendered.yaml

cat > ${RENDER_DIR}/$(basename ${REPO})/${RELATIVE_PATH}/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- rendered.yaml
EOF

rm -rf ${TMP_DIR}
