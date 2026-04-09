#!/bin/bash
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
RENDER_DIR=${RENDER_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")/.render" && pwd)}
SOURCE_REPO_OWNER=${SOURCE_REPO_OWNER:-$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)}
SOURCE_REPO_NAME=${SOURCE_REPO_NAME:-$(${SCRIPTS_DIR}/render/render-get-source-repository-name.sh)}
SOURCE_REPO_COMMIT_HASH=`${SCRIPTS_DIR}/render/render-get-source-repository-commit-hash.sh`
TARGET_REPO_OWNER=${TARGET_REPO_OWNER:-$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)}
TARGET_REPO_NAME=${TARGET_REPO_NAME:-flux-platform-rendered}
GH_TOKEN=${RENDER_GITHUB_TOKEN:-$(gh auth token)}

BRANCH_NAME="rendered/${SOURCE_REPO_OWNER}/${SOURCE_REPO_NAME}/${SOURCE_REPO_COMMIT_HASH}"
echo "Creating Branch: ${BRANCH_NAME}"

pushd ${RENDER_DIR}/${TARGET_REPO_NAME}
git checkout -b ${BRANCH_NAME}
popd