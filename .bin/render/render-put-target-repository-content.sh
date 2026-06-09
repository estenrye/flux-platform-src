#!/bin/bash
set -euo pipefail
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
RENDER_DIR=${RENDER_DIR:-$(dirname "$SCRIPTS_DIR")/.render}
RENDER_SOURCE_NAME=${RENDER_SOURCE_NAME:-flux-platform-rendered}
TARGET_REPO_NAME=${TARGET_REPO_NAME:?TARGET_REPO_NAME is required}
CLUSTER_NAME=${CLUSTER_NAME:?CLUSTER_NAME is required}

SOURCE_DIR="${RENDER_DIR}/${RENDER_SOURCE_NAME}"
TARGET_DIR="${RENDER_DIR}/${TARGET_REPO_NAME}"

if [ -d "${SOURCE_DIR}/applications" ]; then
  cp -r "${SOURCE_DIR}/applications" "${TARGET_DIR}/"
fi

if [ -d "${SOURCE_DIR}/clusters/${CLUSTER_NAME}" ]; then
  mkdir -p "${TARGET_DIR}/clusters"
  cp -r "${SOURCE_DIR}/clusters/${CLUSTER_NAME}" "${TARGET_DIR}/clusters/"
fi
