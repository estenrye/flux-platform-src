---
name: m4-step-tracker
description: M4 step tracker — step 1 verified done 2026-07-28 (OpenBao kv round-trip confirmed by the user); step 2 (Talos-bootstrap Job image + script) shipped same day, not yet live-tested
metadata:
  type: project
---

Tracks [[m4-design]]'s 8-step execution order. Update as steps complete —
this decays fast, keep it current rather than trusting it blindly.

## Status as of 2026-07-28

| # | Step | Status |
|---|---|---|
| 1 | provider-terraform install + generalized `talos-cluster` tofu module + `crossplane-kvm-hosts` EnvironmentConfig | **Done** — bootstrap script run by the user, OpenBao `kv get` on `provider-terraform/kvm-ssh-key` confirmed working |
| 2 | Talos-bootstrap Job image + script (OpenBao for secrets) | Shipped; OpenBao policy/role live-configured 2026-07-28; ServiceAccount/Job/manifests still unmerged, no real cluster bootstrap attempted |
| 3 | `XKubernetesCluster` XRD + `cluster-talos-kvm` Composition | Not started |
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
