# grafana-db and the Grafana secret_key

Grafana (core-infra) stores its state in the CNPG cluster `grafana-db`
(`applications/grafana-db`), backed up with barman to the SeaweedFS bucket
`grafana-db-barman` (30-day retention, daily 03:45 UTC).

## secret_key

`GF_SECURITY_SECRET_KEY` comes from the Secret `grafana-secret-key`, generated
once by ESO (`refreshPolicy: CreatedOnce`). It is the key encryption key for
Grafana's data keys, so everything Grafana encrypted in `grafana-db`
(datasource credentials, OAuth tokens) is unreadable without it.

- Never delete the Secret or the ExternalSecret's `Owner` relationship casually.
  Back up the Secret value before any cluster rebuild.
- To rotate it deliberately, set the new value, then run in maintenance mode
  with a database backup taken first:
  `grafana cli admin secrets-migration re-encrypt-data-keys`, then
  `grafana cli admin secrets-migration re-encrypt`.
- Moving to an external KMS later (e.g. OpenBao transit, which may need Grafana
  Enterprise): keep `secret_key` at its current value, add the provider
  settings, then run both re-encrypt commands.

## Restore

Follow `keycloak-realm-restore.md`, substituting `grafana-db`,
`grafana-db-barman` and the `grafana` namespace. Restore the same
`grafana-secret-key` value before starting Grafana against the restored data.

## secret_key backup in 1Password

A `PushSecret` (`applications/grafana/base/resources/eso.push-secret.secret-key.yaml`)
writes the key to the `core-infra` 1Password vault, item `grafana-secret-key`,
field `secret-key`. Restoring is manual: put that value back into the
`grafana-secret-key` Secret before Grafana starts on restored data.

## Restore access

Members of `ACL_Grafana_DbBackupOperator` get read-only access to the
`grafana-db-barman` bucket (SeaweedFS role `GrafanaDbBackupOperator`) and the
Kubernetes Role `grafana-db-restore-operator` in the `grafana` namespace
(`applications/grafana-db/base/resources/restore-operator.rbac.yaml`). The
Role can manage the `grafana-db` Cluster, its PVCs and backups, scale or
delete the Grafana pod, and cannot read Secrets. It takes effect through API server JWT authentication
([ADR 30](../adr/0030-kubernetes-api-keycloak-jwt-authentication.md)), once `enable_oidc_auth` is applied in the Talos config.

Restore: scale Grafana to 0, delete the Cluster and its PVCs, apply a
`bootstrap.recovery` Cluster (see `keycloak-realm-restore.md`) with
`barmanObjectName: grafana-db-barman`, wait for 3/3, scale Grafana back to 1.
