#!/bin/bash
set -euo pipefail
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}
CLUSTERS_DIR="${BASE_DIR}/clusters"
SOURCE_REPO=${SOURCE_REPO:-estenrye/flux-platform-src}

if [ ! -d "${CLUSTERS_DIR}" ]; then
  echo "[]"
  exit 0
fi

result="[]"

for catalog in "${CLUSTERS_DIR}"/*/catalog.yaml; do
  [ -f "${catalog}" ] || continue
  cluster_dir=$(dirname "${catalog}")
  cluster_name=$(basename "${cluster_dir}")

  flux_source_repo=$(yq e '.metadata.annotations["rye.ninja/flux-source-repo"]' "${catalog}" 2>/dev/null || true)
  if [ "${flux_source_repo}" != "${SOURCE_REPO}" ]; then
    echo "Warning: skipping ${cluster_name} — rye.ninja/flux-source-repo is '${flux_source_repo}', expected '${SOURCE_REPO}'" >&2
    continue
  fi

  # A cluster with a catalog but no kustomization.yaml is not renderable yet
  # (render-kustomize-base-and-patches.sh skips it for the same reason); don't
  # spawn a push-cluster job for it.
  if [ ! -f "${cluster_dir}/kustomization.yaml" ]; then
    echo "Warning: skipping ${cluster_name} — no kustomization.yaml yet (bootstrap in progress)" >&2
    continue
  fi

  name=$(yq e '.metadata.name' "${catalog}")
  project_slug=$(yq e '.metadata.annotations["github.com/project-slug"]' "${catalog}")
  rendered_repo_owner=$(echo "${project_slug}" | cut -d'/' -f1)
  rendered_repo_name=$(echo "${project_slug}" | cut -d'/' -f2)

  entry=$(jq -n \
    --arg name "${name}" \
    --arg rendered_repo_owner "${rendered_repo_owner}" \
    --arg rendered_repo_name "${rendered_repo_name}" \
    --arg environment "${name}" \
    '{name: $name, rendered_repo_owner: $rendered_repo_owner, rendered_repo_name: $rendered_repo_name, environment: $environment}')

  result=$(echo "${result}" | jq --argjson entry "${entry}" '. + [$entry]')
done

echo "${result}"
