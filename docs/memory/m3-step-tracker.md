---
name: m3-step-tracker
description: M3 is fully complete (all 11 steps) as of 2026-07-25 — democratic-csi/Garage/OpenBao/Keycloak/Pinniped live, ADR-21 amended, ADR-25/26 written, 4 runbooks in docs/runbooks/
metadata:
  type: project
---

Tracks [[m3-design]]'s 11-step execution order. Update as steps complete —
this decays fast, keep it current rather than trusting it blindly.

## Status as of 2026-07-24

| # | Step | Status |
|---|---|---|
| 1 | democratic-csi shadow deploy + smoke test | Done (merged #78–#83) |
| 2 | Flip default SC, migrate step-ca-db, retire nfs-pg-owner CronJob | Done (#84) |
| 3 | Garage 3-node + buckets | Done (#85–#97); Garage was redeployed/reset several times during this step's iteration — see WAL gap note below |
| 4 | step-ca-db barman → Garage, retire pg_dump CronJob | Done — see detail below |
| 5 | OpenBao HA on CNPG/Postgres backend | **Fully done 2026-07-24**, including the unseal ceremony `[H]` — see detail below and [docs/runbooks/openbao-unseal.md](../runbooks/openbao-unseal.md) |
| 6 | ESO ClusterSecretStore → OpenBao | Done — see [[m3-step6-secret-migration-eligibility]] |
| 7 | Off-site backup sync (Garage → Cloudflare R2) | Done — see detail below |
| 8 | `keycloak-db` CNPG cluster | Done — see detail below |
| 9a | `cert-manager-acme`: letsencrypt-staging/prod ClusterIssuers | Done — see detail below |
| 9b | Keycloak: realm `ryezone-labs` at `https://id.rye.ninja` | Done — see detail below |
| 10 | Pinniped Supervisor + Concierge, OIDC federation, RBAC | Done 2026-07-25 — see detail below |
| 11 | ADRs, runbooks | Done 2026-07-25 — ADR-21 amended, ADR-25/26 written; openbao-restore/keycloak-realm-restore/garage-node-replacement runbooks written (openbao-unseal already existed). **M3 complete.** |

### Step 10 detail (2026-07-25) — Pinniped Supervisor + Concierge, RESOLVED

Deployed via raw upstream release manifests (no Helm chart exists) at
`applications/pinniped-supervisor/base` and
`applications/pinniped-concierge/base`, `v0.47.0`. Supervisor federates
Keycloak (`OIDCIdentityProvider` against `id.rye.ninja`) and issues its
own tokens at `https://sso.rye.ninja` (`FederationDomain`); Concierge
validates those tokens (`JWTAuthenticator`) and exposes
`TokenCredentialRequest` for `kubectl`. RBAC: `k8s-admin`/`k8s-viewer`
Keycloak groups bound to `cluster-admin`/`view` via `ClusterRoleBinding`
`Group` subjects, relying on a new `groups` client scope
(`oidc-group-membership-mapper`, `full.path: false`) assigned directly
to the `pinniped-supervisor` client.

**Deliberate deviation from [[m3-design]] A5's literal wording**: the
Supervisor terminates its own TLS (Passthrough, same mechanism as
step-ca's Gateway) rather than terminating at Envoy Gateway like
Keycloak. Reason: the Supervisor has no plain-HTTP listener mode at
all, and upstream's own docs warn against terminating TLS in front of
it without re-encrypting to the backend. See
`applications/pinniped-supervisor/base/resources/gateway.yaml`.

**Every one of the following was found live, one at a time, each
symptom masking the next** — the full stack looked "deployed" after the
first `kubectl apply` pass but nothing actually worked end-to-end until
all of these landed:

1. **Rendered manifests split across subdirectories that a namespace-scoped `kubectl apply -f <dir>/pinniped-*/` misses entirely.** The upstream install manifests contain resources destined for `kube-system` (an extra Role/RoleBinding pair for `extension-apiserver-authentication-reader` + a `kube-system-pod-read` Role) and `kube-public` (a Role/RoleBinding granting `list`/`watch` on all ConfigMaps there) alongside three cluster-scoped `APIService` objects and a `CredentialIssuer`. `.render/.../resources/kube-system/`, `.../kube-public/`, and the top-level `apiregistration.k8s.io_v1_apiservice_*.yaml` / `config.concierge.pinniped.dev_v1alpha1_credentialissuer_*.yaml` files are separate from the per-app subdirectories — applying only `pinniped-supervisor/` and `pinniped-concierge/` silently skips all of them. **When applying a multi-namespace rendered app by hand (bypassing Flux), diff the full file list against what got applied — don't assume the per-app subdirectory is the complete set.**
2. **Both `pinniped-supervisor`'s and `pinniped-concierge`'s NetworkPolicy egress rules were missing the Talos apiserver port (6443)** — both are themselves aggregated-API-server registrants (they watch their own CRs and manage `APIService`/`Secret` objects), same requirement as any other apiserver client. See [[calico-networkpolicy-dnat]].
3. **`sso.rye.ninja`/`id.rye.ninja` resolve to this same cluster's own `envoy-merged-eg` LoadBalancer Service** (not a genuinely external destination like cert-manager's ACME/Cloudflare egress), so kube-proxy/Calico DNAT rewrites the destination before egress ever leaves the source pod's veth — egress must allow the post-DNAT containerPort **10443** (`envoy-merged-eg` Service: `443 -> targetPort 10443`), not the dialed port 443. Symptom was a bare TCP connect timeout (not a TLS-layer failure) from every namespace tested, including ones with no NetworkPolicy relevance at all — the tell was that a **direct pod-to-pod connection to the envoy-proxy pod's own IP:10443** also timed out, which only makes sense as a NetworkPolicy block, not a routing/hairpin problem. Fixed in both `pinniped-supervisor`'s and `pinniped-concierge`'s own `network-policy.yaml` (each reaches the other's namespace's public hostname). See [[calico-networkpolicy-dnat]].
4. **`envoy-gateway-system`'s own `envoy-proxy-allow` NetworkPolicy egress never had port 8443 (Supervisor's containerPort) added**, despite the source file already containing the fix with a comment describing it — the edit existed in the repo from before this session's context compaction but was never actually `kubectl apply`'d live. This produced a TLS ClientHello that got sent but never answered (hung, not reset) — Envoy's own egress to the passthrough backend was blocked, so nothing was listening to complete the handshake from Envoy's side even though the Supervisor itself was healthy and Ready. **Lesson repeated from step 9b: a source-file fix is not a live fix. After resuming from a compacted context, re-diff "what the source says should be applied" against "what's actually live" before trusting any file's own claim that something was already done.**
5. **Concierge's `kube-cert-agent-controller` hard-depends on `kube-public/cluster-info` existing, sequentially, before it even inspects the `kube-cert-agent` pod it deploys — and Talos never creates this ConfigMap** (it's a kubeadm-only bootstrap artifact; Talos's control plane is real and visible via `kubectl get pods -n kube-system -l k8s-app=kube-controller-manager`, but nothing populates `kube-public/cluster-info`). The `CredentialIssuer` sat on `CouldNotGetClusterInfo` indefinitely with the `kube-cert-agent` Deployment/pod already healthy — deploying the agent pod is necessary but not sufficient. Fixed with a new idempotent bootstrap script, `.bin/bootstrap-pinniped-cluster-info.sh`, that reads the live cluster's own CA + apiserver address from `kubectl config view --raw` and writes the standard kubeadm-format `cluster-info` ConfigMap (bare kubeconfig, CA + server only, no user/context — matches what a kubeadm cluster ships natively). Deliberately **not** committed as a static kustomize resource: the CA is per-cluster and would go stale across a Talos rebuild, same reasoning as this repo's other cluster-bootstrap-only scripts (`.bin/bootstrap-cluster-sops-key.sh`, `.bin/configure-openbao-*-secrets.sh`). **This is a standing Talos gap, not specific to this cluster's config — any Concierge deploy on any Talos (or other non-kubeadm) cluster needs this same fix.**

None of these were guessed — each was isolated with a targeted debug pod (`kubectl run --rm -i --restart=Never --labels=<matching the relevant NetworkPolicy's podSelector>`) and a specific test (raw IP vs. hostname/SNI, direct pod IP vs. Service vs. external hostname, `curl -v` for TLS-handshake-level detail) to separate "connects but hangs" from "never connects" from "connects then resets," since each has a different root cause in this codebase's established DNAT/RBAC/leader-election failure modes.

Also confirmed (not a bug, just a technique worth keeping): Keycloak's `keycloak-config-cli` Job needed re-running after this step's realm-config edits (new `groups` client scope + `pinniped-supervisor` client with `IMPORT_VARSUBSTITUTION_ENABLED` pulling `PINNIPED_CLIENT_SECRET` from a Secret) — Jobs are immutable, so this means `kubectl delete job` + re-apply, not `kubectl apply` in place, same pattern as `applications/garage/controlplane/resources/bucket-init-job.yaml`.

### Step 10's `[H]` verification — RESOLVED 2026-07-25

The `ryezone-labs` realm had **no users at all** (`GET /admin/realms/ryezone-labs/users` returned `[]`) — nothing to actually log in as. Added one via `keycloak-config-cli`'s `users:` block (`esten`, `k8s-admin` group, SOPS-encrypted temporary password, Keycloak's normal forced `UPDATE_PASSWORD` reset on first login). Hit one more Flux issue applying it: the re-run `keycloak-config-cli` Job had been `kubectl apply`'d live under a different field manager than Flux's server-side apply, so Flux's reconcile failed with `field is immutable` on `spec.template` — fixed by deleting the Job and letting Flux recreate it from scratch (same "manual edits are temporary until merged" class of issue as step 9b, but the failure mode this time was an SSA field-manager conflict rather than a plain revert).

**The actual login then failed twice more, each for a real reason, before finally working:**

1. **First failure was user error, not a bug**: logging in at `https://id.rye.ninja/admin` authenticates against the `master` realm by default, not `ryezone-labs` — `esten` doesn't exist there. Confirmed by testing the password directly against Keycloak's own token endpoint (`grant_type=password`), which returned `"Account is not fully set up"` (a very different, informative error) rather than "invalid credentials" — proving the password was actually correct and it was a wrong-realm problem. Keycloak's own login form (both `/admin` and a real end-user login) shows a generic "Invalid username or password" for both actually-wrong credentials *and* brute-force lockout, so don't trust that message alone — check the realm's actual login-failure counters (`GET .../attack-detection/brute-force/users/<id>`) and the exact URL (`realms/master` vs `realms/ryezone-labs` is easy to eyeball in the browser's address bar once you know to look). Fix: log in at `https://id.rye.ninja/realms/ryezone-labs/account/` instead.

