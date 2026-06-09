#!/usr/bin/env bash
# Reads CLUSTER env var, validates cluster directory, exports derived metadata.
# Source this file after prompt-color.sh.

: "${CLUSTER:?CLUSTER is required. Usage: CLUSTER=<cluster-dir-name> make <target>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_DIR="clusters/${CLUSTER}"
CLUSTER_PATH="${REPO_ROOT}/${CLUSTER_DIR}"

[ -d "${CLUSTER_PATH}" ] || { error "Cluster directory not found: ${CLUSTER_PATH}"; exit 1; }

CATALOG="${CLUSTER_PATH}/catalog.yaml"
[ -f "${CATALOG}" ] || { error "catalog.yaml not found: ${CATALOG}"; exit 1; }

CLUSTER_NAME=$(yq e '.metadata.name' "${CATALOG}")
PROJECT_SLUG=$(yq e '.metadata.annotations["github.com/project-slug"]' "${CATALOG}")
RENDERED_REPO_OWNER=$(echo "${PROJECT_SLUG}" | cut -d'/' -f1)
RENDERED_REPO_NAME=$(echo "${PROJECT_SLUG}" | cut -d'/' -f2)

export REPO_ROOT CLUSTER_DIR CLUSTER_PATH CLUSTER_NAME RENDERED_REPO_OWNER RENDERED_REPO_NAME
