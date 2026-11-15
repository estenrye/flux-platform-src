# ntfy (ntfy.rye.ninja)

Push notifications on core-infra: `applications/ntfy` (ntfy v2.38.0 + oauth2-proxy v7.15.6, namespace
`ntfy`) with its database `applications/ntfy-db` (CNPG, 3 instances, barman backups to the SeaweedFS
bucket `ntfy-db-barman`, daily 04:30 UTC). Exposed by `ntfy-gateway` (class `external-dedicated`,
Let's Encrypt).

## Access model

ntfy has no OIDC or trusted-header login; users and tokens are its own (stored in ntfy-db, default access
`deny-all`). Keycloak SSO therefore only gates the **web UI**:

- A request with an `Authorization` header or an `auth` query parameter goes straight to ntfy
  (Android app, curl, webhooks, the web app's own API calls, WebSockets). A bogus header gains nothing:
  ntfy still denies.
- Any other request (a browser loading the UI) goes to oauth2-proxy, which needs a Keycloak session in
  `ACL_ntfy-users` (Keycloak client `ntfy`, confidential, PKCE S256), then forwards to ntfy. After SSO the
  web app still asks for an ntfy login.
- Token and JWKS calls use `keycloak-http.keycloak.svc` (pods cannot reach `id.rye.ninja`; see
  `docs/memory/gitea-core-infra.md`), so oauth2-proxy runs with `--skip-oidc-discovery`.

Not enabled: attachments, iOS upstream relay (`upstream-base-url`), metrics (`/metrics` would be public
through the Gateway).

## Rollout order

1. **SeaweedFS IAM** (`NtfyDbBarman` role) is in the CreatedOnce Secret `seaweedfs-iam-config`: delete it and
   restart the filers as described in `applications/seaweedfs/base/resources/eso.external-secret.iam-config.yaml`.
   Confirm bucket `ntfy-db-barman` exists before the first backup.
2. **Keycloak**: re-run the keycloak-config-cli Job (creates client `ntfy` and group `ACL_ntfy-users`). The client
   secret is generated in `keycloak` (`keycloak-ntfy-client`), pushed to 1Password (`core-infra` vault, item
   `ntfy-oidc-client`, field `client-secret`) and read back into `ntfy/ntfy-oidc-client`; oauth2-proxy stays
   in CreateContainerConfigError until that exists. Re-run the Job the way `docs/runbooks/gitea.md` describes.
3. **DNS**: confirm `ntfy.rye.ninja` resolves to the `ntfy-gateway` address (external-dns). Gitea gets this
   without a pin; Harbor pins its VIP only for UniFi LAN DNS.
4. Get the admin password: `kubectl -n ntfy get secret ntfy-admin -o jsonpath='{.data.password}' | base64 -d`
   (user `admin`). Create users and tokens:
   `kubectl -n ntfy exec deploy/ntfy -- ntfy user add <name>` /
   `ntfy token add <name>`; grant topics with `ntfy access <user> <topic> rw`.

## Verify (nothing here was run against a live cluster yet)

- `curl -i https://ntfy.rye.ninja/v1/health` is 302 to Keycloak (no credentials, so it goes to oauth2-proxy);
  with `-H 'Authorization: Bearer tk_...'` it returns `{"healthy":true}`.
- Publish: `curl -H 'Authorization: Bearer tk_...' -d hi https://ntfy.rye.ninja/test`.
- Browser: SSO, then the ntfy login; subscribe and watch a message arrive (checks the `auth=` WebSocket path).
- Items to confirm live: Envoy Gateway applies the header/query-param `RegularExpression` matches;
  `$(DB_URI)?sslmode=verify-full...` expands in the ntfy env; ESO's `bcrypt` template function renders.

## Follow-ups

- Healthchecks for `ntfy-db`: add it to `cnpg-backup-watcher` once a ping URL exists in the
  `cnpg-backup-monitor` 1Password item (harbor-db did this in a separate PR).
- Alertmanager/Grafana contact point to ntfy (`fable-5-arch-plan.md` lists ntfy as the alert fallback).
