#!/bin/bash
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}
GH_TOKEN=${GITHUB_TOKEN:-$(gh auth token)}

pushd ${BASE_DIR} > /dev/null
REPO=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
popd > /dev/null

echo -n "${REPO}"
