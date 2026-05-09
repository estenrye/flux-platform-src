#!/bin/bash
set -e
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
SOURCE_BRANCH_NAME=${SOURCE_BRANCH_NAME:-$(git branch --show-current)}

export SOURCE_BRANCH_NAME
echo -n "${SOURCE_BRANCH_NAME}"