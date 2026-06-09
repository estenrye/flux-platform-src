#!/bin/bash
set -e
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
# git branch --show-current returns empty in detached HEAD (e.g. actions/checkout on a PR).
# Fall back to GitHub Actions env vars: GITHUB_HEAD_REF (PR source branch) or GITHUB_REF_NAME (push).
SOURCE_BRANCH_NAME=${SOURCE_BRANCH_NAME:-${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git branch --show-current)}}}

export SOURCE_BRANCH_NAME
echo -n "${SOURCE_BRANCH_NAME}"