# 26. Keycloak + Pinniped Fleet Identity

Date: 2026-07-25

## Status

Accepted

## Context

M3 introduced human/service identity for the fleet: a single OIDC
identity provider (Keycloak) federated into Kubernetes RBAC via Pinniped,
so cluster access no longer requires distributing a static admin
kubeconfig per person. Full design:
[2026-07-21-m3-identity-secrets-design.md](../superpowers/specs/2026-07-21-m3-identity-secrets-design.md)
§A5, §A7.

## Decision

**Keycloak**: realm `ryezone-labs`, deployed via the `codecentric/keycloakx`
Helm chart against the **upstream** `quay.io/keycloak/keycloak` image (not
Bitnami's chart/image — Bitnami's registry moved to a paid subscription
mid-2025, and its chart hardcodes Bitnami-specific paths/entrypoint
assumptions that don't carry over to the upstream image). Realm config is
declarative, reconciled by a hand-rolled `keycloak-config-cli`
(`adorsys/keycloak-config-cli`) Job — `keycloakx` has no bundled
config-cli integration the way Bitnami's chart did. Backed by a dedicated
`keycloak-db` CNPG cluster (same barman-to-Garage pattern as every other
stateful platform service). Exposed at `https://id.rye.ninja` via Envoy
Gateway HTTPS-terminate + a Let's Encrypt (`cert-manager-acme`,
DNS-01/Cloudflare) certificate — Keycloak has a real plain-HTTP listener
internally, so terminating TLS at the Gateway and proxying plain HTTP to
the pod is safe.

**Group model (A7)** — per-app groups, no shared `platform-admin`
catch-all, asserted as an OIDC `groups` claim (a dedicated `groups`
client scope with an `oidc-group-membership-mapper`, `full.path: false`
so the claim value is the bare group name):

| Group | Binds to |
|---|---|
| `k8s-admin` | `ClusterRole` `cluster-admin` via a Pinniped `ClusterRoleBinding` |
| `k8s-viewer` | `ClusterRole` `view` via a Pinniped `ClusterRoleBinding` |
| `keycloak-admin` | Keycloak's built-in `realm-management` `realm-admin` composite role |
| `openbao-admin` | reserved — OpenBao's own OIDC auth-method policy binding is out of M3's scope |
| `openbao-operator` | reserved — same as above |

Keycloak's local admin credential (not an OIDC identity — the recovery
path if Keycloak's own OIDC-dependent admin console access is broken) is
a SOPS-encrypted bootstrap secret, with a break-glass copy in OpenBao at
`secret/platform/keycloak/local-admin`.

**Pinniped**: Supervisor + Concierge, `v0.47.0`, deployed from upstream's
raw release manifests (no Helm chart exists). Supervisor federates
Keycloak (`OIDCIdentityProvider` against `id.rye.ninja`) and issues its
own tokens as `https://sso.rye.ninja` (`FederationDomain`); Concierge
validates those tokens (`JWTAuthenticator`, audience
`controlplane-rye-ninja`) and issues short-lived client certificates via
`TokenCredentialRequest`, using the `kube-cert-agent` mechanism to
discover the cluster's real signing CA from the `kube-controller-manager`
static pod. `k8s-admin`/`k8s-viewer` bind to `cluster-admin`/`view` via
plain `ClusterRoleBinding`s with `Group` subjects — no impersonation
proxy, no custom webhook.

**Deviation from A5's literal wording**: A5 specified both `id.rye.ninja`
and `sso.rye.ninja` terminate TLS at Envoy Gateway, matching Keycloak's
pattern. In practice, **the Supervisor terminates its own TLS** (TLS
Passthrough at the Gateway, the same mechanism `ca.rye.ninja`/step-ca
already used) — the Supervisor has no plain-HTTP listener mode at all,
and upstream's own documentation explicitly warns against terminating
TLS in front of it without re-encrypting to the backend, since the OIDC
protocol's tokens would otherwise cross the pod network unencrypted. TLS
Passthrough with the Supervisor's own Let's Encrypt certificate achieves
the same end (a publicly-trusted cert, since these are browser-facing
OIDC endpoints) with no added complexity — no `BackendTLSPolicy` needed
for re-encryption.

**A cluster-level prerequisite this design didn't anticipate**: Talos
disables `kube-apiserver --anonymous-auth` by default (unlike vanilla
kubeadm). Pinniped's `TokenCredentialRequest` mechanism is deliberately
designed to be callable with zero prior credentials — the JWT rides in
the request body specifically so the call itself doesn't need apiserver
authentication first — and Talos's default silently broke this at the
apiserver's own authentication layer, before RBAC or Concierge ever saw
the request. Re-enabling `anonymous-auth` (matching vanilla Kubernetes'
own default) was required for Pinniped login to work at all; this only
activates two RBAC bindings that already existed and were reviewed
before the change: Pinniped's own `pinniped-concierge-pre-authn-apis`
ClusterRole (`create`/`list` on `TokenCredentialRequest`/
`WhoAmIRequest` only) and the stock `system:public-info-viewer` binding
present on any vanilla cluster. See
[docs/memory/m3-step-tracker.md](../memory/m3-step-tracker.md)'s step 10
section for the full diagnosis.

**OIDC clients**: `pinniped-supervisor` (confidential, used by the
Supervisor to authenticate its own upstream requests to Keycloak) is the
only application-defined client at M3. Pinniped's CLI-facing client,
`pinniped-cli`, is a static public client baked into the Supervisor
binary itself (PKCE, no secret) — not something this repo creates or
manages.

## Consequences

- Cluster access for any human now runs through Keycloak — Keycloak (and
  by extension `keycloak-db`) becoming unavailable means no new Pinniped
  logins can complete, though already-obtained client certificates keep
  working until they expire. The local admin credential (SOPS + OpenBao
  break-glass) is the recovery path if the OIDC chain itself is broken.
- Re-enabling `anonymous-auth` is a cluster-wide apiserver flag, not
  scoped to Pinniped specifically — any future workload that adds a
  `system:unauthenticated` RBAC binding becomes immediately reachable
  too. This is a real, if narrow, expansion of trust surface that should
  be weighed each time a new `system:unauthenticated`/
  `system:authenticated` binding is proposed.
- The Supervisor and Keycloak use two different TLS termination models at
  the same shared Envoy Gateway (`merged-eg`) — Terminate for Keycloak,
  Passthrough for the Supervisor. Both share the same underlying
  LoadBalancer Service and post-DNAT containerPort quirk
  ([docs/memory/calico-networkpolicy-dnat.md](../memory/calico-networkpolicy-dnat.md)),
  which is easy to miss when writing NetworkPolicy egress rules for a
  new app that talks to either public hostname from inside the cluster.
- `keycloak-config-cli` and Pinniped's `kube-cert-agent`/aggregated
  `APIService`/`CredentialIssuer` resources are rendered across multiple
  Kubernetes namespaces (`keycloak`, `pinniped-supervisor`,
  `pinniped-concierge`, plus cluster-scoped and `kube-system`/
  `kube-public` resources) from a single kustomize app directory — normal
  for Flux (which applies everything atomically), but a trap for any
  future manual/break-glass `kubectl apply` against the rendered output:
  a namespace-scoped `kubectl apply -f <app-dir>/` silently skips
  anything destined for a different namespace.
