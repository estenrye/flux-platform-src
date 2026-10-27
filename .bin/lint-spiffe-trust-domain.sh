#!/bin/bash
# ADR-16 render lint: for each cluster directory given, render it with
# kustomize and assert that every container carrying a --trust-domain arg
#   1. carries exactly one (a repeated flag silently lets the last one win), and
#   2. does not set it to cluster.local (the chart default; prohibited for
#      clusters sharing a trust anchor).
# A clean kustomize build proves neither: a JSON6902 patch whose target
# matches nothing is a silent no-op (docs/memory/m3-render-lint-ci-fix.md).
set -euo pipefail

[ "$#" -gt 0 ] || { echo "Usage: $0 <cluster-dir>..." >&2; exit 2; }

FAIL=0
for dir in "$@"; do
  rendered=$(kustomize build --enable-helm --helm-kube-version 1.36.2 "${dir}")

  # One line per --trust-domain arg: <kind>/<name>/<container><TAB><arg>
  args=$(printf '%s\n' "${rendered}" | yq eval '
    select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet")
    | .kind as $k | .metadata.name as $n
    | .spec.template.spec.containers[]
    | .name as $c
    | .args[]? | select(test("^--trust-domain(=|$)"))
    | $k + "/" + $n + "/" + $c + "	" + .' -)

  if [ -z "${args}" ]; then
    echo "OK:   ${dir}: no --trust-domain args rendered"
    continue
  fi

  while read -r container; do
    count=$(printf '%s\n' "${args}" | cut -f1 | grep -cxF -- "${container}")
    if [ "${count}" -ne 1 ]; then
      echo "FAIL: ${dir}: ${container} has ${count} --trust-domain args (want 1)"
      FAIL=$((FAIL + 1))
    fi
  done < <(printf '%s\n' "${args}" | cut -f1 | sort -u)

  while IFS=$'\t' read -r container arg; do
    if [ "${arg}" = "--trust-domain=cluster.local" ]; then
      echo "FAIL: ${dir}: ${container} uses prohibited trust domain cluster.local (ADR-16)"
      FAIL=$((FAIL + 1))
    fi
  done <<< "${args}"

  [ "${FAIL}" -eq 0 ] && echo "OK:   ${dir}: trust-domain args valid"
done

[ "${FAIL}" -eq 0 ]
