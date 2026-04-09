#!/bin/bash
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
REPO_OWNER=$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)
REPO_NAME=$(${SCRIPTS_DIR}/render/render-get-source-repository-name.sh)
GH_TOKEN=${GITHUB_TOKEN:-$(gh auth token)}
export GH_TOKEN

COMMIT_HASH=${GITHUB_SHA:-$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/commits/$(git branch --show-current)" --jq '.sha')}

echo "${COMMIT_HASH}"