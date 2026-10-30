#!/bin/bash
# Render lint: for each cluster directory given, render it with kustomize and
# assert that, when the seaweedfs-db-barman ObjectStore is present, its
# endpointURL is a real Cloudflare R2 account endpoint
# (https://<32-hex-account-id>.r2.cloudflarestorage.com) rather than the
# base's placeholder https://CF_ACCOUNT_ID.r2.cloudflarestorage.com. Each
# cluster must patch it (see clusters/core-infra/patches/seaweedfs-db-barman.yaml).
# A clean kustomize build proves nothing here: a JSON6902 patch whose target
# matches nothing is a silent no-op (docs/memory/m3-render-lint-ci-fix.md).
# A cluster that renders no such ObjectStore passes.
set -euo pipefail

VALID='^https://[0-9a-f]{32}\.r2\.cloudflarestorage\.com$'

[ "$#" -gt 0 ] || { echo "Usage: $0 <cluster-dir>..." >&2; exit 2; }

FAIL=0
for dir in "$@"; do
  rendered=$(kustomize build --enable-helm --helm-kube-version 1.36.2 "${dir}")

  # One line per ObjectStore: <endpointURL>
  endpoints=$(printf '%s\n' "${rendered}" | yq eval '
    select(.kind == "ObjectStore" and .metadata.name == "seaweedfs-db-barman"
           and .metadata.namespace == "seaweedfs")
    | .spec.configuration.endpointURL' - | grep -v '^---$' || true)

  if [ -z "${endpoints}" ]; then
    echo "OK:   ${dir}: no seaweedfs-db-barman ObjectStore rendered"
    continue
  fi

  bad=0
  while read -r endpoint; do
    if ! printf '%s' "${endpoint}" | grep -Eq "${VALID}"; then
      echo "FAIL: ${dir}: ObjectStore/seaweedfs-db-barman endpointURL '${endpoint}' is not an R2 account endpoint (placeholder left unpatched?)"
      bad=1
      FAIL=$((FAIL + 1))
    fi
  done <<< "${endpoints}"
  [ "${bad}" -eq 0 ] && echo "OK:   ${dir}: seaweedfs-db-barman endpoint valid"
done

[ "${FAIL}" -eq 0 ]
