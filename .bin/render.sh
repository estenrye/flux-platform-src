#!/bin/bash
REPO=${REPO:-estenrye/flux-platform-rendered}
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}
RENDER_DIR=${RENDER_DIR:-$(dirname "$SCRIPTS_DIR")/.render}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}
APP_DIR=${APP_DIR:-$(cd ${BASE_DIR}/applications && pwd)}
GITHUB_TOKEN=${GITHUB_TOKEN:-$(gh auth token)}
RENDER_GITHUB_TOKEN=${RENDER_GITHUB_TOKEN:-$(gh auth token)}
LABEL_ZONE=${LABEL_ZONE:-rye.ninja}

export REPO
export RENDER_DIR
export SCRIPTS_DIR
export APP_DIR
export GITHUB_TOKEN
export RENDER_GITHUB_TOKEN
export LABEL_ZONE

${SCRIPTS_DIR}/render/render-put-target-repository-clone.sh
${SCRIPTS_DIR}/render/render-put-target-repository-branch.sh
${SCRIPTS_DIR}/render/render-bin.sh
${SCRIPTS_DIR}/render/render-kustomize-base-and-patches.sh applications
