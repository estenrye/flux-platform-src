#!/bin/bash
set -e
REPO=${REPO:-estenrye/flux-platform-rendered}
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}
RENDER_DIR=${RENDER_DIR:-$(dirname "$SCRIPTS_DIR")/.render}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}
APP_DIR=${APP_DIR:-$(cd ${BASE_DIR}/applications && pwd)}

echo "Cloning Target Repository: ${TARGET_REPO_OWNER}/${TARGET_REPO_NAME}"
if [ -z "$GITHUB_TOKEN" ]; then
  echo "Error: GITHUB_TOKEN is not set. Please set the GITHUB_TOKEN environment variable or ensure you are authenticated with gh."
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-$(gh auth token)}

echo "Cloning Target Repository: ${TARGET_REPO_OWNER}/${TARGET_REPO_NAME}"
if [ -z "$RENDER_GITHUB_TOKEN" ]; then
  echo "Error: RENDER_GITHUB_TOKEN is not set. Please set the RENDER_GITHUB_TOKEN environment variable or ensure you are authenticated with gh."
  exit 1
fi

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
