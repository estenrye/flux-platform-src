# xkubernetescluster

## References

- [Crossplane Compositions (Pipeline mode)](https://docs.crossplane.io/latest/concepts/compositions/)
- [docs/superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md](../../../docs/superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md) — full M4 design, decisions D1-D4
- [docs/memory/m4-design.md](../../../docs/memory/m4-design.md), [docs/memory/m4-step-tracker.md](../../../docs/memory/m4-step-tracker.md)
- [fable-5-arch-spec.md §5](../../../docs/superpowers/specs/fable-5-arch-spec.md)

## Objective

One claim, one running Talos-on-KVM cluster. `kubectl apply` an `XKubernetesCluster` and get back a real, reachable cluster with its DNS delegation and SPIFFE trust domain registered, and a kubeconfig/talosconfig Secret on `controlplane` — the pattern-setting abstraction every later substrate (EKS/GKE/AKS/OKE) will reuse.

## Design decisions

- **No separate claim kind.** `apiextensions.crossplane.io/v2`, `XKubernetesCluster` applied directly, namespaced — same convention as `delegated-hosted-zone-aws`, a deliberate correction to the arch-spec's illustrative (pre-v2) YAML.
- **Terraform for VMs, a Job for Talos bootstrap.** `provider-terraform`'s controller has no `talosctl`/`bao`/`yq`/`jq`, so VM creation (via the `talos-cluster` module) and the actually-imperative Talos bootstrap (schematic lookup, machine secrets, machine-config apply, etcd bootstrap, kubeconfig fetch — `images/docker/talos-cluster-bootstrap`) are split, not forced into one Terraform apply.
- **`Workspace.spec.forProvider.source: Inline`, not `Remote`.** `flux-platform-src` is private; a git-sourced Workspace would need its own unproven git-clone credential wired into `provider-terraform`. The Composition embeds `providers/kvm/modules/talos-cluster`'s current `.tf` content directly — **keep the embedded copy and the real module in sync by hand**; this is a known, accepted drift risk, not an oversight.
- **Network allocation is hand-curated**, not derived. `platform-kvm-network` (an `EnvironmentConfig`, alongside `platform-kvm-hosts`) maps each claimed cluster's name to its subnet/VIP/ASN/node-ULA maps — same philosophy as `providers/kvm/network.yaml` for `controlplane`. A claim whose name has no entry fails validation with a readable `ClaimConditions` message rather than guessing.
- **Narrow scope (M4 step 3).** This Composition gets a claim from nothing to a running, reachable cluster with a connection secret. It does **not** push Flux onto the new cluster (a brand-new remote `provider-kubernetes` pattern with no existing precedent in this repo — deferred to step 3b), register a GitHub rendered repo or deploy key (step 3b/3c — mechanically automatable later via the existing `provider-github` GitHub App credential), or expose a public JWKS/OIDC mirror (step 3c).

## API specification

See `xrd.yaml` for the full OpenAPI schema and field-level docs. Summary:

| Field | Description |
|---|---|
| `spec.subdomain` | Required. Drives DNS delegation and the SPIFFE trust domain; also the lookup key into `platform-kvm-network`. |
| `spec.controlPlane.{count,vcpu,memoryMb,diskSizeGb}` | Control-plane node pool. `count` defaults to 3. |
| `spec.workers.{count,vcpu,memoryMb,diskSizeGb}` | Worker node pool. `count` may be 0 — Talos supports control-plane-only scheduling. |
| `spec.talosVersion` / `spec.kubernetesVersion` | Optional; default to the fleet's current pins. |
| `status.trustDomain` / `status.nameServers` | From the composed `XDelegatedHostedZoneAWS` claim. |
| `status.kubeconfigSecretRef` / `status.talosconfigSecretRef` | Where the bootstrap Job's output landed on `controlplane`. |
| `status.phase` | `PendingNetworkAllocation` → `Bootstrapping` → `Ready`, coarse-grained progress for `kubectl get`. |

## Deployment logic

`cluster-talos-kvm`'s pipeline (see `composition.yaml`), in order:

| Step | Produces / does |
|---|---|
| `environmentConfigs` | Merges `platform-kvm-hosts` + `platform-kvm-network` into pipeline context. |
| `validate-network-allocation` | `ClaimConditions` error if this claim's name has no `platform-kvm-network` entry. |
| `create-dns-delegation` | Composes an `XDelegatedHostedZoneAWS` XR (reused as-is) for `spec.subdomain`. |
| `create-workspace` | Composes a `provider-terraform` `Workspace` (`source: Inline`) — creates the cluster's VMs. |
| `create-bootstrap-job` | Composes a `provider-kubernetes` `Object` wrapping a `batch/v1 Job` (the `talos-cluster-bootstrap` image) — bootstraps Talos, writes the connection Secrets. |
| `status-update` | Writes `trustDomain`/`nameServers`/`kubeconfigSecretRef`/`talosconfigSecretRef`/`phase` back onto the XR, gated on upstream steps actually having resolved. |
| `auto-ready` | Marks the XR `Ready` once composed resources report ready. |

## Known unverified items (flag before treating this composition as proven)

Several pieces of this pipeline use Crossplane/provider APIs with no existing precedent anywhere in this repo, and could not be exercised against a live reconcile in the session that wrote them (no real claim has been created yet — that's step 5). Each is documented at its point of use in `composition.yaml`, and summarized in `docs/memory/m4-step-tracker.md`:

- The exact `apiVersion` for `provider-kubernetes`'s `Object` resource (`kubernetes.crossplane.io/v1alpha2`).
- The exact field name for a CEL query under `readiness.policy: DeriveFromCelQuery`.
- `function-go-templating`'s Sprig function availability (`dict`, `toJson`, `append`, `mul`, `quote`) — inferred from `list`/`default` already being used successfully in `delegated-hosted-zone-aws/composition.yaml`, not independently confirmed for the others.

The embedded Terraform module text **was** independently validated (`tofu validate` + a real `tofu plan` against `factory.talos.dev`, extracted into a scratch directory) and produces output identical to the real `providers/kvm/modules/talos-cluster` module.
