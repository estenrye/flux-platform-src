#!/usr/bin/env bash
# Resolves KUBECONFIG: catalog annotation takes precedence, env var is fallback.
# Source this file after prompt-cluster.sh (which sets CATALOG).

if [ -n "${CATALOG:-}" ] && [ -f "${CATALOG}" ]; then
  _CATALOG_KB=$(yq e '.metadata.annotations["rye.ninja/kubeconfig"]' "${CATALOG}" 2>/dev/null || true)
  if [ -n "${_CATALOG_KB}" ] && [ "${_CATALOG_KB}" != "null" ]; then
    KUBECONFIG="${_CATALOG_KB/#\~/$HOME}"
  fi
  unset _CATALOG_KB
fi

: "${KUBECONFIG:?KUBECONFIG is required. Set KUBECONFIG to the cluster kubeconfig path (e.g. from make oci-kubeconfig)}"
[ -f "${KUBECONFIG}" ] || { error "KUBECONFIG file not found: ${KUBECONFIG}"; exit 1; }
export KUBECONFIG