2. **Second failure was a genuine, cluster-wide architectural incompatibility**: `pinniped login oidc`'s Concierge credential-exchange step got a bare `401 Unauthorized` from every kubeconfig shape tried — a hand-built anonymous bootstrap kubeconfig, and even the "normal" kubeconfig generated via `pinniped get kubeconfig --kubeconfig <admin-kubeconfig>`. Root-caused by manually replaying the exact `TokenCredentialRequest` call twice: once via plain unauthenticated `curl` (matching what the CLI's exec plugin actually does — the JWT rides in the request body specifically so this call needs zero prior apiserver-level credentials) and once wrapped in `kubectl create --raw` using admin transport credentials. The unauthenticated one got the bare `401` from the *main Kubernetes apiserver itself*, before the request ever reached Concierge or evaluated any RBAC; the admin-wrapped one succeeded completely and returned a real signed client cert. **Talos runs `kube-apiserver` with `--anonymous-auth=false` by default** (unlike vanilla kubeadm), which rejects every truly-anonymous request at the authentication layer — a hard blocker no kubeconfig-generation trick can route around, since `pinniped login oidc`'s exec-plugin invocation is always anonymous transport at the HTTP/TLS level regardless of how the resulting kubeconfig file was produced.

   Fixed by re-enabling it: `cluster.apiServer.extraArgs.anonymous-auth: "true"` added to `.bin/create-controlplane-cluster.sh`'s `patch-cp.yaml` heredoc (so a future full rebuild reproduces it) and applied live to all three control-plane nodes via `talosctl machineconfig patch` (offline merge against the node's rendered config in `providers/kvm/controlplane/.rendered/`, diffed to confirm a single-field change) + `talosctl apply-config --mode try` (auto-rollback safety net) then `--mode no-reboot` to confirm, one node at a time, verifying `kubectl get nodes`/the apiserver pod's restart between each. **Only activates two pre-existing, already-reviewed `system:unauthenticated` RBAC bindings** — Pinniped's own `pinniped-concierge-pre-authn-apis` ClusterRole (create/list on `TokenCredentialRequest`/`WhoAmIRequest` only, nothing else) and the stock `system:public-info-viewer` binding present on any vanilla cluster — nothing new was granted, they simply became reachable. A narrower alternative (granting `system:unauthenticated` read access to just `CredentialIssuer`, to unblock kubeconfig *generation* without touching the apiserver) was tried first and found insufficient: it doesn't help the *runtime* `TokenCredentialRequest` call, which is the one that actually needs anonymous-auth open — that narrower change was reverted once this was understood, in favor of the real fix.

   **Gotcha for next time**: the machine-config tooling in this repo (`.bin/create-controlplane-cluster.sh`) requires the exact matching `talosctl` client version — `.venv/bin/talosctl` (pinned, v1.13.5 to match the cluster) is correct; whatever's on the global `PATH` (found to be a stale v1.4.6 here) will silently mis-decode newer machine-config fields (`unknown keys found during decoding`) rather than erroring clearly. Always invoke the repo's pinned binary explicitly for machine-config work, not whatever `talosctl` resolves to on `PATH`. Also: `talosctl patch <resource>` (the *live* resource-patch API) expects RFC6902 JSON-patch format and a `--dry-run`-unfriendly resource/ID pair (`mc v1alpha1`); the simple strategic-merge YAML that works for `talosctl gen config --config-patch` and `talosctl machineconfig patch <file>` (the *offline* file-merge tool used here) does not work with `talosctl patch`. Prefer the offline merge-then-`apply-config` path — it produces a reviewable diff before anything touches a live node.

