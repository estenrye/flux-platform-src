#!/bin/bash
set -euo pipefail
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
RENDER_DIR=${RENDER_DIR:-$(dirname "$SCRIPTS_DIR")/.render}
RENDER_SOURCE_NAME=${RENDER_SOURCE_NAME:-flux-platform-rendered}
TARGET_REPO_NAME=${TARGET_REPO_NAME:?TARGET_REPO_NAME is required}
CLUSTER_NAME=${CLUSTER_NAME:?CLUSTER_NAME is required}

SOURCE_DIR="${RENDER_DIR}/${RENDER_SOURCE_NAME}"
TARGET_DIR="${RENDER_DIR}/${TARGET_REPO_NAME}"

# Replace, do not merge: `cp -r` over the existing clone leaves behind every split
# resource file that a later render no longer produces (removed apps, renamed
# resources, old clusters). Flux only applies what kustomization.yaml lists, so the
# leftovers were harmless but accumulated and misled anyone browsing the repo.
# applications/ and clusters/<CLUSTER_NAME> are generated in full on every render,
# so the fresh copy is authoritative. Other clusters' directories in the clone are
# left alone, and a directory the render did not produce is not touched.
if [ -d "${SOURCE_DIR}/applications" ]; then
  rm -rf "${TARGET_DIR}/applications"
  cp -r "${SOURCE_DIR}/applications" "${TARGET_DIR}/"
fi

if [ -d "${SOURCE_DIR}/clusters/${CLUSTER_NAME}" ]; then
  mkdir -p "${TARGET_DIR}/clusters"
  rm -rf "${TARGET_DIR}/clusters/${CLUSTER_NAME}"
  cp -r "${SOURCE_DIR}/clusters/${CLUSTER_NAME}" "${TARGET_DIR}/clusters/"
fi
