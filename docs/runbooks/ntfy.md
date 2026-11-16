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

1. **SeaweedFS IAM** (`NtfyDbBarman` role) is in the CreatedOnce Secret `seaweedfs-iam-config`. Check whether the
   live Secret already has it (`kubectl -n seaweedfs get secret seaweedfs-iam-config -o jsonpath='{.data.iam\.json}' |
   base64 -d | grep NtfyDb`); in practice ESO re-rendered it after the merge and the filers restarted on their own.
   Only if it is missing, follow `docs/memory/eso-createdonce-trust-policy-edits.md`. Do **not** delete the Secret
   as an easy fix: that regenerates the STS signing key. The bucket `ntfy-db-barman` comes from `createBuckets`;
   confirm it exists before the first backup.
   **The barman sidecar reads `AWS_ROLE_ARN` only at pod start**, so after changing the ObjectStore (or the role)
   restart the database pods: `kubectl -n ntfy annotate cluster ntfy-db kubectl.kubernetes.io/restartedAt=$(date -u +%FT%TZ) --overwrite`.
   Then take a manual `Backup` and check `ContinuousArchiving` is `True`.
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

## Scotty (lab manager agent)

Specs: `pcd-lab-manager/docs/superpowers/specs/2026-11-14-ntfy-notification-service-requirements.md` and
`2026-11-15-ntfy-notifications-design.md`. Users, grants and tokens are ntfy-native and live in `ntfy-db`
(created with `kubectl -n ntfy exec deploy/ntfy -- ntfy ...`, not in git).

| User | Grants | Credential |
|---|---|---|
| `scotty` | `agents-scotty` write-only; `agents-scotty-inbox` read-only | token `scotty-gateway`, no expiry: 1Password `pcd-lab-automation/ntfy.rye.ninja - scotty - token` (`credential`, `hostname`, `password`) |
| `gitea-webhook` | `agents-scotty-inbox` write-only | token `gitea-pcd-lab-manager`: 1Password `pcd-lab/ntfy.rye.ninja - gitea-webhook - token` (human-only vault) |
| `esten` | `agents-scotty` read-only | login in `Home_Lab/ntfy.rye.ninja - esten` (Android app) |

- Write-only means a publish works but the same token gets 403 on a subscribe, and write-only on the inbox means
  `scotty`'s token cannot publish there. Verify with the token: publish `agents-scotty` 200, publish
  `agents-scotty-inbox` 403, subscribe `agents-scotty` 403, subscribe `agents-scotty-inbox` 200.
- **Payload size.** Message limit is the default 4 KB and attachments are off, so a Gitea PR payload is rejected
  (400 "attachments not allowed"), including with `?message=`. Publish with templating,
  `?tpl=1&m=poke` and `Content-Type: application/json`: the stored message is the literal `poke`
  (tested with a 6 KB body).
- **Gitea webhook** on `esten/pcd-lab-manager`: type Gitea, POST, `application/json`, URL
  `https://ntfy.rye.ninja/agents-scotty-inbox?tpl=1&m=poke`, Authorization header `Bearer <gitea-webhook token>`,
  custom events Pull Request, Pull Request Comment, Pull Request Review. Gitea reaches the gateway through the
  egress rule in `applications/gitea/base/resources/network-policy.yaml` (ntfy-gateway Envoy pods, port 10443, the
  same pattern as gitea-runner to Harbor). If Test Delivery is refused by Gitea itself, add `ntfy.rye.ninja` to
  `[webhook] ALLOWED_HOST_LIST`.
- **Temporary grants.** The payload test needs `scotty` read-write on a scratch topic `agents-scotty-test`;
  remove it afterwards with `ntfy access --reset scotty agents-scotty-test` (done 2026-11-15).
- Revocation is the kill switch: `ntfy token remove <user> <token>`.

## Verify (run live 2026-11-15)

- `curl -i https://ntfy.rye.ninja/v1/health` with no credentials goes to oauth2-proxy (403 sign-in page; `/oauth2/start` is the 302 to Keycloak);
  with `-H 'Authorization: Bearer tk_...'` it returns `{"healthy":true}`.
- Publish: `curl -H 'Authorization: Bearer tk_...' -d hi https://ntfy.rye.ninja/test`.
- Browser: SSO, then the ntfy login; subscribe and watch a message arrive (checks the `auth=` WebSocket path).
- Confirmed live: the Authorization-header and `auth=` query-parameter route matches, the `$(DB_URI)?sslmode=...`
  expansion, and ESO's `bcrypt` template. Not tried: a full browser SSO sign-in and a browser WebSocket.

## Follow-ups

- Alertmanager/Grafana contact point to ntfy (`fable-5-arch-plan.md` lists ntfy as the alert fallback).
- The Healthchecks check `cnpg-backup-ntfy-db` and the watcher wiring exist (pcd-ce-deploy#24, flux-platform-src#372).
- Anonymous browsers see oauth2-proxy's "Sign in" button page (HTTP 403); `--skip-provider-button=true` would redirect
  straight to Keycloak.