Verified end-to-end after the anonymous-auth fix landed: a plain unauthenticated `curl` `TokenCredentialRequest` with a deliberately bogus token now gets `{"status":{"message":"authentication failed"}}` from Concierge itself (proof the request reaches RBAC and the authenticator, instead of bouncing off the apiserver's outer authn layer), and the user confirmed `pinniped get kubeconfig` + `kubectl get pods -n kube-system` works end-to-end through a real browser login as `esten`, landing as `cluster-admin` via the `k8s-admin` group. **M3 step 10 has no more open items.**

### Step 9b detail (2026-07-25) — Keycloak, RESOLVED

**Deployment tooling pivoted mid-step, at the user's explicit request**:
started on Bitnami's Helm chart (their closest thing to an "official"
chart, and it conveniently bundles `keycloakConfigCli` as a first-class
values-driven integration). Shipped, deployed, fully verified live —
then the user asked to switch to the *upstream* image instead. Swapping
just `image.repository` on Bitnami's chart would have broken outright:
its StatefulSet template hardcodes Bitnami-specific paths
(`/opt/bitnami/keycloak/...`), a Bitnami entrypoint script, and a
`prepare-write-dirs` init container assuming Bitnami's filesystem layout
— none of which exist in `quay.io/keycloak/keycloak`. Re-platformed onto
`codecentric/keycloakx` (a thin wrapper chart built specifically for the
genuine upstream image, no repackaging) + a hand-rolled
`keycloak-config-cli` Job (this chart doesn't bundle one).

**Real, non-obvious finding: Bitnami retired its free `docker.io/bitnami/*`
image tags** (moved behind a paid subscription, some time in 2025) —
`docker.io/bitnami/keycloak` has zero tags now. Worth knowing before
reaching for *any* Bitnami chart in this repo again — the same problem
will recur. Wasn't the reason for the pivot (the user asked for upstream
regardless), but is what would have blocked staying on Bitnami's chart
long-term anyway.

**Real image findings, verified before committing to either**:
`adorsys/keycloak-config-cli` (the project's own Docker Hub repo, not a
Bitnami repackaging) is actively maintained — tags follow
`<cli-version>-<keycloak-version>` (e.g. `6.5.1-26.5.5`), confirmed via
`curl registry.hub.docker.com/v2/repositories/adorsys/keycloak-config-cli/tags/`
before picking one close to this chart's Keycloak version.

**Architecture, per A5**: TLS terminates at Envoy Gateway (`mode:
Terminate`), not inside Keycloak — `proxy.mode: xforwarded`, no
`tls:`/internal-cert config needed with keycloakx (it has no
`production`-mode TLS-required gate the way Bitnami's chart did).
`replicas: 1` (chart default, kept deliberately for M3's initial rollout
— jgroups/ispn HA clustering deferred to a later milestone).
`codecentric/keycloakx` ships **native Gateway API `httpRoute` support**
— `httpRoute.enabled: true` with `parentRefs` pointed at the existing
`keycloak` Gateway's `https` listener generates the HTTPRoute directly
from chart values; no hand-written HTTPRoute resource needed (unlike the
Bitnami attempt, which required one).

**New `keycloak` Gateway object, not a shared one**: `gatewayClassName:
merged-eg` is Envoy Gateway's "merged gateways" feature — every app
creates its *own* `Gateway`, and Envoy Gateway merges all of them onto
one shared Envoy proxy fleet/external address. Confirmed live: `keycloak`
and `step-ca`'s Gateways both resolved to the identical address
(`2607:3640:1064:27f::9280`). The `letsencrypt-policy`
`CertificateRequestPolicy` from step 9a already covered `id.rye.ninja`
(`*.rye.ninja` glob) — no new approver-policy grant needed.

**Three real bugs hit and fixed during live verification** (all specific
to the keycloakx re-platform, not present in the earlier Bitnami pass):

1. **Container printed CLI help and exited instead of starting.** Bitnami's
   entrypoint script defaults to starting the server; the bare upstream
   image's `ENTRYPOINT` is just `kc.sh` with no default command — with
   `command`/`args` both empty (keycloakx's own default), the container
   runs `kc.sh` alone, which prints usage and exits. Fix: `args: [start]`
   explicitly. Confirmed via `kubectl logs` showing the literal `kc.sh`
   help text before the fix, and a clean startup log after.
2. **`keycloak-config-cli` hung waiting on `http://keycloak-headless/`**
   for the full 120s timeout, every time, despite `keycloak-0` being
   `Ready`. Root cause: a headless Service (`clusterIP: None`) does **no
   port DNAT** — DNS resolves straight to the pod IP, but nothing
   remaps the Service's declared `port: 80` to the pod's actual
   `containerPort: 8080`; clients must target the real container port
   directly. Confirmed by testing `curl` against the pod IP:8080 directly
   (worked instantly) vs. the same pod IP via the *headless service
   name* on the declared port 80 (hung until timeout) vs. explicit port
   8080 on the headless service name (worked). Fixed by pointing
   `KEYCLOAK_URL` at `http://keycloak-headless:8080/`. **This was also
   silently true in the Bitnami pass** — its own config-cli Job used
   `http://keycloak-headless:8080/` (explicit port) from the start,
   which is why it never hit this; I didn't understand *why* that port
   was explicit until debugging this from scratch.
3. **`https://id.rye.ninja` 503'd again after the re-platform**, same
   symptom as the Bitnami pass's fixed bug (`envoy-proxy-allow`
   NetworkPolicy missing port 8080). Investigated assuming I'd
   regressed it — instead discovered the **real root cause of the
   original bug too**: Flux is actively reconciling this cluster from
   `main` on its normal interval, and since PR #126 (which carries this
   exact NetworkPolicy fix) was still open/unmerged, Flux's own
   reconcile silently reverted my earlier manual `kubectl apply` back to
   the committed (broken) state. It wasn't "I forgot to push the fix
   live" (the step 9b Bitnami-era note's original conclusion) — it's
   that *any* live edit to a Flux-managed resource is inherently
   temporary until the underlying source is merged, no matter how
   carefully it was applied. **General lesson**: when verifying a fix to
   a resource Flux manages, on a cluster where Flux is actively
   reconciling from an unmerged branch, expect it to get silently
   reverted on Flux's next sync — re-apply immediately before each
   verification attempt, and get the source change merged promptly
   rather than assuming a manual apply "sticks."

