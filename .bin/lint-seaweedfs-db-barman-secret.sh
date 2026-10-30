#!/bin/bash
# Render lint: for each cluster directory given, render it with kustomize and
# assert that, when the seaweedfs-db-barman ObjectStore is present, the SOPS
# Secret cloudflare-r2-seaweedfs-db-barman (written by
# .bin/provision-cloudflare-r2-bucket.sh to clusters/<name>/secrets/) is also
# rendered into namespace seaweedfs, and that its credentials are still
# SOPS-encrypted (ENC[...]) rather than plaintext.
# A cluster whose kustomization forgets to list the secrets/ file builds
# cleanly and simply never gets the Secret, so a clean build proves nothing
# (docs/memory/m3-render-lint-ci-fix.md).
# A cluster that renders no such ObjectStore passes.
set -euo pipefail

SECRET_NAME="cloudflare-r2-seaweedfs-db-barman"
SECRET_NS="seaweedfs"
KEYS=(access-key-id secret-access-key)

[ "$#" -gt 0 ] || { echo "Usage: $0 <cluster-dir>..." >&2; exit 2; }

FAIL=0
for dir in "$@"; do
  rendered=$(kustomize build --enable-helm --helm-kube-version 1.36.2 "${dir}")

  has_store=$(printf '%s\n' "${rendered}" | yq eval '
    select(.kind == "ObjectStore" and .metadata.name == "seaweedfs-db-barman"
           and .metadata.namespace == "'"${SECRET_NS}"'")
    | .metadata.name' - | grep -v '^---$' || true)

  if [ -z "${has_store}" ]; then
    echo "OK:   ${dir}: no seaweedfs-db-barman ObjectStore rendered"
    continue
  fi

  secret=$(printf '%s\n' "${rendered}" | yq eval '
    select(.kind == "Secret" and .metadata.name == "'"${SECRET_NAME}"'"
           and .metadata.namespace == "'"${SECRET_NS}"'")' - | grep -v '^---$' || true)

  if [ -z "${secret}" ]; then
    echo "FAIL: ${dir}: Secret/${SECRET_NAME} (namespace ${SECRET_NS}) is not rendered; run .bin/provision-cloudflare-r2-bucket.sh and list secrets/${SECRET_NAME}.sops.yaml in the cluster kustomization"
    FAIL=$((FAIL + 1))
    continue
  fi

  bad=0
  for key in "${KEYS[@]}"; do
    value=$(printf '%s\n' "${secret}" | yq eval '(.stringData["'"${key}"'"] // .data["'"${key}"'"]) // ""' -)
    case "${value}" in
      "")
        echo "FAIL: ${dir}: Secret/${SECRET_NAME} has no '${key}'"
        bad=1; FAIL=$((FAIL + 1)) ;;
      ENC\[*) ;;
      *)
        echo "FAIL: ${dir}: Secret/${SECRET_NAME} '${key}' is not SOPS-encrypted"
        bad=1; FAIL=$((FAIL + 1)) ;;
    esac
  done
  [ "${bad}" -eq 0 ] && echo "OK:   ${dir}: Secret/${SECRET_NAME} present and encrypted"
done

[ "${FAIL}" -eq 0 ]
