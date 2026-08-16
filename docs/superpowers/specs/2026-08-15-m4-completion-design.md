# M4 Completion: Closing All Known Gaps

Date: 2026-08-15
Status: Approved — steps B/C/D/E scoped, B.5/B.6/D/E to be refined further at execution time
Companion: [2026-07-26-m4-cluster-lifecycle-design.md](2026-07-26-m4-cluster-lifecycle-design.md) (original M4 design),
           [../memory/m4-step-tracker.md](../memory/m4-step-tracker.md) (live status)

## 1. Why this doc exists

While scoping M5 (observability backbone), `docs/memory/m4-step-tracker.md`
was found to falsely claim M4 step 4 (`clusters/observability/` baseline
layer) was "Done." The user asked for a full audit of M4 rather than a
one-line patch. Three parallel Explore agents independently re-verified all
8 steps against real git history and file content (not other memory files).

## 2. Audit results

| # | Step | Audit verdict |
|---|---|---|
| 1 | provider-terraform + `talos-cluster` module + `crossplane-kvm-hosts` EnvironmentConfig | **CONFIRMED** — real files, wired, PR #131/#133 diffs match claims |
| 2 | Talos-bootstrap Job image + script | **CONFIRMED** — image, workflow, Job identity all real and wired |
| 3 | `XKubernetesCluster` XRD + Composition | **CONFIRMED** |
| 3b | Flux bootstrap push onto `observability` | **CONFIRMED** — real, but via the manual scripted chain, not the originally-envisioned Crossplane automation (documented, deliberate) |
| 3c | Public JWKS/OIDC mirror | **NOT STARTED** — no commit anywhere, deliberately deferred at step 3b's time |
| 4 | `clusters/observability/` baseline layer | **FABRICATED** — tracker claim traced to commit `49a6969` (PR #159), a Backstage-catalog PR whose diff never touched this. No implementation exists anywhere |
| 5 | `observability` claim — first end-to-end provision | **PARTIALLY CONFIRMED** — the provisioning work is real (19 corroborated PRs, populated `platform-kvm-network` entry), but the claim manifest was never committed to GitOps; applied out-of-band |
| 6 | Chainsaw tests + Usage guards | **CONFIRMED** — both suites real, Usage guards real in `composition.yaml`, Tier B live-run account internally credible |
| 7 | Backstage `catalog.yaml` wiring | **CONFIRMED** |
| 8 | ADR-27 | **CONFIRMED** |

**Root cause of the step-4 fabrication**: commit `49a6969`'s message states
the tracker "was stale — steps 3b/4/5 had merged weeks ago," which was true
for 3b and 5 but false for 4. No later session (steps 6/8 close-out, the
"M4 fully complete" declaration) re-verified this before building on top of
it.

**Decision (user, given two possible scope sizes): fix everything** — both
confirmed real gaps (4, 5) and both deliberately-deferred items (3c, full 3b
automation), not just the minimum needed to unblock M5.

## 3. Delivery plan

### A. Correct the record — DONE 2026-08-15

`docs/memory/m4-step-tracker.md` and `docs/memory/MEMORY.md` corrected in
place: step 4 reopened with the fabrication traced to its source commit,
step 5 annotated with the GitOps-tracking gap, the false "M4 fully complete"
conclusions superseded (not deleted — kept for history, clearly marked
wrong).

### B. Step 4 — real baseline layer for `observability`

Scope is authoritative from
[2026-07-26-m4-cluster-lifecycle-design.md](2026-07-26-m4-cluster-lifecycle-design.md)
§6, not guessed from `controlplane`'s list:

**Included**: Calico + default-deny, priority-classes, reloader, gateway/envoy
CRDs, external-dns, storage (democratic-csi), Flux + flux-monitoring, ESO
pointed at OpenBao on `controlplane`, cert-manager + approver-policy +
trust-manager + spiffe-issuer + spiffe-csi-driver (own trust domain
`obs.rye.ninja`, ADR-16), Pinniped **Concierge only**.
**Excluded** (controlplane-only, ADR-14): step-ca(-db), OpenBao(-db),
Keycloak(-db), Pinniped Supervisor, Garage, the Crossplane stack.

Sub-steps, sized to land as 2-3 PRs (mirrors M2-M4's own narrow-scope-per-PR
style):

1. **Network + portable additions** (low risk): new
   `applications/global-network-policy-default-deny/observability/` overlay;
   add `applications/reloader/base` and `applications/flux-monitoring/base`
   (both cluster-agnostic, no new overlay needed) to
   `clusters/observability/kustomization.yaml`.
2. **Ingress plumbing**: add `applications/gateway-api-crds/base`,
   `applications/envoy-gateway-crds/base`, `applications/envoy-gateway/base`
   — same reusable `/base` dirs `controlplane` consumes directly.
3. **Storage**: add `applications/democratic-csi/base`; new SOPS-encrypted
   driver-config secrets via the existing `CLUSTER=observability
   NFS_SERVER_ULA=<ula> make provision-democratic-csi` target.
4. **DNS**: add `applications/external-dns/unifi/base`. Decide at this step
   whether a `cloudflare/observability` overlay is needed now or can wait
   for M5's first public endpoint.
5. **Trust fabric** (own PR, own go-ahead gate — offline CA operation):
   mint `observability`'s own step-ca intermediate for `obs.rye.ninja`
   (confirm the exact offline procedure from PR #74/M2 steps 0-3 before
   doing this, don't assume). New overlays mirroring `controlplane` exactly:
   `cert-manager/observability`, `cert-manager-approver-policy/observability`,
   `cert-manager-trust-manager/observability`,
   `cert-manager-spiffe-issuer/observability` (CA issuer over the new
   intermediate), `cert-manager-spiffe-csi-driver/observability`
   (`app.trustDomain: obs.rye.ninja`). Add
   `applications/pinniped-concierge/base` (verify its values are already
   cluster-agnostic before assuming reuse).
6. **Secret delivery for the new consumers above**: pick between
   Kubernetes-auth multi-mount (new `auth/kubernetes/observability` mount on
   `controlplane`'s OpenBao, trusting `observability`'s own apiserver/token
   reviewer — keeps the one auth pattern this fleet already uses everywhere)
   and AppRole (simpler on OpenBao's side, no cross-cluster apiserver trust,
   but a new pattern this repo has never used). **Recommend Kubernetes-auth
   multi-mount** — consistent with all 4 existing OpenBao bootstrap scripts,
   no new credential-distribution mechanism. Confirm at execution time before
   building.
7. **Verification**: `make render` + lint-kube-linter + checkov +
   trust-domain clean after each PR. Post-merge live: nodes stay `Ready`,
   cert-manager pods healthy, real SVID check (`openssl x509 ... | grep URI`
   → `spiffe://obs.rye.ninja/...`, per ADR-16), democratic-csi provisions a
   real test PVC, Pinniped Concierge `TokenCredentialRequest` succeeds. Only
   mark the tracker "Done" after this live verification, not at merge —
   directly fixing the gap that produced the fabricated claim.

**Known live-verification blocker**: sessions without fleet network access
can't run the live checks in step 7 (confirmed: `no route to host` on both
cluster kubeconfigs from this session) — needs the user, or a
network-connected session.

### C. Step 5 gap — commit the `observability` claim to GitOps

Lower risk than it first looks:
`applications/crossplane-resources/xkubernetescluster/examples/example-claim.yaml`
already contains a claim literally named `observability`
(`namespace: crossplane-system`, 3 CP / 0 workers, `subdomain: obs`,
`vlanRef: observability-vlan`) — almost certainly the exact template used
for the original out-of-band `kubectl apply`. Fix:

1. Diff this example against the **live** claim's current spec (needs the
   user or a network-connected session — `kubectl get xkubernetescluster
   observability -n crossplane-system -o yaml`) to confirm no drift.
