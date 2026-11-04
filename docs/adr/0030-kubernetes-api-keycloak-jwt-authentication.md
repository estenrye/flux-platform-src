# 30. Kubernetes API authentication with Keycloak JWTs

Date: 2026-11-03

## Status

Accepted

Supplements [29. Keycloak on core-infra, Pinniped withdrawn](0029-keycloak-on-core-infra-pinniped-withdrawn.md):
Pinniped stays withdrawn, and people authenticate to the API server directly.

## Context

People need cluster access driven by Keycloak groups, for example the
`ACL_Grafana_DbBackupOperator` restore Role in `applications/grafana-db`.
Pinniped was reconsidered and rejected for now: with one identity provider and
few clusters its Supervisor, Concierge, aggregated APIs, kube-cert-agent and
scoped anonymous access are more overhead than the fleet justifies. Kubernetes
1.37 (Talos 1.14) supports JWT authenticators in `AuthenticationConfiguration`
(stable since 1.34), so the API server can validate Keycloak ID tokens itself.

## Decision

- The API server trusts `https://id.rye.ninja/realms/ryezone-labs` with
  audience `kubernetes`, configured through Talos `KubeAuthenticationConfig`
  in `pcd-ce-deploy/tofu-pcd-talos-cluster` (variable `enable_oidc_auth`; issuers are the list variable `oidc_issuers`, so a CI issuer
  can be added alongside Keycloak). Username is the `email` claim (required verified), groups
  come from the `groups` claim, both without prefix. Usernames and groups with
  a `system:` prefix are rejected.
- Keycloak has a public client `kubernetes` (authorization code + PKCE,
  loopback redirects `http://localhost:8000` and `:18000`), used by
  `kubectl oidc-login` (kubelogin).
- Group model, bare group names in the `groups` claim:

  | Group | Scope | Binds to |
  |---|---|---|
  | `ACL_Kubernetes_cluster-admin` | every cluster | `cluster-admin` |
  | `ACL_Kubernetes_view` | every cluster | `view` |
  | `ACL_Kubernetes_cluster-admin_core-infra` | core-infra | `cluster-admin` |
  | `ACL_Kubernetes_view_core-infra` | core-infra | `view` |

  Bindings are in `clusters/core-infra/resources/rbac.kubernetes-groups.yaml`.
  Narrower per-app groups such as `ACL_Grafana_DbBackupOperator` bind to
  namespaced Roles. Other clusters bind the unsuffixed groups plus their own
  `_<cluster>` pair.
- Anonymous access is limited to the health endpoints (`/livez`, `/readyz`, `/healthz`), as in Talos's default.

## Consequences

- The API server runs on the host network and must reach `id.rye.ninja`
  (OIDC discovery and keys) from the control-plane nodes. Verified 2026-11-03:
  a host-network pod on talos-controlplane-1 got HTTP 200 for the realm's
  discovery document.
- Keycloak being down means no new logins or refreshes. Certificate-based
  admin access (`talosctl kubeconfig`) remains the break-glass path.
- ID tokens cannot be revoked, so keep the Keycloak access-token/session
  lifespans short.
- Each new cluster needs the same Talos setting; the Keycloak client can be
  shared, or given a per-cluster audience if separation is wanted.
- If the fleet grows enough to want a single federated login that issues
  short-lived client certificates, revisit Pinniped (ADR 26).
- Rolled out to the three core-infra control-plane nodes on 2026-11-04, one at
  a time (`docs/runbooks/kubernetes-api-oidc-rollout.md`). The legacy
  `.cluster.apiServer` patch was replaced by the new-style `KubeAPIServerConfig`
  because Talos passes `--authentication-config` only for that form, and the
  Barbican KMS socket moved under `/var/log/audit/kube` (already mounted into
  kube-apiserver) since the new document has no `extraVolumes`.
