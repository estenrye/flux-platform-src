# M4 Design: XKubernetesCluster XRD + talos-kvm Composition

Date: 2026-07-26
Status: Draft — step 1 approved and in progress; steps 2+ scoped in detail as reached
Companion: [fable-5-arch-plan.md](fable-5-arch-plan.md) §M4,
           [fable-5-arch-spec.md](fable-5-arch-spec.md) §5

## 1. Goal

`kubectl apply` of one `XKubernetesCluster` claim produces a fully
registered, Flux-synced Talos workload cluster on KVM. The `observability`
cluster (needed by M5) is the proving ground. Per the arch spec, this is
explicitly the pattern-setting milestone for the whole fleet — every later
substrate (EKS/GKE/AKS/OKE, M6+) reuses this same XRD contract.

Today, provisioning a workload cluster is entirely imperative:
`.bin/create-controlplane-cluster.sh` + `.bin/deploy-cluster.sh` + three
`.bin/bootstrap-cluster-*.sh` scripts, run by hand (ADR-14). ADR-14's own
"Consequences" section states this "cannot be fully automated yet because
Flux bootstrap requires interactive credential handling and the SPIFFE trust
domain must be configured before cert-manager deploys." Closing that gap is
M4's job.

Nothing under `applications/crossplane-providers/` or
`applications/crossplane-resources/` related to Terraform or Talos exists
yet — this is greenfield work, not an extension of something already
scaffolded.

## 2. Confirmed decisions

### D1 — KVM capacity: squeeze onto the single existing host

The arch-plan's capacity table (`fable-5-arch-plan.md` §"Sizing") assumes 2
KVM hosts (64GB RAM each) by M4. Only one exists today (`mf-ms-a2-01`),
already running the `controlplane` cluster at 73/64GB RAM overcommit
(`providers/kvm/README.md`). The observability cluster's 3x 8GB VMs push
total commitment to ~97/64GB.

**Decision (2026-07-26)**: proceed on the single host rather than wait for a
second host or shrink observability's sizing. Revisit if the host shows
memory-pressure instability. ARC is already capped at 8GiB and ballooning is
on; `worker_memory_mb` has a documented fallback to 12288 if needed for the
*controlplane* cluster, but no equivalent lever exists yet for observability
— add one if pressure appears.

### D2 — Bootstrap split: Terraform for VMs, a Job for Talos bootstrap

`provider-terraform`'s controller container ships plain `terraform`/`tofu`
only — no `talosctl`, `bao`, `yq`, `jq`. The genuinely imperative Talos steps
in today's `create-controlplane-cluster.sh` (schematic-ID lookup via the
Talos image factory, machine-secret generation, machine-config render +
per-node patch, applying configs over the network with polling/retry, etcd
bootstrap, kubeconfig fetch — steps 4–9 of that script) don't map onto plain
Terraform resources; they're a stateful, retrying, polling shell sequence.

**Decision (2026-07-26)**: split responsibility instead of forcing
everything into one Terraform apply via `local-exec` in a custom provider
image:

- **`provider-terraform` + the existing `dmacvicar/libvirt` provider**:
  VM lifecycle only — a generalized version of the existing
  `talos-vm`/`controlplane` tofu modules creates the empty zvols + libvirt
  domains and boots the Talos factory ISO. No custom provider image needed;
  this is a close, parameterized port of what already runs in production.
