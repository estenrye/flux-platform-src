---
name: m4-step-tracker
description: M4 step tracker — steps 1-3 merged to main (XRD + Composition, narrowed to core provisioning); state-backend gap found and fixed same-day, 2026-07-31; step 5 (real claim) next
metadata:
  type: project
---

Tracks [[m4-design]]'s 8-step execution order. Update as steps complete —
this decays fast, keep it current rather than trusting it blindly.

## Status as of 2026-07-31

| # | Step | Status |
|---|---|---|
| 1 | provider-terraform install + generalized `talos-cluster` tofu module + `crossplane-kvm-hosts` EnvironmentConfig | **Done, merged to main** — bootstrap script run by the user, OpenBao `kv get` on `provider-terraform/kvm-ssh-key` confirmed working; package reference corrected to `xpkg.upbound.io/upbound/provider-terraform:v1.1.6`; a live NetworkPolicy crash-loop bug found and fixed post-merge (PR #133) — `provider-terraform` confirmed `Running`/`Healthy=True` |
| 2 | Talos-bootstrap Job image + script (OpenBao for secrets) | **Shipped, merged to main**; OpenBao policy/role live-configured; image built+pushed to GHCR via CI; no real cluster bootstrap attempted yet (no Job template existed until step 3) |
| 3 | `XKubernetesCluster` XRD + `cluster-talos-kvm` Composition (core provisioning; Flux-push/GitHub-automation/JWKS-mirror split out to 3b/3c) | **Merged to main (PR #134)** — `make render`/kube-linter/checkov/trust-domain all clean; embedded Terraform module independently validated; per-cluster state backend gap found and fixed same day (below). Several Crossplane/provider API details used are still unverified against a live reconcile (see detail below) |
| 4 | `clusters/observability/` baseline layer | Not started |
| 5 | `observability` claim instance — first end-to-end provision | Not started |
| 6 | Chainsaw deletion/teardown test; Usage guards | Not started |
| 7 | Backstage `catalog.yaml` generation wiring (ADR-18) | Not started |
| 8 | ADR: XKubernetesCluster fleet abstraction (amends ADR-14) | Not started |

### Step 1 detail — DONE 2026-07-28

Scaffolding only — no live `provider-terraform` install applied yet (needs
explicit user go-ahead before merge/apply, since it's a new cluster-admin-adjacent
controller, same diligence as any new Crossplane provider). No VM created.

**Verification note**: this session (running inside a VS Code extension
host, not a plain terminal) had no working path to `op` — no TTY, and
1Password's desktop-CLI-integration doesn't authorize a caller in that
shape, confirmed by directly checking (`op whoami`/`op account list`/env
`OP_SESSION_*`) rather than assuming. The user ran
`.bin/bootstrap-provider-terraform-kvm-key.sh` themselves and confirmed via
a corrected `kubectl exec ... bao kv get` (the first version suggested had
a real bug: `$(op read ...)` nested inside a single-quoted `kubectl exec
... -- sh -c '...'` string tries to run `op` *inside the exec'd container*,
which doesn't have it — fixed by resolving the token in the local shell
first, matching the pattern the bootstrap script itself already uses:
heredoc piped to `kubectl exec -i`, not `-c '...'`).

**Shipped so far**: design doc + memory; `providers/kvm/modules/talos-cluster/`
(generalized port of `providers/kvm/controlplane`'s VM-provisioning half,
`tofu validate` clean); `applications/crossplane-providers/provider-terraform/`
install (Provider, DeploymentRuntimeConfig, NetworkPolicy, scoped
Role/RoleBinding for the Terraform state backend, ProviderConfig);
`.bin/bootstrap-provider-terraform-kvm-key.sh` (new dedicated SSH keypair,
not the human operator's own interactive key) + OpenBao/ESO wiring;
`platform-kvm-hosts` EnvironmentConfig; wired into
`clusters/controlplane/crossplane-providers` and `crossplane-resources`.
`make render` + `make lint-kube-linter` + checkov all clean.

**Real bug caught during this step's own lint pass, not guessed**: an
earlier draft of the `ProviderConfig` put a `terraform { backend
"kubernetes" { secret_suffix = "provider-terraform-default" } }` block in
`configuration` (shared text, merged into every `Workspace`). Every future
cluster's `Workspace` would have collided on the same state Secret name.
Fixed by dropping the backend block from the shared config — each
cluster's own `Workspace` (step 3) must declare its own uniquely-suffixed
backend. See [[m4-design]] D4.

**kube-linter/checkov findings, both suppressed with a rationale
annotation (not silenced blind)**: the state-backend `Role`/`RoleBinding`
grants `secrets` access in `crossplane-system` with no `resourceNames`,
since Terraform-managed state Secret names aren't known until a `Workspace`
actually reconciles. Same annotation pattern already established by
`step-ca-cert-reader`/`trust-manager`/`envoy-gateway` in this repo
(`ignore-check.kube-linter.io/access-to-secrets` +
`checkov.io/skip1: "CKV2_K8S_5=..."`, both on the `RoleBinding`).

**RESOLVED 2026-07-29**: the `provider-terraform` package reference was
corrected at the user's direction to
`xpkg.upbound.io/upbound/provider-terraform:v1.1.6` (the original
`xpkg.crossplane.io/crossplane-contrib/...:v1.1.1` guess was never
confirmed to resolve — that registry returned `401` unauthenticated).
Confirmed live: `https://marketplace.upbound.io/providers/upbound/provider-terraform/v1.1.6`
returns `200`. Note the registry/org is `upbound`, not `crossplane-contrib`
— a deliberate exception to this repo's usual registry-host convention.

**Still genuinely unverified**: the `authorized_keys` entry on
`mf-ms-a2-01` wasn't independently re-checked (only the OpenBao side was
confirmed) — low risk, same script writes both atomically, but worth a
glance before step 3 tries to actually use the key.

### Step 2 detail — shipped 2026-07-28, not yet live-tested

**What shipped**: `images/docker/talos-cluster-bootstrap/` (Dockerfile +
`bootstrap.sh` + catalog.yaml) and `.github/workflows/
build-talos-cluster-bootstrap.yml`, following the exact pattern already
established by `images/docker/crossplane-extra-bin-init/` (found mid-step
— useful prior art that wasn't known about when M4's design doc was first
drafted: this repo already has a real, working `docker-multiarch-slsa-releaser`
reusable GH Actions workflow that builds and pushes to a private GHCR
package). Also `applications/talos-cluster-bootstrap/base/` (fixed
ServiceAccount/Role/RoleBinding/NetworkPolicy identity for the Job, wired
into `clusters/controlplane/crossplane-providers/kustomization.yaml` --
NOT the plain baseline list, since it targets `crossplane-system`, which
`crossplane-core` creates; matches provider-terraform's own placement) and
`.bin/configure-openbao-talos-cluster-bootstrap-secrets.sh` (OpenBao
policy/role for that fixed ServiceAccount, write access this time --
mirrors step 1's SSH-key script but the Job needs `create`, not just
`read`, since it generates a cluster's machine secrets on first bootstrap).

`bootstrap.sh` is a close, deliberately-unrewritten port of
`.bin/create-controlplane-cluster.sh`'s steps 1-4 and 6-7 (schematic ID,
machine secrets, machine-config render, apply-config-in-maintenance-mode
polling loop, etcd-bootstrap retry loop, kubeconfig fetch) -- step 5 (`tofu
apply`, VM creation) is intentionally absent, since that already happened
via `provider-terraform` before this Job runs. Every YAML-file read in the
original became an env var; SOPS became OpenBao (`bao kv get`/`kv put`,
authenticated via the Job's own `auth/kubernetes/login`, not a static
token); the local kubeconfig/talosconfig file writes became `kubectl
create secret ... | kubectl apply -f -` against controlplane's own
apiserver (the Job runs in-cluster, not on a workstation). Node input is a
single `NODES_JSON` env var shaped exactly like the `talos-cluster`
Terraform module's own `nodes` output (`{name: {role, ula, mac}}`) so step
3's composition can pass it through with minimal reshaping.

**Real bugs caught by actually building/running it, not just reading it
back**:
1. The Dockerfile originally downloaded `talosctl`/`jq`/`openbao` with `curl
   -o <renamed-name>` *before* checksum verification, but each project's
   checksum file lists the *original* release filename -- `sha256sum -c`
   then fails with "No such file" against the renamed local file. Fixed by
   downloading with `-O` (original name preserved) and renaming only after
   verification passes. Caught by `docker build --target fetch`, not
   inspection -- the first build attempt failed exactly this way.
2. `mikefarah/yq`'s release `checksums` file is a multi-algorithm CSV
   (CRC32/MD4/MD5/SHA1/.../SHA-256/...), not a plain `sha256sum.txt` --
   SHA-256 is column 19, confirmed live against that release's own
   `checksums_hashes_order` asset (fetched 2026-07-28) rather than assumed.
3. Full Dockerfile build + a smoke run (`docker run` with all 5 tools'
   `--version`/`version` output, on `--platform linux/amd64` since this
   build machine is arm64) confirmed talosctl v1.13.5, kubectl v1.36.2, jq
   1.8.2, yq v4.53.3, bao v2.6.1 -- all matching this fleet's existing
   pins, all actually executable, not just present.
4. `shellcheck` (via `docker run koalaman/shellcheck`, not installed
   locally) found exactly one hit, an SC2086 on the same
   `${CP_ADDRS//,/ }` unquoted-expansion line that exists verbatim in the
   original script -- confirmed intentional (comma-to-space word-splitting
   that quoting would break), not a new defect.

**Two kube-linter/checkov-class findings, same suppression pattern as step
1's `provider-terraform-state-backend`**: the Job's `Role`/`RoleBinding`
(dynamic per-claim Secret names, can't scope `resourceNames`) and both
`NetworkPolicy` objects (`dangling-networkpolicy` -- no Job pod exists
until step 3 creates one). All annotated with a specific rationale, not
blanket-ignored. `make render` + `lint-kube-linter` + checkov + trust-domain
all clean after.

**Genuinely new NetworkPolicy shape, flagged as such**: talosctl needs
port 50000 (apid) egress to the claimed cluster's own nodes -- addresses
vary per claim, so (like the existing bare-443 external-reachability
rules) it can't be scoped to a specific `ipBlock` the way
provider-terraform's KVM-host SSH rule was. Worth a second look at step 3
once real node addresses exist, in case a tighter scope becomes possible
(e.g. the claimed cluster's own allocated ULA range).

**Not done in this step, deliberately**: no Job resource template exists
yet (that's step 3, once the Composition knows exactly what to template
from the Workspace's outputs); the image hasn't been pushed to GHCR (the
GH Actions workflow triggers on push to `main` -- nothing merged yet); no
real Talos cluster has been bootstrapped through this path. The
`app.kubernetes.io/name: talos-cluster-bootstrap` label + `serviceAccountName:
talos-cluster-bootstrap` contract the step-3 Job must satisfy is written
down in `applications/talos-cluster-bootstrap/README.md` -- check it
before writing the Job template.

**OpenBao side live-configured 2026-07-28**: the user ran
`.bin/configure-openbao-talos-cluster-bootstrap-secrets.sh` -- policy
`talos-cluster-bootstrap-secrets` and `auth/kubernetes/role/
talos-cluster-bootstrap` both written successfully, clean output, no
errors. The role is bound to a ServiceAccount name/namespace
(`talos-cluster-bootstrap`/`crossplane-system`) that **doesn't exist on
the live cluster yet** -- OpenBao roles bind by name only, no existence
check at write time, so this is expected and not itself a verification
that the whole chain works. That last link (the actual ServiceAccount +
a real `bao write auth/kubernetes/login` from a pod using it) can't be
checked until the `talos-cluster-bootstrap` app + `provider-terraform`
merge and Flux applies them.

### Merged to main — 2026-07-29

Source PR `estenrye/flux-platform-src#131` and rendered PR
`estenrye/flux-platform-rendered-controlplane#117` both merged at the
user's explicit direction, after all CI checks (render, lint, checkov,
trust-domain, the `talos-cluster-bootstrap` image build, and the
rendered-repo push) were green. `controlplane`'s Flux will pick this up
on its normal reconcile — first real live installation of
`provider-terraform` and the `talos-cluster-bootstrap` identity on the
fleet. Not yet independently verified post-merge (e.g. `kubectl get
provider provider-terraform` showing `Healthy`, or a real `bao write
auth/kubernetes/login` from that ServiceAccount succeeding) — worth
checking before step 3 assumes either is actually working.

### Post-merge live verification found a real bug — RESOLVED 2026-07-29

Checking the above turned up a genuine problem: `provider-terraform`'s pod
was crash-looping (`0/1 Error`, 5+ restarts) — `kubectl logs` showed
`SafeStart precheck failed: unable to perform RBAC check ... dial tcp
[fd97:45c2:b3a1:2000::1]:443: i/o timeout` (the provider does an RBAC
self-check against the apiserver on startup, independent of any
Workspace). Root cause: the `provider-terraform` `NetworkPolicy` shipped
in step 1 had a comment correctly describing the standard bare-port-6443
apiserver egress rule (Calico evaluates post-DNAT, Talos serves the
apiserver on 6443) but the rule itself was never actually written — only
a separate external-443 rule existed. `talos-cluster-bootstrap`'s own
NetworkPolicy had the correct rule; only `provider-terraform`'s was
missing it. This is exactly the class of bug the design doc's own
verification section exists to catch, and it was only caught because the
user asked "proceed [to step 3]" and a live-state check was done first
instead of assuming the merged PRs meant the pods actually worked.

Fixed in `estenrye/flux-platform-src#133` + rendered
`estenrye/flux-platform-rendered-controlplane#118`, merged same day.
Verified end-to-end live: `flux-platform-rendered`'s `GitRepository`
picked up the new revision (~90s after merge, 1m poll interval),
`crossplane-providers` Kustomization applied it, and after a manual
`kubectl delete pod` to force a restart with the new policy, the pod came
up `1/1 Running`, `0` restarts, and `kubectl get providers.pkg.crossplane.io
provider-terraform` shows `Healthy=True`/`Installed=True`.

**Still not verified**: a real `bao write auth/kubernetes/login` from the
`talos-cluster-bootstrap` ServiceAccount (no Job has run yet to exercise
that path — the Job template itself is step 3).

### Step 3 detail — shipped 2026-07-30, not yet applied live

**Scope narrowed at the user's direction** before any code was written,
same "narrow first" reasoning as steps 1-2 (confirmed via `AskUserQuestion`):
this step gets a claim from nothing to a running, reachable Talos cluster
with DNS/trust-domain registered and a kubeconfig Secret on `controlplane`.
Pushing Flux onto the *new* cluster, GitHub rendered-repo/deploy-key
automation, and the public JWKS/OIDC mirror are split out to steps 3b/3c —
see [[m4-design]]'s execution-order section for the full breakdown and the
ADR-14 automatability research behind it.

**What shipped**: `applications/crossplane-resources/xkubernetescluster/`
(XRD + `cluster-talos-kvm` Composition + catalog/kustomization/README/
examples, mirroring `delegated-hosted-zone-aws`'s exact structure and
Pipeline-mode Go-templating style); a `platform-kvm-network`
`EnvironmentConfig` (hand-curated per-cluster network allocation, empty
until step 5 populates a real `observability` entry); changes to
`providers/kvm/modules/talos-cluster` (new `data.tf` computing the
Talos-factory schematic ID internally instead of taking it as a
caller-supplied input) and `images/docker/talos-cluster-bootstrap/
bootstrap.sh` (takes the now-single-sourced `SCHEMATIC_ID` directly
instead of recomputing it) — a real coordination gap found and fixed
while *planning*, not discovered live: the VM-creation module and the
bootstrap Job each independently computed a schematic ID that merely
*happened* to agree because both hashed the same input; moving the
computation into the module and threading its output through removes the
duplication.

**Independently validated, not just written and trusted**:
- The embedded Terraform module text (the Composition's `Workspace` uses
  `source: Inline` — see the "real risk avoided" note below — so the
  actual HCL a reconcile would run is a literal string inside
  `composition.yaml`, not a file `tofu` would normally lint). Extracted
  it into a scratch directory (sibling `../talos-vm` copied alongside),
  ran `tofu init`/`validate` (clean) and a real `tofu plan` against
  `factory.talos.dev` with representative `tfvars` — produced the exact
  same schematic ID, ISO URL, and node MAC/ULA output as the real
  `providers/kvm/modules/talos-cluster` module's own equivalent test.
  Caught and fixed two real HCL syntax bugs this way (see below) that
  `make render`/kube-linter would never have caught, since kustomize
  treats the whole embedded HCL as an opaque string.
- **Real bugs caught by this validation, not by inspection**: six
  `variable "x" { type = number, default = N }`-style declarations used
  invalid single-line HCL block syntax (a block body's attributes must be
  newline-separated, not comma-separated — comma-separated is only valid
  inside an *object-constructor expression* like `{ source = "x", version
  = "y" }` used as a value, which is a different grammar rule and is why
  the adjacent `required_providers { libvirt = {...} }` block's inline
  object syntax was fine while these weren't). `tofu init`/`validate`
  failed with a specific, correct error pointing at each one; fixed by
  splitting to multi-line blocks.
- `make render` + `kube-linter` + `checkov` + `lint-trust-domain` all
  clean across the whole repo, confirming the ~700-line `composition.yaml`
  (a Go-template's source lives inside a YAML string field, so this only
  validates the *outer* YAML structure, not the template's runtime
  semantics — see below) parses and integrates correctly.

**Real risk identified and deliberately avoided, not just noted**:
`provider-terraform`'s `Workspace` supports `source: Remote` (git-sourced
modules) or `source: Inline` (literal HCL text). `Remote` would let the
Workspace reference `providers/kvm/modules/talos-cluster` directly from
this repo instead of duplicating it — but `flux-platform-src` is private,
so `Remote` needs its own git-clone credential wired into
`provider-terraform`'s container, and exactly how/where `go-getter` picks
that up for a private clone was unverified. Chose `Inline` (embed the
module's current `.tf` content directly) to avoid stacking one more
unproven dependency on top of everything else this step already
introduces. **Accepted, documented tradeoff**: the embedded copy can
drift from the real module if one is edited without the other — flagged
both in `composition.yaml`'s own comments and in
[[m4-design]]/the design doc, not silently accepted.

**Known gap — RESOLVED 2026-07-31, same day flagged**: the `Workspace` had
no Terraform state backend configured anywhere — not in the embedded
module, not in the shared `provider-terraform` `ProviderConfig` (which
deliberately has none, per step 1's D4 correction: a shared backend
config would make every cluster's Workspace collide on one state
Secret). Fixed via option (a) from the original write-up: the embedded
module's `terraform {}` block now also declares `backend "kubernetes" {
secret_suffix = "{{ $name }}", namespace = "crossplane-system",
in_cluster_config = true }`, templated per-claim by the same Go-template
step that already has `$name` in scope. No new RBAC needed —
`provider-terraform`'s existing `crossplane-system` `Role`/`RoleBinding`
(step 1, no `resourceNames`) already covers whatever Secret name this
produces. Re-validated the same way as the original embedded-module
check: extracted into a scratch directory, `tofu init -backend=false` +
`tofu validate` clean (confirms `-backend=false` correctly skips real
backend initialization during offline validation, not just that the
HCL parses). `make render`/kube-linter/checkov/trust-domain all
re-confirmed clean after.

**Explicitly unverified against a live reconcile (no claim exists yet —
that's step 5), each documented at its point of use**:
- `provider-kubernetes`'s `Object` resource `apiVersion`
  (`kubernetes.crossplane.io/v1alpha2`, inferred from
  `crossplane-contrib/provider-kubernetes` source during research, not
  observed live).
- The exact field name for a CEL query under `readiness.policy:
  DeriveFromCelQuery` (`celQuery`, inferred from the enum's own naming
  convention).
- `function-go-templating`'s Sprig function availability beyond `list`/
  `default` (already confirmed in use by `delegated-hosted-zone-aws`) —
  `dict`, `toJson`, `append`, `mul`, `quote` are assumed available (Sprig
  is a large, standard, near-universally-bundled Go-template function
  library, and `list`/`default` being present is reasonably strong
  evidence the rest of Sprig is too) but not independently confirmed.
- Whether `Workspace.spec.forProvider.varmap` accepts arbitrarily nested
  JSON (lists of objects, maps) the way the `hosts`/`control_plane_node_ulas`
  values here need — confirmed from the upstream README's description,
  not from a live apply.

**Not done in this step, deliberately**: no `KubernetesCluster`/
`XKubernetesCluster` claim was created — no VM, no Job run, no live
cluster. The XRD + Composition are themselves safe to apply live (they
only register a CRD and a Composition; nothing reconciles until a claim
exists) but weren't applied in this session — flagged for the user's
go-ahead before merge, same diligence as every prior provider/CRD
install in this milestone.
