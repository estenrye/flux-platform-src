#!/usr/bin/env bash
# Generate the M2 migration inventory for a control plane cluster.
#
# Usage: generate-migration-inventory.sh [cluster-name]
#
# Read-only kubectl queries (no cloud credentials; the managed resources ARE
# the cloud state of record). Output: docs/migration/m2-spot-migration-inventory.md
# Regenerate at M2 kickoff and diff against the committed snapshot to catch drift.
#
# Design: docs/superpowers/specs/2026-07-11-m0-baseline-audit-design.md
set -euo pipefail

CLUSTER="${1:-crossplane}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="${REPO}/clusters/${CLUSTER}/catalog.yaml"
OUT="${REPO}/docs/migration/m2-spot-migration-inventory.md"

KUBECONFIG_RAW="$(grep 'rye.ninja/kubeconfig:' "${CATALOG}" | awk '{print $2}')"
KUBECONFIG="${KUBECONFIG_RAW/#\~/${HOME}}"
export KUBECONFIG

mkdir -p "${REPO}/docs/migration"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

md() { printf '%s\n' "$*" >> "${OUT}"; }

: > "${OUT}"
md "# M2 Migration Inventory: ${CLUSTER} (Rackspace Spot)"
md ""
md "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) by \`.bin/generate-migration-inventory.sh ${CLUSTER}\`"
md ""
md "Disposition legend: \`move-state\` (import with same external-name), \`recreate\` (fresh install via Flux), \`retire\` (do not migrate), \`n/a\`, or blank (decide during M2 planning)."
md ""

