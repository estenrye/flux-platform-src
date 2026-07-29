---
name: m4-design
description: M4 design decisions — XKubernetesCluster XRD + talos-kvm composition; KVM capacity squeeze, Terraform-for-VMs + Job-for-bootstrap split, v2-XRD-no-claim-kind convention
metadata:
  type: project
---

M4 design drafted 2026-07-26, kicked off same day as M3 was declared complete.
Full doc: [docs/superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md](../superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md)

**Why:** M4 is the arch plan's next milestone after M3 — build the
`XKubernetesCluster` abstraction so `kubectl apply` of one claim produces a
Flux-synced Talos workload cluster on KVM, using an `observability` cluster
(needed by [[m3-design]]'s downstream M5) as the proving ground. Explicitly
the "pattern-setting milestone for the whole fleet" per
`fable-5-arch-spec.md` §5.3.

**How to apply:** Use this as the M4 kickoff reference, mirroring how
[[m3-design]] anchors M3 work.

## Key confirmed decisions

- **D1 — KVM capacity**: only one physical host (`mf-ms-a2-01`) exists, not
  the arch-plan's assumed 2. Already at 73/64GB RAM overcommit from
  `controlplane` alone. Decision: squeeze the observability cluster's 3x 8GB
  VMs onto the same host (~97/64GB total) rather than wait for a second host
  or shrink sizing. Revisit if the host shows instability.
- **D2 — Bootstrap split**: `provider-terraform`'s controller has no
  `talosctl`/`bao`/`yq`/`jq`, so the genuinely imperative Talos steps
  (schematic-ID lookup, secret gen, machine-config render+patch, network
  apply-config with polling, etcd bootstrap, kubeconfig fetch — today's
  `.bin/create-controlplane-cluster.sh` steps 4–9) can't be plain Terraform
  resources. Decision: **provider-terraform + libvirt provider = VM creation
  only** (generalized port of the existing `talos-vm`/`controlplane` tofu
  modules, no custom provider image); **a separate composed Kubernetes Job**
  (custom image bundling talosctl+bao+yq+jq+curl, close port of the shell
  script's imperative half) does the Talos bootstrap, writing secrets to
  **OpenBao** (not SOPS — runs unattended) and kubeconfig to a Secret. Mirrors
  the existing one-shot-Job pattern (`keycloak-config-cli`,
  Garage's `bucket-init-job.yaml`) rather than fighting Terraform's model
  with `local-exec`.
- **D3 — No separate claim kind**: the arch-spec's illustrative YAML shows a
  distinct `KubernetesCluster` claim kind separate from `XKubernetesCluster`
  — that's the pre-v2 Crossplane pattern. This repo's one existing XRD
  (`XDelegatedHostedZoneAWS`) already uses `apiextensions.crossplane.io/v2`
  and applies the `X`-prefixed kind directly, namespaced, no separate claim
  CRD. Decision: `XKubernetesCluster` is the only kind, applied directly —
  same class of spec-correction as [[m3-design]]'s A4.

## Inherited conventions (not new decisions, just confirmed to still apply)

- Composition style: `Pipeline`-mode, `function-environment-configs` →
  `function-go-templating` (one step per concern, `.observed.resources`
  chains prior steps' output into later ones, `ClaimConditions` for
  validation errors, a gated `status-update` step) → `function-auto-ready`.
  No patch-and-transform, no KCL, anywhere in this repo.
- 4-phase Flux Kustomization `dependsOn` chain ([[crossplane-bootstrap-phasing]])
  governs placement: provider installs → `crossplane-providers`;
  provider-configs → their own subdir under `crossplane-resources`; XRD+Composition
  → `crossplane-xrds`; EnvironmentConfigs + XR instances → `crossplane-resources`.
- ADR-16 trust-domain formula (`<subdomain>.<zoneName>`, surfaced at
  `XDelegatedHostedZoneAWS.status.trustDomain`) is a hard ordering
  dependency the composition must respect before configuring
  cert-manager-spiffe-csi-driver on the new cluster.
- **Correction (2026-07-27, verified against upstream)**: `provider-terraform`
  does *not* persist Workspace state automatically — an earlier draft of
  this assumed it did. `ProviderConfig.spec.configuration` HCL must
  explicitly declare `backend "kubernetes" { in_cluster_config = true, ... }`,
  which means the provider's ServiceAccount needs scoped `Role`/`RoleBinding`
  RBAC on `secrets` in `crossplane-system` (not `cluster-admin`, not
  nothing). `ProviderConfig.spec.credentials[]` materializes named Secret
  keys as files in the Terraform working dir — this is how the KVM SSH
  private key reaches the injected `provider "libvirt" {}` block. See D4 in
  the full design doc for details + two follow-ups (credential file mode,
  `no_verify` host-key skip) and the still-unverified xpkg registry
  path/tag.

## Execution order (8 steps)

1. provider-terraform install + generalized KVM Talos-cluster Terraform
   module + KVM host EnvironmentConfig
2. Talos-bootstrap Job image + script (OpenBao for secrets)
3. `XKubernetesCluster` XRD + `cluster-talos-kvm` Composition
4. `clusters/observability/` baseline layer
5. `observability` claim instance — first real end-to-end provision
6. Chainsaw deletion/teardown test; Usage guards
7. Backstage `catalog.yaml` generation wiring (ADR-18)
8. ADR: XKubernetesCluster fleet abstraction (amends ADR-14)

## New ADRs

- ADR (number TBD): XKubernetesCluster fleet abstraction — amends ADR-14's
  "bootstrap is manual, can't be automated" consequence.