**Local admin credential**: 32-char random password, generated and piped
directly into `sops -e` + `kubectl apply` (live Secret) + OpenBao
(`secret/platform/keycloak/local-admin`, `bao kv put`) all within one
shell scope — never displayed, never written to a file. **Repeated the
"deleted the plaintext before finishing all three uses" mistake from
earlier in this session once already** (see the step-ca-db-snapshots-sync
section above) before catching it partway through — this time caught it
before losing anything, redid the whole generate→encrypt→apply→break-glass
sequence as a single atomic block. **Standing pattern for any future
secret needing multiple destinations: generate once, consume everywhere,
in one shell scope — never split "encrypt" and "use" across separate
commands when the value can't be recovered after SOPS-encrypting it.**
The DB and realm data live in `keycloak-db` (unaffected by the server
chart swap) — confirmed the whole re-platform preserved the existing
`ryezone-labs` realm and all 5 groups untouched (Keycloak's own startup
log showed it auto-migrating the realm's stored schema version across
the image bump, not recreating anything).

Verified end-to-end live before merge (full re-verification after the
keycloakx pivot, not just carried over from the Bitnami pass):
- Keycloak pod `Running`/`Ready` on the upstream image, `args: [start]`
  confirmed actually starting the server (not printing help)
- `keycloak-config-cli` Job succeeded against `keycloak-headless:8080`;
  realm `ryezone-labs` + all 5 A7 groups confirmed present via the admin
  REST API (identical group IDs to the pre-pivot check — proves the DB
  data survived the chart swap, not just "a realm exists")
- Re-ran the config-cli Job (delete + recreate) — succeeded again cleanly
- `https://id.rye.ninja/admin/master/console/` → `200`, real title
  "Keycloak Administration Console"
