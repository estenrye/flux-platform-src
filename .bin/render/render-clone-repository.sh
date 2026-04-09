#!/bin/bash
REPO=${GITHUB_REPOSITORY:-estenrye/flux-platform-rendered}
REPO_OWNER=$(dirname ${REPO})
REPO_NAME=$(basename ${REPO})
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}
RENDER_DIR=${RENDER_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")/../.render" && pwd)}
GH_TOKEN=${RENDER_GITHUB_TOKEN:-$(gh auth token)}

export GH_TOKEN

pushd ${RENDER_DIR}
rm -rf ${REPO_NAME}
gh repo clone ${REPO} -- --depth 1
popd