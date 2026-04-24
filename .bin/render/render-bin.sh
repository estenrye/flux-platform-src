#!/bin/bash
set -e
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
RENDER_DIR=${RENDER_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")/.render" && pwd)}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}
RELATIVE_PATH=${1}

SOURCE_REPO=${SOURCE_REPO:-$(${SCRIPTS_DIR}/render/render-get-source-repository.sh)}
TARGET_REPO_OWNER=${TARGET_REPO_OWNER:-$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)}
TARGET_REPO_NAME=${TARGET_REPO_NAME:-flux-platform-rendered}

cp -r ${SCRIPTS_DIR} ${RENDER_DIR}/${TARGET_REPO_NAME}/.bin
cp -r ${BASE_DIR}/.vscode ${RENDER_DIR}/${TARGET_REPO_NAME}/.vscode

mkdir -p ${RENDER_DIR}/${TARGET_REPO_NAME}/.venv
cp ${BASE_DIR}/.venv/.gitignore ${RENDER_DIR}/${TARGET_REPO_NAME}/.venv/.gitignore

mkdir -p ${RENDER_DIR}/${TARGET_REPO_NAME}/doc/adr
cp ${BASE_DIR}/doc/adr/0001-record-architecture-decisions.md ${RENDER_DIR}/${TARGET_REPO_NAME}/doc/adr/

pushd ${SCRIPTS_DIR}
adr generate toc \
  | sed 's#](#](https://github.com/estenrye/flux-platform-src/blob/main/doc/adr/#g' \
  | sed "1s|^# |# ${SOURCE_REPO} |" \
  > ${RENDER_DIR}/${TARGET_REPO_NAME}/doc/adr/0002-source-repo-adr-index.md
popd