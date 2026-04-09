#!/bin/bash
REPO=${REPO:-estenrye/flux-platform-rendered}
SCRIPTS_DIR=$(dirname "$0")
RENDER_DIR=$(dirname "$SCRIPTS_DIR")/.render

pushd ${RENDER_DIR}
rm -rf $(basename ${REPO})
gh repo clone ${REPO}
popd