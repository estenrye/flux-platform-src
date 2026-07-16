# flux-platform-src

Source-of-truth repository for a self-hosted, vendor-agnostic control plane
that manages a fleet of Kubernetes clusters spanning a home lab (KVM, Ubiquiti
Network, TrueNAS Scale) and public cloud (AWS, GCP, Azure, OCI). Everything
here is authored by humans; nothing here is applied directly to a cluster.

## Goals

1. **One control plane, any substrate.** A single Crossplane-based control
   plane provisions, configures, and monitors clusters regardless of where
   they run — on-prem Talos VMs on KVM today, managed cloud Kubernetes
   (EKS/GKE/AKS/OKE) as the fleet grows. Consumers request a cluster via one
   claim shape (`XKubernetesCluster`); vendor differences live inside
   Crossplane compositions, never in a consumer manifest.
2. **No cloud lock-in.** Core services — identity, secrets, observability,
   databases, messaging — are self-hosted in the home lab and integrated
   through interoperable protocols (OIDC, SPIFFE X.509 SVIDs, OTLP, the S3
   API, the PostgreSQL wire protocol, Gateway API, CSI) so any piece can be
   swapped without redesigning the rest. Cloud is used only for substrate the
   home lab can't provide.
3. **GitOps is the only write path.** Humans author changes here; CI renders
   and validates them; Flux applies them. `kubectl apply` is break-glass only.
4. **Zero long-lived credentials.** Cloud access flows through Workload
   Identity Federation, intra-fleet traffic authenticates via SPIFFE mTLS, and
   the only static secrets are a SOPS-encrypted bootstrap set.
5. **The platform documents itself.** Every component and cluster carries a
   Backstage `catalog.yaml`, so fleet topology is queryable rather than
   tribal knowledge — and the same metadata drives CI's cluster discovery.

The full target architecture, guiding principles, and roadmap are written up
in [`docs/superpowers/specs/fable-5-arch-spec.md`](docs/superpowers/specs/fable-5-arch-spec.md)
(plan: [`fable-5-arch-plan.md`](docs/superpowers/specs/fable-5-arch-plan.md));
this README summarizes where that plan stands today.

## How it works

This repo (`flux-platform-src`) is authored by hand: Kustomize bases and
overlays, Helm values, Crossplane compositions, and SOPS-encrypted secrets —
none of which Flux can apply as-is. A companion repo,
`flux-platform-rendered`, holds only plain, lint-validated Kubernetes YAML
that Flux actually watches. Nobody edits the rendered repo by hand.

```mermaid
flowchart LR
    A[Contributor edits applications/ or clusters/] --> B[Pull request]
    B --> C[CI: render with kustomize + helm]
    C --> D[CI: lint with checkov + kube-linter]
    D --> E[CI: push rendered YAML to flux-platform-rendered]
    E --> F[PR on main: auto-merge]
    F --> G[Flux reconciles the cluster]
```

- **Author here.** [`applications/<name>/`](applications/) holds one
  component per directory (an operator, a CRD set, a Crossplane provider),
  each with a `base/` overlay plus optional provider variants and a
  `catalog.yaml`. [`clusters/<name>/kustomization.yaml`](clusters/) is the
  single aggregation point that decides which applications land on which
  cluster.
- **CI renders and gates.** `make render` runs Kustomize/Helm for every
  cluster discovered from `clusters/*/catalog.yaml`; `make lint` runs Checkov
  and kube-linter against the rendered output. A failing gate blocks delivery
  to every cluster, not just the one that changed.
- **Delivery is per-cluster.** Each cluster's rendered manifests go to its own
  target repository (`github.com/project-slug` in its `catalog.yaml`) via a
  dedicated GitHub App — no personal access tokens, no shared write scope.
- **Flux does the applying.** Each cluster runs Flux, watching only its own
  rendered repository. `kubectl apply` is reserved for break-glass recovery.

See [ADR-0008](docs/adr/0008-source-vs-rendered-repository-pattern.md)
(source vs. rendered), [ADR-0009](docs/adr/0009-cicd-pipeline-architecture.md)
(the CI pipeline), and
[ADR-0010](docs/adr/0010-gitops-layering-and-kustomize-composition-strategy.md)
(directory layout and composition) for the full decisions behind this flow.

## Fleet topology

Three cluster roles, per the
[Fable 5 architecture spec](docs/superpowers/specs/fable-5-arch-spec.md):