2. If it matches, promote it into
   `clusters/controlplane/crossplane-resources/xkubernetescluster.observability.yaml`
   (same pattern as the existing
   `delegated-hosted-zone-aws.controlplane-rye-ninja.yaml`), wire into that
   directory's `kustomization.yaml`.
3. First Flux apply should be a no-op update given matching name/namespace/
   spec — verify live (no unexpected diff, no resource recreation) before
   trusting it.

### D. Step 3c — public JWKS/OIDC mirror

Design-level only for now; needs its own scoping pass at execution time
(matches how every other M4 step got refined right before being built, not
upfront). Known building blocks and open questions to resolve then:

- Confirm/set `--service-account-issuer` on the target cluster's Talos
  apiserver config to a stable public HTTPS URL.
- A CronJob mirroring `/.well-known/openid-configuration` +
  `/openid/v1/jwks` from the local apiserver to a public-read Garage bucket
  (on `controlplane`'s Garage, per the on-prem substrate design).
- A real public DNS name + ingress path for the mirror.
- Security review of anonymous/public JWKS exposure before shipping — this
  is a new public attack surface, treat with the same diligence as every
  other new external-facing endpoint in this fleet.
- Relevant trigger: if step B.6 above lands JWT/OIDC-based OpenBao auth
  later, this mirror becomes a hard dependency — otherwise it's standalone.

### E. Step 3b full automation — Crossplane-driven Flux bootstrap

Design-level only for now. Today's manual chain
([[bootstrap-cluster-generic-chain]]): 6 `.bin/bootstrap-cluster-*.sh`
scripts + `make deploy-cluster` (one-time direct `kubectl apply`) + `make
bootstrap-cluster-deploy-key` + a manual push/merge + `flux reconcile source
git`. Automating this means a Composition-driven pipeline (likely a new
stage in `cluster-talos-kvm` or a follow-on XR) that:

- Creates the GitHub deploy key + rendered repo via `provider-github`
  (already installed, used elsewhere in this repo).
- Applies the initial bootstrap resources directly to the new cluster via
  `provider-kubernetes` with a remote `ProviderConfig` sourced from the
  cluster's own kubeconfig Secret — genuinely unblocked now (that Secret
  didn't reliably exist before step 2/3 landed; it does now).
- Triggers the render/CI step that today runs on a `git push` to `main` —
  open question: does Crossplane push directly to the source repo's default
  branch, or open a PR needing a merge gate? This determines how "hands-off"
  the automation actually ends up being.
- Triggers the initial Flux reconcile.

This is the largest, least-specified piece of this plan — treat it as its
own mini-milestone with its own `AskUserQuestion` scoping pass before any
code is written, same as every other genuinely new design decision in this
repo's history.

## 4. Sequencing

A (record correction) first — done. B (step 4) and C (step 5 GitOps
adoption) are independent of each other and of D/E — can proceed in
parallel. D (JWKS mirror) and E (full 3b automation) are both substantial
new builds; sequence them after B/C are live-verified, since B.6's OpenBao
auth decision may make D partially moot (if Kubernetes-auth multi-mount is
chosen, D is no longer a blocker for anything in this plan — just a
standalone completion item).

## 5. Verification

Every sub-step gets: `make render` + `make lint-kube-linter` + checkov +
trust-domain lint clean before merge (existing repo-wide gate); live
verification after merge, explicitly required before any tracker entry is
marked "Done" — the exact discipline gap that produced this whole audit.
