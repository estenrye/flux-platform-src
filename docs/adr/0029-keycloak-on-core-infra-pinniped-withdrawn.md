# 29. Keycloak on core-infra, Pinniped withdrawn

Date: 2026-11-01

## Status

Accepted (cluster access without Pinniped: [30. Kubernetes API authentication with Keycloak JWTs](0030-kubernetes-api-keycloak-jwt-authentication.md))

Supersedes [26. Keycloak + Pinniped Fleet Identity](0026-keycloak-pinniped-fleet-identity.md)

## Context

[ADR 26](0026-keycloak-pinniped-fleet-identity.md) put Keycloak
(`https://id.rye.ninja`, realm `ryezone-labs`) on the controlplane cluster and
federated it into Kubernetes RBAC through Pinniped. Pinniped is no longer wanted,
and the identity provider should live on core-infra, which already runs
SeaweedFS, ESO and the Calico Envoy gateways.

## Decision

- **Keycloak moves to core-infra.** `applications/keycloak` and
  `applications/keycloak-db` are core-infra-native: Calico `external-dedicated`
  gateway with the cert-manager Gateway API shim, `csi-cinder-sc-retain`
  storage. The controlplane overlay was deleted. The database starts empty; the
  realm is rebuilt by `keycloak-config-cli`. Existing users and sessions were
  not migrated.
- **Pinniped is withdrawn everywhere.** Supervisor and Concierge are removed from
  controlplane and the Concierge from observability, with the Keycloak client
  and its secrets. `applications/pinniped-*` remain in the tree, unused.
- **Credentials are generated in-cluster** by ESO `Password` generators
  (`refreshPolicy: CreatedOnce`): bootstrap admin, the `esten` one-time
  password and the `seaweedfs-s3` client secret. They exist only as cluster
  Secrets.
- **Backups go to SeaweedFS with Kubernetes auth.** The barman sidecar presents a
  projected ServiceAccount token (audience `seaweedfs-s3`) and assumes the
  `KeycloakDbBarman` role through SeaweedFS STS `AssumeRoleWithWebIdentity`. No
  static keys. The API server issues tokens as
  `https://kubernetes.default.svc.cluster.local`
  (`pcd-ce-deploy/tofu-pcd-talos-cluster/kms.tf`), and unauthenticated callers may
  read its JWKS.
- **Keycloak is a second OIDC source for SeaweedFS S3.** The `groups` claim maps
  to roles: `ACL_SeaweedFS_AllBucketAdmin` (all buckets),
  `ACL_SeaweedFS_ListAllBuckets` (list only), `ACL_Keycloak_DbBackupOperator`
  (list and read on `keycloak-db-barman`).

## Consequences

- Keycloak-DB backups depend on SeaweedFS. SeaweedFS trusts Keycloak only when
  validating tokens, so there is no startup cycle, and a Keycloak outage does not
  affect backups.
- There is no cluster-access federation any more; kubeconfig access is by other
  credentials.
- The SeaweedFS IAM schema, the JWKS fetch with the mounted cluster CA, and the
  token mount in the barman sidecar were not verified live when this was written.
