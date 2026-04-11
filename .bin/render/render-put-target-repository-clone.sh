#!/bin/bash
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
RENDER_DIR=${RENDER_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")/.render" && pwd)}
TARGET_REPO_OWNER=${TARGET_REPO_OWNER:-$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)}
TARGET_REPO_NAME=${TARGET_REPO_NAME:-flux-platform-rendered}
GH_TOKEN=${RENDER_GITHUB_TOKEN:-$(gh auth token)}

pushd ${RENDER_DIR} > /dev/null || exit 1
rm -rf ${TARGET_REPO_NAME}
gh repo clone ${TARGET_REPO_OWNER}/${TARGET_REPO_NAME} -- --depth 1
popd > /dev/null || exit 1