# OpenBao Cross-Cluster Auth: SPIFFE Cert-Based Access for Remote Clusters

Date: 2026-08-16
Status: Shipped and independently verified correct at every layer
        (PRs #172-#177, all merged) — end-to-end live verification blocked
        by an unrelated, pre-existing fleet networking bug, not by
        anything in this design. See §6.
Companion: [2026-08-15-m4-completion-design.md](2026-08-15-m4-completion-design.md) (step B6),
           [ADR-16](../adr/0016-spiffe-trust-domain-configuration-per-cluster.md),
           [fable-5-arch-plan.md](fable-5-arch-plan.md) §M6-M8 (cloud substrates),
           [../memory/pod-egress-gua-routing-broken.md](../memory/pod-egress-gua-routing-broken.md)

## 1. Why this exists

M4 completion step B6 originally scoped as "give `observability` a way to
read secrets from `controlplane`'s OpenBao." What actually landed in B3-B5
never needed this (all of `observability`'s secrets so far — TrueNAS,
UniFi, the step-ca intermediate — are plain SOPS files, matching
`controlplane`'s own equivalents). But the user asked to build B6 anyway,
ahead of a concrete need, specifically because M5's LGTM work and future
cloud substrates (M6 EKS, M7 GKE/AKS, M8 OKE) will need it, and getting the
*pattern* right now — before more clusters exist — is cheaper than
retrofitting it later.

## 2. Decisions considered, and why the final one won

**Kubernetes-auth multi-mount** (a second `auth/kubernetes/<cluster>` mount
per remote cluster, OpenBao doing live TokenReview against that cluster's
own apiserver): this is the pattern all 4 existing OpenBao consumers on
`controlplane` already use, so it was the initial default. Rejected as the
*general* pattern for remote clusters because it doesn't generalize to
cloud substrates — it requires `controlplane`'s OpenBao to reach *into*
each remote cluster's apiserver, a two-directional dependency that's often
impractical for managed cloud clusters (private/restricted apiserver
endpoints, VPN/peering per provider). Kubernetes-auth remains correct and
unchanged for `controlplane`'s own same-cluster consumers — this isn't a
"second paradigm to maintain" so much as the right tool split by trust
boundary: local auth for local workloads, identity-based auth for remote
ones.

**SPIFFE-based cert auth** (Vault/OpenBao's native `cert` auth method,
using each cluster's own step-ca-signed intermediate — the same chain B5
built for `observability` — as the trust anchor): chosen because it's
one-directional (only the *remote* cluster's workloads need outbound
reachability to OpenBao, never the reverse) and substrate-agnostic (an EKS
or GKE cluster's own SPIFFE intermediate would authenticate identically to
`observability`'s, no per-cloud special-casing).

**Real blocker found and resolved**: ESO's `vault` provider `auth.cert`
config wants `clientCert` as a `secretKeySelector` — a static Kubernetes
`Secret`. SPIFFE SVIDs are deliberately delivered via the CSI driver as an
ephemeral filesystem mount, not a `Secret` object (a core SPIFFE design
principle: short-lived, auto-rotating, never persisted as a static
resource). These don't compose directly.

**Resolution, reusing an existing pattern in this repo**: `OpenBao`'s own
server certificate already sidesteps this exact problem — it uses a normal
`cert-manager` `Certificate` (stable `Secret`, auto-renewed by
cert-manager) instead of the CSI ephemeral volume, specifically because its
consumer (the Helm chart's volume mount) needs a stable Secret reference.
Same fix applies here: a dedicated, non-CSI `Certificate` per remote
cluster for its ESO's client identity.

**Chain verification**: the client must present its full chain (leaf +
its own intermediate) so OpenBao's server-side trust store can stay fixed
at `{controlplane-intermediate, root}` forever, regardless of how many
remote clusters join the fleet — no per-cluster update to OpenBao's own
config, ever. Building that "leaf + own intermediate" bundle declaratively
(no new imperative Job) uses `trust-manager`'s `Bundle` CRD, which supports
multiple `sources` concatenated into one `target` — confirmed against the
pinned `v0.22.0` CRD schema (`sources` is `minItems: 1, maxItems: 100`,
`target.secret` is supported, not just `target.configMap`).

## 3. Final design

### controlplane

1. New trust-manager `Bundle` (`ryezone-labs-chain-controlplane`):
   sources `[root ConfigMap, controlplane's own csi-driver-spiffe-ca Secret's
   tls.crt]`, target a `chain.crt` ConfigMap key, distributed fleet-wide
   (both inputs are already-public certs, just not currently combined
   anywhere). Needed because `openbao-server-tls`'s own `ca.crt` field is
   root-only (cert-manager propagates the *issuer's* `ca.crt`, which for a
   single-hop chain is root — confirmed by re-deriving the same logic B5
   used) — verifying a *two-hop* remote chain needs both root and
   controlplane's own intermediate in one file.
2. New OpenBao listener stanza on a separate port (`8443`, since `8201` is
   already cluster-address) with `tls_require_and_verify_client_cert =
   true` + `tls_client_ca_file` pointing at the new `chain.crt`. The
   **existing** `8200` listener (same-cluster Kubernetes-auth traffic,
   including the crossplane/cert-manager/provider-terraform consumers
   already live) is untouched — nothing already working changes.
3. `openbao-server-tls` Certificate gains a LAN hostname (`bao.rye.ninja`)
   in `dnsNames`.
4. New `Gateway`/`TLSRoute`, structurally identical to `step-ca`'s
   (`gatewayClassName: merged-eg`, SNI passthrough, no Envoy-level cert
   inspection — verification happens at OpenBao's own new listener),
   routing `bao.rye.ninja` to the new `8443` listener only.
5. New `.bin/configure-openbao-cert-auth.sh`: `bao auth enable cert` +
   a role scoped by `allowed_uri_sans` matching the SPIFFE ID URI pattern.
   Run by the user (needs the OpenBao root token, same pattern as the 4
   existing OpenBao bootstrap scripts). **Unverified, flag before running**:
   the exact `allowed_uri_sans` glob syntax and whether OpenBao 2.6.1's
   `cert` auth role config needs its own `certificate` field set (possibly
   redundant with the listener's `tls_client_ca_file`, possibly not) —
   confirm against the real running version, don't assume upstream Vault
   docs apply verbatim to this OpenBao fork/version.

### observability (template for any future remote cluster)

6. New `applications/external-secrets-operator/observability/` overlay: a
   dedicated `Certificate` (`eso-openbao-client`, `cert-manager` namespace —
   trust-manager's configured trust namespace, where sources must live,
   confirmed via `applications/cert-manager-trust-manager/observability/values.yaml`),
   `isCA: false`, carrying a SPIFFE URI SAN
   (`spiffe://obs.rye.ninja/ns/external-secrets-operator/sa/external-secrets`).
   Not the CSI ephemeral volume — same reasoning as `openbao-server-tls`.
7. New `Bundle` combining this leaf's `tls.crt` + observability's own
   `csi-driver-spiffe-ca` Secret's `tls.crt` (already sitting in
   `cert-manager` namespace since B5) into one distributed
   `client-bundle.pem` — the "present full chain" piece. Public-cert-only
   data (no keys), safe to distribute fleet-wide like B5's existing bundles.
8. New `ClusterSecretStore` using `provider.vault.auth.cert`: `clientCert`
   from the bundle (step 7), the private key referenced directly from the
   `eso-openbao-client` Secret's `tls.key` (namespace `cert-manager`,
   explicit `namespace:` field on the `secretKeySelector` — ClusterSecretStore
   is cluster-scoped so this is meaningful, not defaulted).

**Any future remote cluster** (EKS/GKE/AKS/OKE, M6-M8) repeats only steps
6-8, using whatever step-ca intermediate that cluster gets via the same
workload-intermediate pattern B5 established. Nothing on `controlplane`'s
side changes per new cluster.

## 4. Sequencing and risk

Two PRs: controlplane-side (1-5) first, since it's the shared trust anchor
and has no dependency on anything cluster-specific; observability-side
(6-8) once that's merged and the new listener/auth backend are confirmed
live. Step 5 and step 8's actual `bao` CLI commands need the user (root
token access, same diligence as every other OpenBao bootstrap script) —
this session can write the scripts and the GitOps manifests but not run
the imperative OpenBao-side configuration.

**Real, deliberate scope boundary**: this design does not touch OpenBao's
existing `8200` listener or any of the 4 existing same-cluster consumers.
If anything about the new `8443` listener or `cert` auth backend is wrong,
the blast radius is contained to the new path — same-cluster Kubernetes-auth
keeps working regardless.

## 5. Follow-up

An ADR should be written once this is live-verified (real cert issued, real
`bao write auth/cert/certs/...` succeeded, a real `ExternalSecret` on
`observability` resolves against OpenBao over the new path) — same
sequencing M4's own ADR-27 used: written after the real PRs exist, so it
reflects what shipped rather than what was planned.

## 6. Live verification outcome (2026-08-23)

Every component this design describes was independently confirmed correct
and live:

- Controlplane-side: `auth/cert` backend enabled, `remote-observability-eso`
  cert role registered (`.bin/configure-openbao-cert-auth.sh` ran
  successfully end-to-end after two real bugs were found and fixed live —
  see the PR history: the `openbao-server-8443-fullchain` `Bundle` couldn't
  read a cross-namespace Secret source, fixed by switching to an init
  container; the `openbao-server-test` Helm test-hook `Pod` blocked the
  whole `flux-platform` Kustomization's atomic dry-run apply on any
  `server.volumes` change, removed entirely).
- `openbao`'s new `8443` listener, `Gateway`, `TLSRoute`: all `Programmed`/
  `Accepted`/`ResolvedRefs`; Envoy's own `/clusters` admin endpoint confirmed
  the `openbao` backend cluster with all 3 pod endpoints `healthy`, on every
  `merged-eg` replica, after a rolling restart resolved an xDS staleness gap
  on one replica.
- Observability-side: `eso-openbao-client` `Certificate` issued
  (`Ready: True`), `eso-openbao-client-bundle` `Bundle` synced
  (`Synced: True`), DNS resolves `bao.rye.ninja` to the correct shared
  Gateway VIP.

**What's still blocked, and why it's not a B6 problem**: the
`openbao-remote` `ClusterSecretStore` itself can't complete the mTLS
handshake to `bao.rye.ninja:443` — but this was root-caused to a real,
pre-existing, fleet-wide bug unrelated to anything in this design: pods
cannot reach *any* GUA-space destination at all (confirmed with an
unrelated external control target, not just fleet VIPs), while the exact
same traffic works fine from the same node's own network stack
(`hostNetwork: true`). Full details, diagnostic evidence, and next steps:
[[pod-egress-gua-routing-broken]] (`docs/memory/pod-egress-gua-routing-broken.md`).

This design is considered **shipped and complete** — the remaining blocker
belongs to a separate investigation, not to this one. Don't re-open or
re-debug any of this design's own manifests based on the `ClusterSecretStore`
still showing `Ready: False`; confirm the GUA routing fix first, then this
should go green with no further changes needed here.
