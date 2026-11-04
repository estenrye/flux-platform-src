# Runbook: enable Keycloak JWT authentication on a core-infra control plane

[ADR 30](../adr/0030-kubernetes-api-keycloak-jwt-authentication.md). The change
lives in `pcd-ce-deploy/tofu-pcd-talos-cluster` (`enable_oidc_auth`,
`oidc_issuers`) and is **not applied yet**.

## What changes on each control-plane node

- The legacy `.cluster.apiServer` patch is gone. A new-style
  `KubeAPIServerConfig` document replaces it (Talos only passes
  `--authentication-config` for that form). It keeps the SAN and the
  service-account issuer/JWKS args.
- The Barbican KMS plugin's socket moves from `/etc/barbican-kms/run/kms.sock`
  to `/var/log/audit/kube/kms/kms.sock`, a directory kube-apiserver already
  mounts. The encryption config's endpoint changes with it.
- `KubeAuthenticationConfig` carries the `oidc_issuers` JWT authenticators.

A node whose plugin or API server is on the wrong socket path cannot decrypt
Secrets, so roll one node at a time and check each before the next.

## Procedure

1. Snapshot etcd: `talosctl -n <cp1> etcd snapshot /tmp/etcd-pre-oidc.db`.
2. `tofu plan -var enable_oidc_auth=true`; expect only
   `talos_machine_configuration_apply.controlplane[*]` to change.
3. For `i` in 0, 1, 2, one at a time:
   - `tofu apply -var enable_oidc_auth=true -target='talos_machine_configuration_apply.controlplane[<i>]'`
   - `talosctl -n <node> ls /var/log/audit/kube/kms` shows `kms.sock`.
   - `talosctl -n <node> get apiserverconfig -o yaml | grep useAuthenticationConfig`
     is `true`, and the API server args include `--authentication-config` and
     no `--anonymous-auth`.
   - `kubectl get --raw='/readyz?verbose' | grep kms` is ok, and
     `kubectl -n kube-system get secret <any> -o name` still works against that
     node.
   - Only then continue to the next node.
4. Log in: `kubectl oidc-login get-token --oidc-issuer-url=https://id.rye.ninja/realms/ryezone-labs --oidc-client-id=kubernetes --oidc-extra-scope=groups`,
   then `kubectl --user=oidc auth whoami` shows your email and
   `ACL_Kubernetes_*` groups.

## Rollback

Revert the Talos change and apply to the affected node. If a node cannot decrypt
Secrets, the other two still serve; fix it before touching another. The etcd
snapshot from step 1 is the last resort.
