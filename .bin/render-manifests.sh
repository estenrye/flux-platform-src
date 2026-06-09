#!/bin/bash
set -e
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}
RENDER_DIR=${RENDER_DIR:-$(dirname "$SCRIPTS_DIR")/.render}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}

export RENDER_DIR
export SCRIPTS_DIR
export BASE_DIR

if [ -z "${CI}" ]; then
  mkdir -p "${RENDER_DIR}"
  if [ ! -f "${RENDER_DIR}/.gitignore" ]; then
    printf '*\n!.gitignore\n' > "${RENDER_DIR}/.gitignore"
  fi
fi

${SCRIPTS_DIR}/render/render-kustomize-base-and-patches.sh applications
${SCRIPTS_DIR}/render/render-kustomize-base-and-patches.sh clusters
${SCRIPTS_DIR}/render/render-split-resources.sh
