#!/bin/bash
REPO=${GITHUB_REPOSITORY:-estenrye/flux-platform-rendered}
REPO_OWNER=$(dirname ${REPO})
REPO_NAME=$(basename ${REPO})
RENDER_DIR=${RENDER_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")/../.render" && pwd)}
GITHUB_TOKEN=${GITHUB_TOKEN:-$(gh auth token)}
export GITHUB_TOKEN

COMMIT_HASH=`${SCRIPTS_DIR}/render/render-get-source-commit-hash.sh`

echo "${COMMIT_HASH}"