- **A composed Kubernetes `Job`**: does the actual Talos bootstrap. Runs a
  purpose-built image bundling `talosctl` (version-pinned to match the
  cluster, per the existing "wrong `talosctl` on PATH silently
  mis-decodes machine config" gotcha in
  [[m3-step-tracker]]), `bao`, `yq`, `jq`, `curl`. The script is a close port
  of `create-controlplane-cluster.sh`'s imperative half, parameterized by
  the claim's node topology and network allocation. Writes Talos machine
  secrets to **OpenBao** (not SOPS — this runs unattended in-cluster; there's
  no workstation to hold a SOPS age key), and the resulting kubeconfig to a
  Kubernetes Secret (the contract's "connection secret," §5.2 item 3).

This mirrors the repo's existing one-shot-imperative-Job pattern
(`keycloak-config-cli`, Garage's `bucket-init-job.yaml`) rather than fighting
Terraform's declarative/idempotent-apply model with `local-exec`
provisioners wrapping a retry loop, and avoids building and maintaining a
custom Crossplane provider OCI image.

### D3 — `XKubernetesCluster` is a v2 XRD applied directly; no separate claim kind

The arch-spec's illustrative YAML (§5.1) shows a distinct claim kind
(`kind: KubernetesCluster`) separate from the XRD's own kind
(`XKubernetesCluster`) — the "classic" pre-v2 Crossplane claim pattern. That
predates this repo's actual convention: the one existing XRD
(`XDelegatedHostedZoneAWS`, `applications/crossplane-resources/
delegated-hosted-zone-aws/xrd.yaml`) uses `apiextensions.crossplane.io/v2`,
and its example (`examples/example-claim.yaml`) applies the `X`-prefixed
kind directly, namespaced — v2 XRDs merge the XR/claim UX, no separate claim
CRD.

**Decision**: follow the established repo convention. `XKubernetesCluster`
is the only kind; it's applied directly as a namespaced XR. This is a
deliberate, documented correction to the spec's illustrative YAML, same
class of fix as [[m3-design]]'s A4 correction.

### D4 — `provider-terraform` facts, verified against upstream (correction to this doc's earlier draft)

Verified live against `crossplane-contrib/provider-terraform`'s
`examples/cluster/` (GitHub, 2026-07-27), since getting these wrong would
silently break Step 3's Workspace:

- **State is not persisted automatically.** An earlier draft of this doc
  assumed `provider-terraform` persists Workspace state as a Kubernetes
  Secret on its own — wrong. `ProviderConfig.spec.configuration` (HCL,
  injected into every `Workspace` using that `ProviderConfig`) must
  explicitly declare `terraform { backend "kubernetes" { in_cluster_config
  = true, namespace = "crossplane-system", secret_suffix = "<name>" } }`.
  Without it, state defaults to local and is lost on every controller pod
  restart. Consequence: the `provider-terraform` ServiceAccount needs scoped
  RBAC (`Role`+`RoleBinding` on `secrets` in `crossplane-system`) — not
  `cluster-admin`, and not nothing either.
- **`ProviderConfig.spec.credentials[]`** (apiVersion `tf.upbound.io/v1beta1`):
  each entry (`{filename, source: Secret, secretRef: {namespace, name,
  key}}`) is materialized as a file in the Terraform working directory,
  referenced by bare filename from the injected `configuration` HCL (e.g.
  `credentials = "gcp-credentials.json"` in upstream's Google example).
  This is the mechanism for the KVM SSH private key: `filename:
  kvm-ssh-key`, and `configuration` sets `provider "libvirt" { uri =
  "qemu+ssh://automation-user@<host>/system?keyfile=kvm-ssh-key&no_verify=1"
  }`. Two known follow-ups, not blocking step 1: (a) unverified whether
  provider-terraform writes credential files at a mode SSH's client will
  accept (0600) — check when step 3's Workspace is first live-tested; (b)
  `no_verify=1` skips libvirt's own SSH host-key check, acceptable for now,
  a pinned `known_hosts` would be tighter.
- **Real bug caught before merge, during step 1's own render/lint check**:
  an earlier draft put `terraform { backend "kubernetes" { secret_suffix =
  "provider-terraform-default", ... } }` in the shared `ProviderConfig`'s
  `configuration`. Since `configuration` is static text merged into
  *every* `Workspace` using that `ProviderConfig` (every cluster, until
  there's a reason to split), a single hardcoded `secret_suffix` would
  make every future cluster's Terraform state collide on the same
  Kubernetes Secret name — the second `Workspace` created (step 3+) would
  silently share, and likely corrupt, the first's state. Fixed by removing
  the backend block from the shared `configuration` entirely; each
  cluster's own `Workspace` (step 3) must declare its own `backend
  "kubernetes"` block with a `secret_suffix` derived from the claim (e.g.
  the cluster name) inside its own module content instead.
- **Frozen at Terraform 1.5.7** (pre-BSL; upstream explicitly won't adopt
  newer Terraform releases, pointing at `provider-opentofu` instead).
  `check` blocks (used by the existing `providers/kvm/controlplane` module)
  landed in Terraform 1.5.0, so that's compatible — but the new generalized
  module (§7) must not use any HCL feature newer than 1.5.7, narrower than
  the `>= 1.8.0` OpenTofu the workstation-run `providers/kvm/controlplane`
  module requires today.
- **Package reference unverified**: pinning
  `xpkg.crossplane.io/crossplane-contrib/provider-terraform:v1.1.1` (latest
  GitHub release, matching this repo's registry-host convention for every
  other `crossplane-contrib/*` package already installed) — but the
  registry endpoint returned `401 UNAUTHORIZED` rather than a listable tag
  set when probed unauthenticated, so this exact path/tag combination is
  **not yet confirmed to resolve**. Verify with `crossplane xpkg` or a live
  `kubectl describe provider` before treating step 1 as mergeable.

## 3. Composition style (inherited convention, not a new decision)

The only existing composition in this repo (`delegated-hosted-zone-aws/
composition.yaml`) is a `Pipeline`-mode `Composition` built entirely from:

1. `function-environment-configs` — always first; merges referenced
   `EnvironmentConfig` data into the pipeline context.
2. `function-go-templating` — one step per concern; reads
   `.observed.composite.resource.spec.*` for claim inputs, falls back to
   `$environment.*`; reads `.observed.resources` on later reconciles to pull
   prior steps' composed-resource status (e.g. an ARN, a nameserver list)
   forward into the next step's template; emits `meta.gotemplating.fn
   .crossplane.io/v1alpha1 kind: ClaimConditions` for validation failures
   surfaced on the claim itself; a final `status-update` step writes
   `XR.status` fields, gated on all required values being present.
3. `function-auto-ready` — last step, no input; marks the XR `Ready` once
   composed resources report ready.

No `function-patch-and-transform`, no KCL exist anywhere in this repo.
`cluster-talos-kvm` (step 3) follows this exact style — same three function
types, same `.observed.resources`-chaining technique to thread a
`provider-terraform` `Workspace`'s outputs (VM MACs/ULAs) into the
Talos-bootstrap `Job`'s spec, and the bootstrap `Job`'s resulting kubeconfig
Secret into the remote-cluster `provider-kubernetes` `ProviderConfig`.

## 4. Bootstrap-chain plumbing (inherited convention)

The 4-phase Flux `Kustomization` `dependsOn` chain (`crossplane-core` →
`crossplane-providers` → `crossplane-xrds` → `crossplane-resources`,
documented in [[crossplane-bootstrap-phasing]]) governs where every new
piece lands:

- `provider-terraform` install → `clusters/controlplane/crossplane-providers/`
- its `ProviderConfig` (libvirt SSH credential) → a `provider-config/`
  subdirectory referenced only from `crossplane-resources`
- `XKubernetesCluster` XRD + `cluster-talos-kvm` Composition →
  `clusters/controlplane/crossplane-xrds/`
- the KVM-host `EnvironmentConfig` and the `observability` cluster's XR
  instance → `clusters/controlplane/crossplane-resources/`

Existing gotchas that apply unchanged: kustomize's load-restrictor forces
every provider-config into its own subdirectory with its own
`kustomization.yaml` (bare cross-tree file references are blocked);
`postBuild.substituteFrom` in `crossplane-resources`/`crossplane-providers`
will try to expand any literal `${...}` text, including in XRD prose
descriptions if they lived in a `substituteFrom`-enabled Kustomization (they
don't — XRDs live in `crossplane-xrds`, which has none); every new
`kustomization.yaml` directory needs a sibling `catalog.yaml`.

`provider-kubernetes` today only has an `InjectedIdentity` `ProviderConfig`
(manages the control-plane cluster itself). A `credentials.source: Secret`
variant, pointed at a remote cluster's own kubeconfig, doesn't exist as a
pattern yet — step 3 introduces it.

## 5. Trust domain and DNS delegation (inherited convention, hard ordering dependency)

ADR-16's formula: `trustDomain = <spec.subdomain>.<resolvedZoneName>`,
surfaced at `XDelegatedHostedZoneAWS.status.trustDomain` once that claim
reconciles. The `cluster-talos-kvm` composition must create/reference an
`XDelegatedHostedZoneAWS` claim (reusing the existing XRD as-is — no changes
needed there) and read its status back via the same `.observed.resources`
pattern *before* it can hand a trust domain to the new cluster's
`cert-manager-spiffe-csi-driver` Helm values. `otlp.obs.rye.ninja` (used by
M5) implies `subdomain: obs` for the observability cluster, consistent with
the existing `subdomain: controlplane`/`subdomain: crossplane` claims.

## 6. Workload-cluster baseline

No shared "workload cluster baseline" kustomize base exists yet — every
baseline app is listed directly in `clusters/controlplane/kustomization.yaml`
today. `clusters/observability/kustomization.yaml` (step 4) will be a new
file mixing in the portable `applications/*/base` directories:

**Included** (core baseline, replicated on any workload cluster): Calico +
default-deny, priority-classes, reloader, gateway/envoy CRDs (if ingress
needed), external-dns, storage (democratic-csi), Flux itself + flux
monitoring, ESO (pointed at OpenBao on `controlplane`), cert-manager +
approver-policy + trust-manager + spiffe-issuer + spiffe-csi-driver (**with
the cluster's own trust domain**, per §5 above — not `controlplane.rye.ninja`),
Pinniped **Concierge only**.

**Excluded** (controlplane-only, per ADR-14 — workload clusters don't run
these, they're clients of the control plane's copy): step-ca(-db), OpenBao(-db),
Keycloak(-db), Pinniped **Supervisor**, Garage, the entire Crossplane stack
(`crossplane-core/providers/xrds/resources` and its 4-phase Kustomization
chain — workload clusters are *registered with* the control plane's
Crossplane via an `XDelegatedHostedZoneAWS` claim, they don't run their own).

## 7. Terraform module generalization

`providers/kvm/controlplane/` is a hand-rolled root module specific to one
cluster (reads `../hosts.yaml`/`../network.yaml` directly, hard-codes 3 CP +
3 worker `for_each` sourced from those files). `XKubernetesCluster` needs a
single reusable module any future `talos-kvm` claim can instantiate — no new
hand-authored `.tf` directory per cluster, which would defeat the "one
`kubectl apply`" goal.

**Decision**: new `providers/kvm/modules/talos-cluster/`, parameterized by
cluster name, node-pool spec (CP/worker counts + sizes), a KVM host list
(passed as a variable — sourced from a new `crossplane-kvm-hosts`
`EnvironmentConfig` at the composition layer, not a static `hosts.yaml`
read, so multiple clusters share one host inventory), and network parameters
(ULA infra subnet, pod/service CIDRs, BGP ASN, apiserver VIP). The leaf
module `providers/kvm/modules/talos-vm/` is unchanged — it's already
generic (fixed MAC/CPU/RAM/disk in, VM out, no IPv6 knowledge).

`providers/kvm/controlplane/` itself is left as-is — the control plane
cluster is the spec's stated exception ("script-bootstrapped, not
claim-managed," §5.3) and is not migrated onto the new module. No behavior
change to the live cluster.

Per-cluster network allocation (subnet/ASN/VIP, distinct per claim) is
deferred to step 3 when the composition that calls this module is built —
not needed for step 1's scaffolding.

## 8. Execution order

1. **DONE 2026-07-28** — provider-terraform install + generalized KVM
   Talos-cluster Terraform module + KVM host EnvironmentConfig. Verified
   live: the OpenBao kv round-trip for the KVM SSH key.
2. **Shipped 2026-07-28, not yet live-tested** — Talos-bootstrap Job image
   + script (OpenBao instead of SOPS for secrets). Discovered mid-step:
   `images/docker/crossplane-extra-bin-init/` already establishes a
   working pattern for building and publishing a custom image (Dockerfile
   + `catalog.yaml` in `images/docker/<name>/`, a path-filtered GH Actions
   workflow calling the reusable `estenrye/.github/.github/workflows/
   docker-multiarch-slsa-releaser.yml`, private GHCR package) — reused
   directly rather than inventing a new build/publish mechanism. See
   [[m4-step-tracker]] for the full detail, including two real bugs caught
   by actually building the image (not just reading the Dockerfile back).
3. `XKubernetesCluster` XRD + `cluster-talos-kvm` Composition wiring 1–2
   together, plus DNS delegation, connection secret, remote-cluster
   `provider-kubernetes` `ProviderConfig`, Flux bootstrap push,
   `service-account-issuer` + JWKS-mirror CronJob to Garage
4. `clusters/observability/` baseline layer
5. `observability` `XKubernetesCluster` claim instance — first real
   end-to-end provision
6. Chainsaw deletion/teardown test on a throwaway claim; Usage guards
7. Backstage `catalog.yaml` generation wiring for claimed clusters (ADR-18)
8. ADR: XKubernetesCluster fleet abstraction; supersede/amend ADR-14's
   "manual, can't be automated" consequence

Open `[H]` decisions surface as each step is reached, same iterative pattern
M3 used — see [[m4-step-tracker]] for live status.

## 9. New ADRs

- ADR (number TBD at step 8): XKubernetesCluster fleet abstraction —
  supersedes/amends ADR-14's bootstrap-is-manual consequence.