# ---------------------------------------------------------------- Crossplane
md "## Crossplane managed resources"
md ""
md "Migration rule: set deletionPolicy=Orphan, pause, export, import by external-name, verify observe-not-recreate."
md ""
md "| Kind | Namespace/Name | External name | ProviderConfig | DeletionPolicy | Ready | Disposition |"
md "|---|---|---|---|---|---|---|"
kubectl get managed -A -o json 2>/dev/null > "$T/managed.json"
jq -r '.items[] | [
    .kind,
    "\(.metadata.namespace // "-")/\(.metadata.name)",
    (.metadata.annotations["crossplane.io/external-name"] // "-"),
    (.spec.providerConfigRef.name // "-"),
    (.spec.deletionPolicy // "Delete"),
    ([.status.conditions[]? | select(.type=="Ready")][0].status // "-"),
    ""
  ] | "| " + join(" | ") + " |"' "$T/managed.json" | sort >> "${OUT}"
md ""

md "## Claims and composite resources"
md ""
md "| Kind | Namespace/Name | Composition | Ready | Disposition |"
md "|---|---|---|---|---|"
kubectl get xdelegatedhostedzoneaws -A -o json 2>/dev/null > "$T/xrs.json"
jq -r '.items[] | [
    .kind,
    "\(.metadata.namespace // "-")/\(.metadata.name)",
    (.spec.crossplane.compositionRef.name // .spec.compositionRef.name // "-"),
    ([.status.conditions[]? | select(.type=="Ready")][0].status // "-"),
    ""
  ] | "| " + join(" | ") + " |"' "$T/xrs.json" >> "${OUT}"
md ""

md "## XRDs and Compositions (installed via Flux; recreate on target)"
md ""
md '```'
kubectl get xrd -o custom-columns='NAME:.metadata.name,ESTABLISHED:.status.conditions[?(@.type=="Established")].status' 2>/dev/null >> "${OUT}" || true
kubectl get compositions -o custom-columns='NAME:.metadata.name,XR-KIND:.spec.compositeTypeRef.kind' 2>/dev/null >> "${OUT}" || true
md '```'
md ""

md "## Providers, functions, runtime configs (recreate via Flux)"
md ""
md '```'
kubectl get providers.pkg.crossplane.io -o custom-columns='NAME:.metadata.name,PACKAGE:.spec.package' --no-headers >> "${OUT}"
kubectl get functions.pkg.crossplane.io -o custom-columns='NAME:.metadata.name,PACKAGE:.spec.package' --no-headers >> "${OUT}"
kubectl get deploymentruntimeconfigs -o name 2>/dev/null >> "${OUT}" || true
kubectl get environmentconfigs.apiextensions.crossplane.io -o name >> "${OUT}"
kubectl get providerconfigs -A -o name 2>/dev/null >> "${OUT}" || true
kubectl get clusterproviderconfigs.upjet-cloudflare.m.upbound.io -o name 2>/dev/null >> "${OUT}" || true
md '```'
md ""

# ---------------------------------------------------------------- CNPG
md "## CNPG databases (move-state via barman backup/restore)"
md ""
md "| Cluster | Namespace | Instances | Ready | Storage | Backup config | Disposition |"
md "|---|---|---|---|---|---|---|"
kubectl get clusters.postgresql.cnpg.io -A -o json > "$T/cnpg.json"
jq -r '.items[] | [
    .metadata.name,
    .metadata.namespace,
    (.spec.instances | tostring),
    (.status.readyInstances // 0 | tostring),
    (.spec.storage.size // "-"),
    (if .spec.backup then "yes" else "NONE" end),
    "move-state"
  ] | "| " + join(" | ") + " |"' "$T/cnpg.json" >> "${OUT}"
md ""

# ---------------------------------------------------------------- Flux
md "## Flux topology (recreate: new cluster entry + rendered repo)"
md ""
md '```'
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A --no-headers >> "${OUT}"
kubectl get gitrepositories.source.toolkit.fluxcd.io -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,URL:.spec.url,BRANCH:.spec.ref.branch' --no-headers >> "${OUT}"
md '```'
md ""

# ---------------------------------------------------------------- Secrets
md "## SOPS-encrypted secrets in repo"
md ""
md '```'
(cd "${REPO}" && git ls-files | grep -iE 'sops|\.enc\.' || echo "(none matched)") >> "${OUT}"
md '```'
md ""

md "## In-cluster Secrets not owned by a controller (manual decisions)"
md ""
md "Excludes helm releases, SA tokens, and secrets owned by cert-manager/ESO/Flux/CNPG/Crossplane."
md ""
md '```'
kubectl get secrets -A -o json > "$T/secrets.json"
jq -r '.items[]
  | select(.type != "helm.sh/release.v1" and .type != "kubernetes.io/service-account-token")
  | select((.metadata.ownerReferences // []) | length == 0)
  | select(.metadata.labels["app.kubernetes.io/managed-by"] // "" | test("Helm") | not)
  | select(.metadata.annotations["cert-manager.io/certificate-name"] // "" == "")
  | select(.metadata.namespace | test("^(kube-|calico|tigera)") | not)
  | "\(.metadata.namespace)/\(.metadata.name) (\(.type))"' "$T/secrets.json" >> "${OUT}"
md '```'
md ""

# ---------------------------------------------------------------- ESO
md "## External Secrets"
md ""
md '```'
kubectl get clustersecretstores.external-secrets.io --no-headers >> "${OUT}"
kubectl get secretstores.external-secrets.io -A --no-headers 2>/dev/null >> "${OUT}" || true
kubectl get externalsecrets.external-secrets.io -A --no-headers >> "${OUT}"
md '```'
md ""

# ---------------------------------------------------------------- DNS
md "## DNS records referencing this cluster"
md ""
md "From in-cluster managed resources (Route53/Cloudflare) plus known platform names."
md ""
md '```'
jq -r '.items[] | select(.kind=="Record" or .kind=="Zone") | "\(.kind): \(.metadata.annotations["crossplane.io/external-name"] // .metadata.name) -> \(.spec.forProvider.name // .spec.forProvider.fqdn // "-") \(.spec.forProvider.type // "") \(.spec.forProvider.records // .spec.forProvider.content // "" | tostring)"' "$T/managed.json" >> "${OUT}"
md '```'
md ""
md "Known platform names (verify at cutover): \`ca.crossplane.rye.ninja\` -> gateway LB $(kubectl get gateway -A -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || echo '?')"
md ""

# ---------------------------------------------------------------- PKI
md "## PKI identity (MUST NOT change in M2)"
md ""
FP=$(kubectl get secret csi-driver-spiffe-ca -n step-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256 | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')
SUBJ=$(kubectl get secret csi-driver-spiffe-ca -n step-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject)
NOTAFTER=$(kubectl get secret csi-driver-spiffe-ca -n step-ca -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate)
md "- Root fingerprint (sha256): \`${FP}\` - disposition: **move-state** (root key material from SOPS)"
md "- Root subject: \`${SUBJ}\`"
md "- Root expiry: \`${NOTAFTER}\`"
md "- Live trust domain: \`$(kubectl get ds -n cert-manager cert-manager-csi-driver-spiffe-driver -o json | jq -r '.spec.template.spec.containers[].args[]?' | grep trust-domain | cut -d= -f2)\` (ADR-16 drift finding; new cluster uses controlplane.rye.ninja)"
md "- ClusterIssuers: $(kubectl get clusterissuers -o name | tr '\n' ' ')"
md ""

# ---------------------------------------------------------------- Headroom
md "## Resource headroom snapshot"
md ""
md '```'
kubectl top nodes 2>/dev/null >> "${OUT}" || md "(metrics unavailable)"
md '```'
md ""
md "Top pod consumers:"
md '```'
kubectl top pods -A --sort-by=memory 2>/dev/null | head -15 >> "${OUT}" || md "(metrics unavailable)"
md '```'
md ""

# ---------------------------------------------------------------- Deps
md "## Workstation and CI dependencies"
md ""
md "- Kubeconfig: \`${KUBECONFIG_RAW}\` (from catalog annotation)"
md "- Rendered repo: \`$(grep 'github.com/project-slug:' "${CATALOG}" | awk '{print $2}')\`"
md "- Source repo filter: \`$(grep 'rye.ninja/flux-source-repo:' "${CATALOG}" | awk '{print $2}')\`"
md ""
md "## Pre-filled dispositions (policy, from the plan)"
md ""
md "- step-ca root key material: **move-state** (fleet trust anchor)"
md "- \`global-network-policy-default-deny/rackspace-spot\` overlay and all \`rackspace-spot\` provider variants: **retire**"
md "- Rackspace Spot LB / gateway addresses: **retire** (replaced by UniFi BGP VIPs)"

echo "wrote ${OUT}"
