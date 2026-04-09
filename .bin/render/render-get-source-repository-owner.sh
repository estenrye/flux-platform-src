#!/bin/bash
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
GH_TOKEN=${GITHUB_TOKEN:-$(gh auth token)}
REPO=${GITHUB_REPOSITORY:-$(${SCRIPTS_DIR}/render/render-get-source-repository.sh)}
REPO_OWNER=$(dirname ${REPO})

echo "${REPO_OWNER}"