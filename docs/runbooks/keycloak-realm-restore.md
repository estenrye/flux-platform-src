# Runbook: Keycloak realm restore (`controlplane`)

Two independent recovery paths exist for Keycloak, and they restore
**different things** — know which one the incident actually calls for
before picking one:

| Path | Restores | Loses |
|---|---|---|
| **A. `keycloak-db` restore** (this runbook, primary) | Everything: realm structure, clients, groups, **and all user accounts/credentials/sessions** | Anything written after the last WAL segment archived before the incident (seconds to low minutes under normal archiving) |
| **B. `keycloak-config-cli` re-apply from git** | Only what's declared in `applications/keycloak/base/resources/keycloak-config-cli-configmap.yaml` — realm settings, groups, client scopes, the `pinniped-supervisor` client | **All end-user accounts** (e.g. `esten`) — the realm YAML in git has never declared a `users:` entry beyond the one bootstrap user added for M3 step 10's `[H]` verification, and even that is a *declarative* record (username/group/temp-password), not a backup of whatever password/session state actually existed live |

Path B is not a substitute for path A — it's what already happens
automatically on every `keycloak-config-cli` Job run (idempotent
reconciliation), and it only helps if the *database itself* is intact
and just missing a structural change that was reverted or never applied.
If `keycloak-db` is actually gone, path B alone gets you a realm that
looks right structurally but has **no users in it** — nobody can log in.

## Path A — restore `keycloak-db`

Same barman-cloud-to-Garage mechanism as every other CNPG-backed app on
this cluster (`keycloak-db-barman` bucket, 30-day retention,
`applications/keycloak-db/controlplane/resources/scheduled-backup.yaml`,
nightly 03:15 UTC). Follow
[openbao-restore.md](openbao-restore.md)'s Phase 1 procedure verbatim,
substituting:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: keycloak-db
  namespace: keycloak
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:18.3@sha256:5e30290fba3d990b08a9caea6ddb49c661ad8246cbb2688adad7e6cc78df6c3f
  storage:
    size: 10Gi
    storageClass: democratic-csi-nfs-pg
  primaryUpdateStrategy: unsupervised
  bootstrap:
    recovery:
      source: keycloak-db-source
  externalClusters:
    - name: keycloak-db-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: keycloak-db-barman
```

Check the source backup is healthy first (`kubectl -n keycloak get
backup --sort-by=.metadata.creationTimestamp`), delete the broken
`Cluster` + its PVCs (`kubectl -n keycloak delete cluster keycloak-db &&
kubectl -n keycloak delete pvc -l cnpg.io/cluster=keycloak-db`), apply
the recovery manifest above imperatively, and watch it reach `instances:
3/3`.

**Unlike OpenBao, there is no separate unseal phase** — once
`keycloak-db` is healthy, the existing `keycloak-0` StatefulSet pod (or a
fresh one, if it was also lost) reconnects and Keycloak is immediately
usable; there's no sealed/unsealed state to manage. If the `keycloak`
Deployment/StatefulSet itself was also lost (not just the database),
Flux recreates it from `applications/keycloak/base` on its next
reconcile — no manual redeploy needed, unlike OpenBao where the Helm
release itself would need standing up manually in a from-scratch DR
scenario.

**After the database is back**, re-run `keycloak-config-cli` anyway as a
consistency check — it's idempotent and cheap (a full run took ~2s
during M3 step 10's live testing), and it catches the case where the
restored data predates a structural change that's since been re-applied
in git but wasn't yet reflected in the WAL segment the restore landed
on:

```sh
kubectl -n keycloak delete job keycloak-config-cli
kubectl apply -f applications/keycloak/base/resources/keycloak-config-cli-job.yaml
kubectl -n keycloak logs job/keycloak-config-cli --tail=30
# expect "keycloak-config-cli ran in 00:0X.XXX" with no errors
```

(Applying the Job imperatively like this only survives until the next
Flux reconcile if it also needs a `ConfigMap` change that isn't in git
yet — for a pure re-run against unchanged config, letting Flux itself
delete+recreate it on next reconcile works too, since Jobs are immutable
and Flux's server-side apply will hit the same conflict noted in
[docs/memory/m3-step-tracker.md](../memory/m3-step-tracker.md)'s step 10
section if you `kubectl apply` it yourself first — delete it again
before the next reconcile if you went the manual route.)

## Verify

```sh
curl -sk https://id.rye.ninja/realms/ryezone-labs/.well-known/openid-configuration | jq .issuer
# "https://id.rye.ninja/realms/ryezone-labs"
```

Then confirm end-user accounts actually survived (path A) or don't exist
yet (path B, expected) via the admin REST API — see
[docs/memory/m3-step-tracker.md](../memory/m3-step-tracker.md)'s step 10
section for the exact `curl`-based admin-token-then-query pattern used
to verify this live during M3.

## Restore drill (non-destructive)

Same scratch-cluster pattern as
[openbao-restore.md](openbao-restore.md)'s drill section and
[step-ca-db-restore.md](step-ca-db-restore.md): a differently-named
`Cluster` (`keycloak-db-restore-drill`), its own copies of
`applications/keycloak-db/base/resources/network-policy.yaml` and the
`controlplane` overlay's barman/apiserver-egress policies re-scoped to
the drill name, restored from the same `keycloak-db-barman`
`ObjectStore` (read-only). Verify by connecting directly and checking
the `user_entity` table has rows (Keycloak's own user table):

```sh
kubectl -n keycloak exec keycloak-db-restore-drill-1 -c postgres -- \
  psql -d keycloak -c 'SELECT count(*) FROM user_entity;'
```

Tear down the same way: delete the scratch `Cluster` (takes its PVCs
with it) and the scratch NetworkPolicies.