| Role | Purpose | Status |
|---|---|---|
| **Control plane** (`controlplane`) | Crossplane, Flux, step-ca (trust domain root), Keycloak, OpenBao, Garage, Backstage. The only cluster with cloud-mutation credentials. Runs as an IPv6-only Talos-on-KVM cluster in the home lab — a script-bootstrapped pet, not self-managed by Crossplane. | Live (M1 complete — see [status](docs/memory/m1-implementation-status.md)) |
| **Observability** | LGTM stack, Garage gateway, Dispatch — isolated so control plane and observability failures aren't correlated. | Planned |
| **Workload clusters** | Tenant applications plus a thin platform baseline (Flux, cert-manager+SPIFFE, Calico, OTel, ESO). Never run Crossplane. | Planned (fleet expansion after control plane migration) |

The control plane was originally bootstrapped on Rackspace Spot
([ADR-0003](docs/adr/0003-bootstrapping-the-crossplane-controlplane-cluster.md))
and is migrating to the home lab for reliability
([ADR-0020](docs/adr/0020-control-plane-on-talos-on-kvm.md),
[ADR-0021](docs/adr/0021-on-prem-substrate-talos-truenas-csi-zfs.md)); Spot
retires once the migration completes.

## Repository layout

| Path | Contents |
|---|---|
| [`applications/`](applications/) | One directory per platform component (operators, CRDs, Crossplane providers, networking, PKI, storage), each with a `base/` overlay and `catalog.yaml` |
| [`clusters/`](clusters/) | One directory per cluster: its `kustomization.yaml` (aggregates applications), `catalog.yaml` (Backstage `System` + CI discovery), SOPS rules, and cluster-specific resources |
| [`providers/`](providers/) | Infrastructure-as-code for substrates the control plane doesn't yet manage itself — currently OpenTofu + libvirt for the home lab KVM host(s) |
| [`docs/adr/`](docs/adr/) | Architecture Decision Records — the durable "why" behind the platform |
| [`docs/runbooks/`](docs/runbooks/) | Operational procedures (DR restore, key rotation, node replacement, upgrades) |
| [`docs/superpowers/specs/`](docs/superpowers/specs/) and [`docs/superpowers/plans/`](docs/superpowers/plans/) | Design docs and implementation plans for specific pieces of work |
| [`docs/migration/`](docs/migration/) | In-flight migration inventories |
| [`docs/memory/`](docs/memory/) | Working notes on project state, gotchas, and open decisions ([index](docs/memory/MEMORY.md)) |
| [`tests/`](tests/) | Chainsaw contract test suites that verify a cluster meets its baseline (network, storage, load balancing, Flux health) |
| [`.bin/`](.bin/) | Scripts: cluster create/destroy, DR backup/restore, render, lint, bootstrap |

## Getting started

```sh
make render-deps   # install kustomize, adr-tools, etc.
make render        # render all discovered clusters to .render/
make lint           # render + checkov + kube-linter
make push-pr        # push rendered output as a PR to each cluster's rendered repo
```

`.bin/create-controlplane-cluster.sh` and `.bin/destroy-controlplane-cluster.sh`
provision and tear down the home lab control plane cluster itself (see
[`providers/kvm/README.md`](providers/kvm/README.md)); this is infrastructure
bootstrap, separate from the GitOps flow above.

## Key documents

- [ADR index](docs/adr/) — start with
  [ADR-0008](docs/adr/0008-source-vs-rendered-repository-pattern.md),
  [ADR-0009](docs/adr/0009-cicd-pipeline-architecture.md), and
  [ADR-0010](docs/adr/0010-gitops-layering-and-kustomize-composition-strategy.md)
  for the delivery mechanics, then
  [ADR-0018](docs/adr/0018-backstage-catalog-as-platform-topology-source-of-truth.md)
  for how the fleet is cataloged.
- [Fable 5 architecture spec](docs/superpowers/specs/fable-5-arch-spec.md) and
  [plan](docs/superpowers/specs/fable-5-arch-plan.md) — the target
  architecture and roadmap this repo is converging toward.
- [M1 implementation status](docs/memory/m1-implementation-status.md) — where
  the current home lab migration stands.
- [Runbooks](docs/runbooks/) — what to do when something breaks.
- [Project memory index](docs/memory/MEMORY.md) — working notes that don't
  belong in an ADR (gotchas, open decisions, in-flight state).
