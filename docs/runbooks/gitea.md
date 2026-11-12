# Gitea (git.rye.ninja)

Gitea on core-infra: `applications/gitea` (Helm chart 12.7.0, Gitea 1.27.0 rootless),
database `applications/gitea-db` (CNPG, 3 instances, barman backups to the SeaweedFS
bucket `gitea-db-barman`, daily 04:00 UTC), exposed by the `gitea-gateway` Gateway
(class `external-dedicated`, Let's Encrypt) with the chart-rendered HTTPRoute. HTTPS
only; built-in SSH is disabled.

## Rollout order

Everything is in `clusters/core-infra/kustomization.yaml`; two pieces need a manual nudge
because they are created once:

1. **SeaweedFS IAM** (`GiteaDbBarman` role) lives in the CreatedOnce Secret
   `seaweedfs-iam-config`. Roll it out as described in
   `applications/seaweedfs/base/resources/eso.external-secret.iam-config.yaml`
   (delete the Secret, restart the filers). The `gitea-db-barman` bucket comes from
   `createBuckets`; confirm it exists before the first backup.
2. **Keycloak**: re-run the keycloak-config-cli Job so the `gitea` client and the
   `ACL_gitea-users` / `ACL_gitea-admins` groups exist, and restart Keycloak so
   `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` takes effect. The client secret is generated in the
   `keycloak` namespace (`keycloak-gitea-client`), pushed to 1Password
   (`core-infra` vault, item `gitea-oidc-client`, field `client-secret`) and read back
   into `gitea/gitea-oidc-client`. Gitea's init container fails until that Secret
   exists; it retries.

## Authentication

- Keycloak realm `ryezone-labs`, client `gitea`, **confidential** (authorization code
  with a client secret). Gitea 1.27 cannot act as a PKCE client: its OIDC provider
  sends no `code_challenge`, and `gitea admin auth add-oauth` has no PKCE option. Do not
  turn on "Proof Key for Code Exchange" for this client in Keycloak, Gitea's requests
  would be rejected.
- Sign-in requires the Keycloak group `ACL_gitea-users`; `ACL_gitea-admins` sets the
  Gitea admin flag on each login. Add admins to both (groups do not nest).
- Redirect URI: `https://git.rye.ninja/user/oauth2/Keycloak/callback` (the source name
  `Keycloak` is part of the path).
- The pod cannot reach `id.rye.ninja` through the gateway (hairpin), so discovery is
  fetched from `keycloak-http.keycloak.svc.cluster.local`. Keycloak's
  `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` makes that document list in-cluster token and
  userinfo URLs, while the issuer and authorization URL stay public.
- Sign-out: the client's `post.logout.redirect.uris` is `https://git.rye.ninja/*`; without
  it Keycloak rejects Gitea's logout redirect as an invalid redirect URI.
- Break-glass local admin: Secret `gitea/gitea-admin` (`username`, `password`).

## Mirrors and migrations from GitHub

The nodes are IPv6-only, so github.com is reached through DNS64/NAT64 (`64:ff9b::/96`).
Two settings make that work, and both are needed:

- `migrations.ALLOWED_DOMAINS` (`applications/gitea/base/values.yaml`) is a hostname
  allow-list: github.com, `*.github.com`, `*.githubusercontent.com`. Gitea's default
  `external` rule rejects `64:ff9b::/96` as a reserved range ("You cannot import from
  disallowed hosts"). To mirror from another host, add it here.
- The `gitea` NetworkPolicy allows egress TCP 443 to `64:ff9b::/96`. Without it the
  clone fails with `dial tcp [64:ff9b::...]:443: i/o timeout` (the policy drops it).

Private repos need a token the form can use: paste the token value, not a 1Password
`op://` reference. A classic PAT needs the `repo` scope (and SSO authorization if the
org enforces it); a fine-grained token is scoped to one owner, so for an org's private
repo its resource owner must be that org. GitHub answers 404 for a repo the token
cannot see. A failed migration leaves a broken repository record; delete it before retrying.

## Database TLS

cert-manager chain in the `gitea` namespace: `gitea-db-selfsigned` Issuer ->
`gitea-db-ca` Certificate (10 y) -> `gitea-db-ca` Issuer -> `gitea-db-server-tls`
Certificate (90 d, renewed 30 d early, CNPG reloads it via the `cnpg.io/reload` label).
Approver-policy needs the `gitea-db-ca` / `gitea-db-server` CertificateRequestPolicies
and the `cert-manager-policy:gitea-db` grant. Gitea connects with
`SSL_MODE=verify-full` and trusts the CA through `PGSSLROOTCERT`
(`/etc/gitea-db-ca/ca.crt`, only `ca.crt` of the Secret is mounted).

## Repository storage (NFS)

Repositories live on the NAS dataset `flash-pool/gitea-repos` (50 GiB refquota),
exported over NFSv4 as `nfs.nas.rye.ninja:/mnt/flash-pool/gitea-repos` and mounted
at `/repos` (`repository.ROOT`; not under `/data`, because kubelet would create the nested mountpoint as root in the Cinder volume) through the static PV/PVC `gitea-repos`
(`applications/gitea/base/resources/repos.pv.yaml`, `ReadWriteMany`, mount options
`nfsvers=4.1,hard,noatime`). `/data` (app.ini, queue, attachments) stays on the
20 Gi Cinder volume. The dataset, the NAS user/group `gitea` (UID/GID 3004), the
export (every client mapped to that user, limited to the VLAN 1179 node network (bgp-net))
and the snapshot tasks are provisioned by `pcd-ce-deploy/tofu-truenas/gitea.tf`.

- **Snapshots:** hourly (kept 2 days) and daily at 23:15 America/Chicago (kept 30
  days), which is after gitea-db's 04:00 UTC backup in both CST and CDT. Restore a
  repository by cloning from `.zfs/snapshot/<name>` on the dataset.
- **Capacity check:** the CronJob `gitea-repos-capacity` runs hourly, reads the
  volume's size and usage, and pings the Healthchecks check on `/fail` at 75% or
  more, otherwise success. It also fails if the reported size exceeds the expected
  50 GiB (quota not applied). Check `gitea-repos-capacity` (period 1 hour, grace 30
  minutes); its ping URL is in 1Password `core-infra/healthchecks-ping-gitea-repos`,
  field `capacity`. Resizing means changing `var.gitea_repos_quota_gib`, the PV
  `capacity` and the CronJob's `EXPECTED_SIZE_GIB` together.
- **Snapshot check:** the same CronJob lists `/repos/.zfs/snapshot` (the NAS exports
  the snapshot directory over NFS) and pings check `gitea-repos-snapshots` (period 1
  hour, grace 30 minutes, URL in field `snapshots` of the same 1Password item) while
  the newest snapshot is under 26 hours old, `/fail` when older or when none is
  listed. Only the daily snapshot is guaranteed: its task has `allow_empty = true`,
  while the hourly one is skipped on an idle dataset.
- **NAS unreachable:** `hard` mounts block I/O instead of erroring, so Gitea hangs
  until the NAS returns, and the capacity job's pod sits in ContainerCreating (the
  silent check alerts on its own).

## Backup and restore

Database backups are watched by `cnpg-backup-watcher` (check `cnpg-backup-gitea-db`, daily; URL in
1Password `core-infra/healthchecks-ping-cnpg-backups`, field `gitea-db`): it fails when the latest
backup is older than 26 hours or WAL archiving is unhealthy. Restore: same procedure as grafana-db, see `keycloak-realm-restore.md` and
`grafana-db.md`, substituting `gitea-db`, `gitea-db-barman` and the `gitea`
namespace. Repositories: ZFS snapshots above (same NAS as the data, so not
off-site).

## Not done yet

- No restore-operator Role / SeaweedFS operator role (grafana-db has one).
- No off-site copy of the repositories or the `/data` volume; no SSH access.
- Not applied yet: the tofu in pcd-ce-deploy, and the node-to-NAS NFS path over
  IPv6 (UniFi firewall between VLAN 1179 and the NAS) is unverified.
