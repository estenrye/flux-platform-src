#!/bin/bash
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
GH_TOKEN=${GITHUB_TOKEN:-$(gh auth token)}
pushd ${SCRIPTS_DIR} > /dev/null
REPO=${GITHUB_REPOSITORY:-$(${SCRIPTS_DIR}/render/render-get-source-repository.sh)}
popd > /dev/null
REPO_OWNER=$(dirname ${REPO})

echo -n "${REPO_OWNER}"