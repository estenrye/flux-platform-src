#!/bin/bash
set -e
REPO=${REPO:-estenrye/flux-platform-rendered}
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}
RENDER_DIR=${RENDER_DIR:-$(dirname "$SCRIPTS_DIR")/.render}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}
APP_DIR=${APP_DIR:-$(cd ${BASE_DIR}/applications && pwd)}
BIN_DIR=${BIN_DIR:-$(dirname "$SCRIPTS_DIR")/.venv/bin}
LABEL_ZONE=${LABEL_ZONE:-rye.ninja}

export REPO
export RENDER_DIR
export SCRIPTS_DIR
export APP_DIR
export GITHUB_TOKEN
export RENDER_GITHUB_TOKEN
export LABEL_ZONE

find ${RENDER_DIR} -type f -name "*.yaml" -o -name "*.yml" | xargs ${BIN_DIR}/kube-linter lint \
  --config ${BASE_DIR}/.kube-linter/config.yaml