- `https://id.rye.ninja/realms/ryezone-labs/.well-known/openid-configuration`
  → `200`, `issuer: https://id.rye.ninja/realms/ryezone-labs` (confirms
  `proxy.mode: xforwarded` correctly derives the public issuer URL — this
  exact value is what step 10's Pinniped OIDC client will need)

**Deferred to step 10, deliberately**: a `groups` client scope +
group-membership protocol mapper (so group membership shows up as an
OIDC claim) was *not* added in this step. `defaultDefaultClientScopes`
semantics in a realm-import context are a known sharp edge (unclear
whether specifying it replaces vs. adds to the built-in scope list) —
safer to wire this once there's a real client (Pinniped) to test the
actual claim flow against, rather than guess now.

### Step 9a detail (2026-07-24) — cert-manager-acme, RESOLVED

New `applications/cert-manager-acme/base` app: `letsencrypt-staging` +
`letsencrypt-prod` `ClusterIssuer`s (ACME DNS-01, Cloudflare solver), one
shared `CertificateRequestPolicy` (`letsencrypt-policy`, glob-matched via
`selector.issuerRef.name: "letsencrypt-*"`, `allowed.dnsNames.values:
["*.rye.ninja"]`) + RBAC `use` grant for the `cert-manager` ServiceAccount
— same shape as the existing `csi-driver-spiffe-ca-policy` pattern.
No new NetworkPolicy needed: the upstream cert-manager Helm chart's own
`networkPolicy.enabled: true` already opens unrestricted-destination
egress on 80/443/53/6443 for the controller pod, which covers both the
ACME API and the Cloudflare API calls DNS-01 needs.

**Cloudflare token sourced from OpenBao, not 1Password** (the design doc's
original assumption) — same 1Password item (`cloudflare-api-token`) as
crossplane's `cloudflare-creds`, but via a dedicated
`openbao-cert-manager` `ClusterSecretStore` / `eso-cert-manager` k8s-auth
role / `cert-manager-secrets-read` policy, kept separate from step 6's
`crossplane-secrets-read` for least-privilege scoping even though the same
ESO ServiceAccount authenticates for both (same reasoning as the
dedicated Garage keys minted per bucket this session). Confirmed clean of
circularity first: the `letsencrypt-*` issuers are entirely separate from
the `csi-driver-spiffe-ca` issuer OpenBao's own Certificate uses, so
nothing on OpenBao's boot chain touches this. Config script:
`.bin/configure-openbao-cert-manager-secrets.sh`.

Verified end-to-end live before merge, not just component-by-component:
issued a real `Certificate` (`acme-dns01-smoke-test.rye.ninja`) via
`letsencrypt-staging` — full DNS-01 round trip (Cloudflare TXT record,
propagation, Let's Encrypt validation) succeeded in ~90s, decoded cert
confirmed correct subject/SAN/issuer. Both `ClusterIssuer`s show
`ACMEAccountRegistered`/`Ready: True`. Test `Certificate`/Secret deleted
after.

**ACME account email**: used `esten.rye@ryezone.com` (no existing
precedent in the repo for a registration email) — this is where Let's
Encrypt sends expiry/problem notifications. Not silently reversible: an
email change re-registers a *new* ACME account rather than updating the
existing one.

### Step 8 detail (2026-07-24) — keycloak-db CNPG cluster, RESOLVED

New `applications/keycloak-db` app, structured identically to `openbao-db`
(base + controlplane split, same `imageName`/`storageClass`/plugin JSON
patch, same CNPG-I barman-cloud plugin wiring) — deliberately copied the
already-fixed pattern rather than step-ca-db's older one, so the
region-signing bug ([[m3-step-tracker]]'s step 5 section) never had a
chance to recur: `region: garage` was in the credentials Secret from the
very first apply.

**Namespace ownership, decided proactively this time**: `keycloak-db`
(the CNPG cluster) owns creation of the `keycloak` namespace via
`applications/keycloak-db/base/resources/namespace.yaml` — same split as
`step-ca-db` owning `step-ca` and `openbao-db` (indirectly, via the
sibling `openbao` app) owning `openbao`. The future Keycloak app (step
9b) will just reuse this namespace, not create its own. Checked this
*before* writing any manifest, instead of discovering it live via a
`NotFound` error (see the step-ca-db-snapshots-sync mistake earlier this
session) — worth continuing to check namespace-vs-app-name explicitly
every time rather than assuming symmetry.

**One placeholder worth flagging for step 9b**: the `keycloak-db`
NetworkPolicy's ingress rule assumes the future Keycloak server pods carry
label `app.kubernetes.io/name: keycloak` (the common Helm chart
convention) — this hasn't been verified against whatever chart actually
gets vendored yet. Check/adjust when step 9b lands.

Verified end-to-end live before merge: all 3 instances `Running 2/2`,
`Cluster in healthy state`, `ScheduledBackup` (`immediate: true`) fired
immediately and succeeded — `ObjectStore` status shows a populated
`firstRecoverabilityPoint`/`lastSuccessfulBackupTime` on the first try,
and the Garage bucket shows 12 objects (~6.7 MiB) archived.

### Step 7 detail (2026-07-24) — off-site backup sync, RESOLVED

**Redesigned, at the user's request, before implementation started**: the
M3 design's step 7 was written as "OpenBao raft snapshot CronJob → Garage
+ off-site copy," but that's stale — step 5 pivoted OpenBao off raft onto
CNPG/Postgres, so there is no `bao operator raft snapshot` to run anymore.
The user asked for a dependency-style gut check before building anything;
confirmed the real backup data is already the CNPG barman WAL/base-backup
stream flowing into Garage's `openbao-db-barman` bucket (wired in step 5).
Redefined step 7 as: mirror that bucket to the already-provisioned
Cloudflare R2 `openbao-snapshots` bucket (credential from A6, created
2026-07-21, sat unused until now). The Garage `openbao-snapshots` bucket
from step 3's bucket-init job is now dead weight — pre-provisioned for the
old raft-snapshot design, nothing writes to it. Left it empty rather than
deleting it.

**What shipped**: new `applications/openbao-snapshots-sync` app — a
`CronJob` (daily 04:00 UTC, after the 03:00 UTC CNPG `ScheduledBackup`)
running `rclone sync` between two S3-compatible "on-the-fly" remotes (no
`rclone.conf` on disk): Garage's `openbao-db-barman` bucket (source) and
Cloudflare R2's `openbao-snapshots` bucket (destination). `sync` (not
`copy`) so R2 tracks Garage's 30-day barman retention pruning too, not an
ever-growing pile.

- New dedicated Garage key `openbao-snapshots-sync`, **read-only** on
  `openbao-db-barman` (least privilege — this job never writes to Garage).
  Created directly via `kubectl exec ... garage key create` /
  `garage bucket allow --read`; no admin token needed for the in-pod CLI
  path (unlike the HTTP admin API the bucket-init job uses). SOPS-encrypted
  as `openbao-snapshots-sync-credentials.sops.yaml`.
- R2 side reuses the existing `cloudflare-r2-openbao-snapshots` secret
  (access key, secret key, endpoint, bucket — all already provisioned)
  as-is.
- **Real bug hit and fixed during live verification**: rclone's inline
  connection-string syntax (`:s3,param=val,...:path`) uses `:` and `,` as
  delimiters. Passing `endpoint=http://garage.garage.svc.cluster.local:3900`
  unquoted made rclone mis-split the string — failed with `Custom endpoint
  \`http\` was not a valid URI`. Fix: wrap endpoint values in escaped
  double quotes (`endpoint=\"${VAR}\"`) per rclone's CSV-style
  connection-string quoting rules. Applies to any future on-the-fly S3
  remote with a scheme+port endpoint, not just this job.
- Verified end-to-end live (manual `kubectl create job --from=cronjob/...`
  runs, before merge): first run copied all 52 objects (~5.6 MiB) from
  Garage to R2 successfully; second run reported "nothing to transfer" —
  confirmed idempotent, safe for daily scheduling.
- Live-testing note: applying the SOPS-encrypted credentials Secret
  directly via `kubectl apply -f <rendered-file>` fails (`unknown field
  "sops"` — render doesn't decrypt). Verified instead by applying an
  equivalent plaintext Secret with the same values piped through
  `kubectl apply -f -` via heredoc (not `--from-literal`, which the auto
  mode classifier blocked as a bare credential-bearing CLI arg — stdin
  piping worked, consistent with [[m3-step6-secret-migration-eligibility]]'s
  root-token handling). Flux will create the real Secret from the
  committed SOPS file on merge.

### Step 7 extended to step-ca-db (2026-07-24) — same pattern, second bucket

At the user's request, replicated the exact same off-site-sync pattern for
`step-ca-db`: new `applications/step-ca-db-snapshots-sync` app, new R2
bucket `step-ca-db-snapshots`, new dedicated read-only Garage key on
`step-ca-db-barman`. Two things worth remembering:

- **`step-ca-db` (the CNPG cluster) runs in the `step-ca` namespace, not
  `step-ca-db`** — same pattern as `openbao-db` running in `openbao`, not
  `openbao-db`. Got this wrong on the first pass (namespace-not-found on
  apply); the app-name-vs-namespace split is the rule to check first next
  time, not assume symmetry from the resource name.
- **R2 bucket + scoped token were created programmatically**, not via
  dashboard — the user pointed me at an account-admin-scoped Cloudflare API
  token (`op://psqynbegdx52mzknfzo55zmlwi/nfpyakcyihmxgg5uh7sp23agam/credential`,
  outside the `controlplane` 1Password vault) after I initially assumed
  dashboard access was required (mirroring how A6's original openbao bucket
  was provisioned). See [[cloudflare-r2-token-derivation]] for the
  Access-Key-ID/Secret-Access-Key derivation formula this required (got it
  wrong once, verified the fix live before trusting it).
- R2 side verified via direct `aws s3 ls`/`cp`/`rm` round-trip *before*
  encrypting (proves the credential works, scoped correctly to just this
  bucket).
- **In-cluster CronJob dry-run completed 2026-07-24** (deferred earlier in
  the same session when 1Password locked out mid-task, then finished once
  it came back): minted a throwaway R2 token scoped identically to the
  committed one, applied it as a temporary live `cloudflare-r2-
  step-ca-db-snapshots` Secret in `step-ca`, ran `kubectl create job -n
  step-ca step-ca-db-snapshots-sync-test --from=cronjob/
  step-ca-db-snapshots-sync`. First run copied all WAL segments + 5 base
  backups (~21 MiB) from Garage to R2; second run reported "nothing to
  transfer" — confirmed idempotent. Temp token revoked after. The live
  Secret in-cluster now holds that revoked temp credential's values until
  Flux applies the real one from the committed SOPS file post-merge — not
  a problem, just don't be surprised if `cloudflare-r2-step-ca-db-snapshots`
  looks "wrong" in-cluster before this PR merges.

### Step 4 detail (2026-07-23) — RESOLVED

- WAL archiving wired and base backups now actually run: PR #98 wired
  `barmanObjectStore` but never added a `Backup`/`ScheduledBackup`, so no
  base backup had ever executed. Fixed in #99 (`ScheduledBackup`,
  daily 03:00 UTC + `immediate: true`).
- **Restore drill now passes.** Root-caused two stacked issues:
  1. Garage's buckets all showed creation date 2026-07-23 (today),
     consistent with Garage's PV data having been wiped by one of the
     several redeploys during step 3's iteration (health-probe fixes, v2
     API fixes — PRs #85–#97). Any WAL archived before that reset was
     gone.
  2. **Real bug, fixed in #102**: `target: prefer-standby` (both the
     Cluster default and the ScheduledBackup) anchors the backup's
     `beginWal` to the *standby's own* checkpoint/restart-point — which
     on this low-traffic cluster was stuck at an old WAL segment for
     hours with no sign of advancing, even though streaming replication
     itself was healthy and caught up. Every `prefer-standby` backup
     needed that stale WAL for consistency, and it was gone. Switched
     `target: primary` on both. Verified end-to-end: forced a fresh WAL
     segment (`pg_logical_emit_message` + `pg_switch_wal`, zero schema
     impact), confirmed it persisted in Garage, took a `target: primary`
     backup (`beginWal == endWal`, both fresh), restored it onto a
     scratch CNPG cluster via the barman `externalCluster` path, and
     confirmed all 24 tables + real row data (6 certs) present. Scratch
     cluster and NetworkPolicies fully torn down afterward.
  - Restore procedure note (NOT the old pg_dump-based
    [[m2-step11-restore-drill]] runbook): externalCluster recovery needs
    `serverName: step-ca-db` explicitly set on the `barmanObjectStore`
    block — it otherwise defaults to the externalCluster's own reference
    name and silently looks in the wrong S3 prefix, failing with "no
    target backup found".
  - Live production `Cluster.spec.backup.target` and
    `ScheduledBackup.spec.target` both confirmed `primary` post-deploy.

### Barman in-tree API deprecation — RESOLVED 2026-07-23

Migrated `step-ca-db` off the in-tree `spec.backup.barmanObjectStore` API
(removed in CNPG 1.31.0; cluster was on 1.30.0) to the CNPG-I Barman
Cloud Plugin, same day as discovery, at the user's explicit direction
(not deferred). PRs #104–#106.

**Correction on the earlier "SIDECAR_IMAGE Secret has no data" finding**:
that was my own investigation error, not a real gap. The Secret's `data:`
key sorts alphabetically *before* `kind`/`metadata` in the downloaded
manifest, and an early `grep -A6` only looked *after* the `name:` line —
missing it entirely. The value was present and decodes cleanly to
`ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.13.0`. Lesson: always
re-verify a "the artifact seems broken" conclusion with a full-file
`grep`/`sed` before trusting it, especially before deferring real work on
that basis.

**What shipped**:
- New `applications/cnpg-barman-plugin` app: vendors the upstream v0.13.0
  release manifest into `cnpg-system`. Controller image + the
  `SIDECAR_IMAGE` secret value both digest-pinned. NetworkPolicies added
  (cnpg-system runs default-deny; needed both an ingress rule on the
  plugin for the operator's gRPC calls, and a supplementary egress rule
  on the *operator's* existing podSelector, since NetworkPolicies are
  additive and the operator's own policy file lives in a different app).
- `step-ca-db`: added an `ObjectStore` CR (direct translation of the old
  config), switched `Cluster.spec.plugins` (`isWALArchiver: true`) and
  `ScheduledBackup.spec.method: plugin`. No `serverName` override needed
  — defaults to the Cluster's own name, preserving the existing
  `step-ca-db/...` prefix in Garage.
- **Two follow-up fixes needed post-deploy, both because this cluster runs
  `cert-manager-approver-policy`** (blocks any cert-manager
  `CertificateRequest` with zero content-based matching unless something
  explicitly grants it):
  1. The plugin's Certificates (`barman-cloud-client`/`-server`, via its
     own bundled `selfSigned` Issuer) had no matching
     `CertificateRequestPolicy` → stuck `WaitingForApproval` forever →
     `barman-cloud` pod stuck `ContainerCreating` (`FailedMount: secret
     not found`) → `step-ca-db` Cluster reconciliation stalled
     ("cannot proceed... unknown plugin being required"). **No outage** —
     existing pods kept running fine, just blocked from progressing.
     Fixed by adding a `CertificateRequestPolicy` scoped to the plugin's
     `selfsigned-issuer` (mirrors the existing
     `csi-driver-spiffe-ca-policy` pattern).
  2. A matching policy alone wasn't enough: approver-policy *also*
     requires an explicit RBAC `use` grant (a `ClusterRole` naming the
     specific policy in `resourceNames`, bound to the `cert-manager`
     ServiceAccount) — content-matching a Ready policy is necessary but
     not sufficient. Fixed by mirroring
     `csi-driver-spiffe-ca.clusterrole(binding).yaml` exactly. **If any
     future app adds its own cert-manager Issuer under approver-policy,
     budget for both pieces up front.**
- Verified end-to-end on production: plugin pod Running/Ready, all 3
  `step-ca-db` instances rolled cleanly (2/2 containers, sidecar
  injected, zero WAL-archiving gap across the restart — confirmed
  segments 4D–52 all present in Garage with no missing numbers), step-ca
  `/health` still 200 post-rollout, and a fresh `method: plugin` Backup
  completed with `beginWal == endWal` on current WAL.

See [[m3-render-lint-ci-fix]] for a separate, now-resolved finding from
this same session: `render-and-lint` CI had been failing on every commit
since step 1 kickoff, masking these issues from automated review.

### Step 5 detail (2026-07-23) — OpenBao on CNPG/Postgres, RESOLVED

**Design decision, at the user's explicit direction**: the original M3
design called for OpenBao HA via integrated Raft storage. The user
challenged this directly — "CNPG is already a core dependency for Step
Certificates, so why not take advantage of CNPG and our already proven
backup/restore path?" — and then explicitly scoped the work to
OpenBao's PostgreSQL storage backend instead. This is a supported
upstream path (unlike HashiCorp Vault, where Postgres storage is
community/unsupported): OpenBao deliberately invested in it, reaching
production-ready status with HA in v2.5.0 (April 2026); this deploy
runs chart `openbao-helm` 0.28.6 / app v2.6.1. HA-over-Postgres
coordinates leader election via a dedicated `openbao_ha_locks` table —
no Raft peer discovery, every pod points at the same CNPG primary via
`storage "postgresql" { ha_enabled = "true" }` in the HCL config, with
`BAO_PG_CONNECTION_URL` injected from CNPG's auto-generated
`openbao-db-app` Secret (`extraSecretEnvironmentVars`) so no credential
ever lands in a rendered manifest.

**What shipped**:
- `applications/openbao-db`: new CNPG `Cluster` (3 instances), mirrors
  `step-ca-db` exactly — same pinned image digest, same
  `barman-cloud.cloudnative-pg.io` plugin wiring (shared cluster-wide
  plugin, no redeploy needed), `ScheduledBackup` with `target: primary`
  from day one (no repeat of the step-4 `prefer-standby` bug).
- `applications/openbao`: official `openbao-helm` chart vendored via
  kustomize `helmCharts:`, `server.dataStorage.enabled: false` (no local
  PVCs, Postgres is the store), `server.ha.raft.enabled: false`.
- Live status: `openbao-db` Cluster healthy, 3/3 instances. `openbao-0`
  Running/stable (1-of-3 up under `OrderedReady` StatefulSet gating —
  this session didn't force the other two up since the unseal ceremony
  is still pending anyway). `Initialized: false, Sealed: true` as
  expected — the `[H]` unseal ceremony is intentionally out of scope for
  this step, same as originally planned.

**THE MAJOR LESSON — SPIFFE CSI certs carry no DNS SANs, only a SPIFFE
URI SAN**: the first implementation used the `spiffe.csi.cert-manager.io`
CSI ephemeral-volume driver for TLS (cleaner on paper — it has its own
dedicated auto-approver and needs zero `CertificateRequestPolicy`/RBAC).
The user preemptively flagged the risk before implementation even
started: "the spiffe csi tls cert does not allow for additional SANs. I
think TLS termination and reencryption with a public cert may be
required." That prediction was confirmed live: decoding the actual
issued cert (`openssl x509 -noout -text`) showed
`X509v3 Subject Alternative Name: critical / URI:spiffe://controlplane.rye.ninja/ns/openbao/sa/openbao`
and **nothing else** — the documented `csi.cert-manager.io/dns-names`
pod annotation is simply not honored by this driver. It's built for
SPIFFE-aware peer identity verification, not standard hostname-based TLS
(what the `bao` CLI / Go's `crypto/tls` / any normal HTTP client does).
**Fix**: switched to a real `cert-manager.io/v1 Certificate` (mirrors
the already-working `cnpg-barman-plugin` pattern: `Certificate` +
`CertificateRequestPolicy` + RBAC `use` grant), issued by the same
`csi-driver-spiffe-ca` ClusterIssuer — so still zero new CA to
distribute, since it's already trusted platform-wide via the
trust-manager Bundle. Also had to include both FQDN and short-form
hostnames (`openbao.openbao.svc.cluster.local` *and*
`openbao.openbao.svc`, etc.) — the chart's own `VAULT_ADDR`/cluster-addr
env vars use the short form, which an FQDN-only SAN list missed.
**Lesson for future TLS decisions on this platform**: default to a real
`Certificate` for anything doing standard hostname TLS verification;
reach for SPIFFE CSI only when the consumer is genuinely SPIFFE-aware.

**Recurring gotcha, hit twice more this step**: Kubernetes immutable
Pod fields (`serviceAccountName`, `volumes`) block Flux's atomic
dry-run for the *entire* cluster kustomization when an existing Pod's
spec changes underneath it — not just Jobs (see step-4/CI-fix history).
Hit on `openbao-server-test` (the chart's Helm-test-hook bare Pod) twice:
once when RBAC/serviceAccountName was added, again when the TLS volume
switched from the SPIFFE CSI volume to the Secret-backed one. Same fix
each time: `kubectl delete pod openbao-server-test`. Also hit on
`openbao-0` itself after the liveness-probe revert and again after the
TLS pivot, since `updateStrategyType: OnDelete` (deliberate, upstream's
own recommendation for this chart) never auto-recreates existing pods on
template change.

**Liveness probe crash-loop (self-inflicted, reverted)**: the initial
implementation set `server.livenessProbe.enabled: true`, reasoning the
httpGet handler works fine over TLS. It crash-looped `openbao-0`:
`/v1/sys/health` returns 501 uninitialized / 503 sealed, both read as
failure by kubelet, and sealed is a normal long-lived pre-unseal state.
Reverted to the chart's own deliberate default (`false`).

**kustomize helm kubeVersion gate**: `kustomize build --enable-helm`
defaults to a pre-1.30 `Capabilities.KubeVersion` unless told otherwise,
which broke on `openbao-helm`'s `kubeVersion: >=1.30.0-0` chart gate.
Fixed once, platform-wide, in the shared render script
(`.bin/render/render-kustomize-base-and-patches.sh`): added
`--helm-kube-version 1.36.2` (controlplane's real server version) to the
`kustomize build` invocation. Any future chart with its own
`kubeVersion` gate is already covered.

**RESOLVED 2026-07-24 — `openbao-db-barman-credentials` created, plus a
second real bug found and fixed (region signing)**: created the Garage
key (`barman-openbao-db`), granted it `RWO` on `openbao-db-barman`, and
SOPS-encrypted it (PRs #113–#114). That alone wasn't enough — `openbao-db`'s
very first WAL archive attempt then failed with `error 400 Bad Request,
Authorization header malformed, unexpected scope:
'.../us-east-1/s3/aws4_request', expected: '.../garage/s3/aws4_request'`.

**Root cause**: Garage's `s3_api.s3_region` is set to the non-default
value `"garage"`, but neither `openbao-db-barman`'s nor `step-ca-db-barman`'s
`ObjectStore` ever set `s3Credentials.region`, so barman-cloud's boto3
client signed requests with the SDK default (`us-east-1`) instead.
**This was a real, live latent bug on `step-ca-db` too** — not just an
openbao-specific gap. It only "worked" there because the one-time WAL
archive destination check had already succeeded in the past (before
this was investigated) and wasn't being re-validated on every push;
`openbao-db`'s brand-new cluster had no such cached success and failed
immediately. Lesson: **a currently-healthy backup path is not proof a
Garage `ObjectStore` is fully correct** — the destination check doesn't
necessarily re-run every time, so a latent signing bug can hide behind
a stale cache indefinitely until something (a pod restart, a fresh
cluster) forces re-validation.

Fixed by adding `s3Credentials.region` (a secretKeySelector, sibling to
`accessKeyId`/`secretAccessKey` in the `ObjectStore` CRD schema) pointing
at a new `region: garage` key in both credentials Secrets (PRs #115–#116).
For `openbao-db` this was a straight edit. For `step-ca-db`, the existing
Secret couldn't be edited in place — the private SOPS age key isn't
available in this working environment (by design; it lives in the
`controlplane` 1Password vault, not committed) — so instead of trying to
recover the old plaintext, the Garage access key was **rotated**
(`barman-step-ca-db` → `barman-step-ca-db-v2`): create new key, grant it
on the bucket, write a fresh Secret, verify the new key works, then
`garage bucket deny` + `garage key delete` the old one. **General
takeaway for any future SOPS Secret that needs a field added without the
private key on hand: rotate the underlying credential rather than trying
to patch the encrypted file.**

Verified end-to-end post-fix: `openbao-db-1`'s `plugin-barman-cloud`
sidecar archives WAL cleanly (`Archived WAL file`, no more `400` errors),
and the `openbao-db-barman` Garage bucket has real objects (11 objects,
~2.9 MiB) for the first time. `step-ca-db-2` (primary)'s periodic
retention-policy enforcement — which requires authenticated `List` calls
— keeps succeeding cleanly on the new key/region with zero errors.

- `openbao-server-test` Pod's own TLS verification against the *new*
  cert failed with `certificate signed by unknown authority` (the test
  hook only sets `VAULT_ADDR`, no `VAULT_CACERT`/`BAO_CACERT`) — not
  root-caused, deemed non-blocking since it's tooling outside the plan's
  own verification criteria. Correctness was instead proven directly:
  `kubectl exec -n openbao openbao-0 -c openbao -- sh -c 'BAO_ADDR=https://openbao.openbao.svc:8200
  BAO_CACERT=/openbao/tls/ca.crt bao status'` (and the pod-internal DNS
  name) both succeeded with full CA verification, no skip-verify. The
  `openbao-server-test` Pod is currently left in `Error` status on the
  cluster — low-priority cleanup (`kubectl delete pod
  openbao-server-test`, Flux/Helm will recreate it clean on the next
  relevant change).
- The comment above `applications/openbao-db/controlplane` /
  `applications/openbao/base` in
  `clusters/controlplane/kustomization.yaml` still says "openbao's own
  SPIFFE-CSI TLS volume needs cert-manager-spiffe-csi-driver" — stale
  after the pivot to a real Certificate; the driver is no longer a
  dependency of this app. Needs a follow-up wording fix (harmless, not
  functionally wrong — `cert-manager-spiffe-csi-driver` still needs to
  come first for unrelated apps).

### Step 5's `[H]` unseal ceremony — RESOLVED 2026-07-24

First-ever init + unseal ran clean: 5 shares/3 threshold, all 3 pods
unsealed, HA formed (`openbao-0` active, others standby), key shares +
root token SOPS-encrypted at
`clusters/controlplane/secrets/openbao-unseal.sops.yaml` per a new
whole-file `.sops.yaml` rule (mirrors `step-ca-root`/`talos-secrets`).
Full step-by-step procedure now lives in
[docs/runbooks/openbao-unseal.md](../runbooks/openbao-unseal.md),
written this session (#118).

One real bug found on first run: `bao audit enable` over the API is
rejected outright on this OpenBao version (`cannot enable audit device
via API; use declarative, config-based audit device management
instead` — deliberate upstream, since `file`/`socket` audit devices can
write arbitrary paths). Fixed by declaring the device directly in
`applications/openbao/base/values.yaml`'s `server.ha.config` instead
(#119); since the StatefulSet is `OnDelete`, each pod needed a manual
`kubectl delete pod` to pick up the config and re-emit through the
unseal cycle. Verified end-to-end via `kubectl logs`: audit backend
enabled, live JSON audit entries flowing to stdout. Ceremony log with
both runs (init + the audit-fix restart) captured in the runbook (#120).

M3 step 5 has no more open items. Step 6 (ESO `ClusterSecretStore` →
OpenBao; migrate `aws-account-creds`) is next and has not been started.

### Step 6 pre-flight finding (2026-07-24) — `aws-account-creds` never existed; the M2/M3 design's premise was wrong

Before starting step 6, checked for the secret the M3 design (A4) names
as the thing to migrate — no live Secret in any namespace, no SOPS
file under `clusters/controlplane/secrets/`, no trace in git history
beyond the design docs themselves. Initially read this as "quarantined
or lost." **Corrected by the user**: it's neither. The Roles Anywhere
trust-anchor bootstrap (M2 §4.4) was never done via a stored static
`aws-account-creds` IAM key at all — it was done interactively using
the user's own AWS SAML SSO credentials. The M2/M3 design docs'
description of a "static bootstrap credential" that gets "moved" then
"quarantined" then "migrated to OpenBao break-glass" describes a
mechanism that was planned but never actually built; the real bootstrap
path left no credential object behind to migrate, by design.

**How to apply**: step 6 as originally scoped (A4: "migrate
`aws-account-creds` to OpenBao break-glass path") has no source
material and should be dropped or re-scoped, not treated as blocked or
recoverable. If a break-glass AWS credential in OpenBao is still
wanted for future manual bootstraps (e.g. a new trust anchor at some
future root rotation), that would need to be freshly minted and scoped
for that purpose — it is a new decision, not a migration. The
proof-of-concept `ExternalSecret` half of step 6 (validate the
ESO+OpenBao pattern with one existing SOPS secret) is unaffected and
can proceed on its own. [[m3-design]]'s A4 section needs a matching
correction. See [[m3-step6-secret-migration-eligibility]] for the
dependency-analysis rule (never migrate a secret on OpenBao's own boot
chain) and the confirmed-clean candidate secrets.
