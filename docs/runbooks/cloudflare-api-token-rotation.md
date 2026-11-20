# Runbook: Cloudflare API Tokens (one per consumer) and Rotation

Every consumer of Cloudflare DNS gets **its own token** and its own 1Password item, so a leaked or
rotated token affects one consumer, not all of them. The old shared item `core-infra/cloudflare-api-token`
is being retired (see Migration). Rotate a token **immediately after any exposure** (printed in a terminal,
chat, CI log, transcript or commit) and otherwise annually.

Origin: on 2026-11-20 `op read` printed the shared token into a Claude Code session while diagnosing a
failed Healthchecks playbook run (the failure itself was transient). The shared token served five consumers,
so the exposure meant rotating all of them at once.

## Tokens

All tokens: permissions `Zone:Zone:Read` + `Zone:DNS:Edit`, zone resources limited to `rye.ninja`, a
Cloudflare token name equal to the item name, and an expiry (TTL) of one year. Cloudflare cannot restrict
DNS edit to `_acme-challenge` TXT records, so the zone scope is the narrowest available; where the consumer
has a fixed egress address, also set **Client IP Address Filtering** on the token (optional, but it makes a
leaked token useless from elsewhere).

| Consumer | Item (vault) | Read by | Applied by |
|---|---|---|---|
| cert-manager, core-infra (ACME DNS-01) | `cloudflare-api-token-cert-manager` (`core-infra`) | ESO `clusters/core-infra/resources/eso.external-secret.cloudflare-api-token.yaml` | `refreshPolicy: OnChange`, force a sync |
| external-dns, core-infra | `cloudflare-api-token-external-dns` (`core-infra`) | ESO `eso.external-secret.cloudflare-dns.yaml` | force a sync, restart the pod |
| Caddy on `healthchecks-vm` | `cloudflare-api-token-healthchecks` (`core-infra`) | `pcd-ce-deploy/ansible/provision-healthchecks.yml` (`hc_cf_token`), written to `/opt/healthchecks/caddy.env` | re-run the playbook |
| TrueNAS ACME DNS authenticator | `cloudflare-api-token-truenas` (`core-infra`) | `pcd-ce-deploy/tofu-truenas` (`cloudflare_onepassword_item_title`) | **`tofu apply`**: the value is copied onto the NAS, so a 1Password change alone does nothing |
| certbot on the PCD hypervisor | `cloudflare-api-token-certbot` (`pcd.rye.ninja`) | `pcd-ce-deploy/ansible/certbot-pcd.yml` (`onepassword_item_title`) | re-run the playbook (writes `/etc/letsencrypt/cloudflare.ini`) |

Each item has fields `credential` (the token) and `token-id` (Cloudflare's token ID, so a script or a
person can find and delete the old token). If another consumer turns up
(`grep -rn cloudflare-api-token` across the repos), give it its own row, token and item; never reuse one.

## Creating a token

1. Cloudflare dashboard, My Profile, API Tokens, Create Token, custom token with the permissions above.
2. Copy the value straight into the 1Password item (UI, or `op item create/edit` reading the value from
   stdin); never into a file, a shell argument or a chat. Record the token ID in `token-id`.
3. Test it without printing it: `op read op://<vault>/<item>/credential | wc -c` returns a non-zero count.

## Rotating one token

Never print a token. If a read fails, retry it and check it by byte count or exit code, not by echoing it.

1. In Cloudflare, **Roll** the consumer's token (the old value stops at once; only this consumer is affected,
   until step 3 finishes). Do it when no certificate for this consumer is near expiry.
2. Update the consumer's 1Password item (`credential`; `token-id` is unchanged by a roll).
3. Apply it as the table says:
   - cert-manager / external-dns:
     ```bash
     kubectl -n cert-manager annotate externalsecret cloudflare-api-token-secret force-sync=$(date +%s) --overwrite
     kubectl -n external-dns annotate externalsecret dns-credentials force-sync=$(date +%s) --overwrite
     kubectl -n external-dns rollout restart deploy   # external-dns reads the secret at start
     ```
   - healthchecks: from `pcd-ce-deploy/ansible`,
     `OP_ACCOUNT=ryefamily.1password.com ansible-playbook -i inventory.yml provision-healthchecks.yml`
     (the env file changes, so the `Recreate stack` handler restarts Caddy).
   - TrueNAS: `tofu apply` in `pcd-ce-deploy/tofu-truenas`; expect an in-place update of
     `truenas_acme_dns_authenticator.cloudflare`.
   - certbot: re-run `pcd-ce-deploy/ansible/certbot-pcd.yml`.
4. Verify:
   - cert-manager: `kubectl -n cert-manager get externalsecret,certificate` shows `SecretSynced` and Ready, with no
     Cloudflare auth errors in the cert-manager logs. external-dns logs show a clean reconcile.
   - healthchecks: `curl -sI https://healthchecks.rye.ninja` returns 200 with a valid certificate and Caddy
     logs show no DNS challenge errors.
   - TrueNAS: the ACME authenticator test in the UI passes, or the next certificate renewal succeeds.
   - certbot: `certbot renew --dry-run` on the hypervisor succeeds.

If a token was **exposed**, also: check the Cloudflare audit log (Manage Account, Audit Log) for DNS changes you
did not make since the exposure, and crt.sh for `rye.ninja` certificates issued in that window (a DNS-edit
token can pass ACME challenges). The place it was printed may keep the value, so deleting the output is not
enough; roll the token.

Rollback: there is none for a rolled token; fix forward with the new value.

## Migration from the shared token (one-time)

Order matters: create everything, switch consumers, delete the old token last.

1. Create the five tokens and items above (Creating a token). Leave `core-infra/cloudflare-api-token` and
   its token untouched.
2. Change the consumers to their own items, one PR per repo (do not merge before the item exists):
   - `flux-platform-src`: the two ESO `remoteRef.key` values (`cloudflare-api-token/credential` becomes
     `cloudflare-api-token-cert-manager/credential` and `cloudflare-api-token-external-dns/credential`).
   - `pcd-ce-deploy`: `provision-healthchecks.yml` `hc_cf_token`; `tofu-truenas/variables.tf` default
     `cloudflare_onepassword_item_title`; `certbot-pcd.yml` `onepassword_item_title` and its vault if it changes.
3. Apply each consumer (steps in Rotating one token, step 3) and verify it.
4. When all five are verified, **delete the old shared token in Cloudflare** (this is the actual
   remediation for the 2026-11-20 exposure; until then the leaked value still works) and delete or archive
   `core-infra/cloudflare-api-token` in 1Password after one more `grep -rn cloudflare-api-token` finds no reference.
5. Update `docs/runbooks/healthchecks-self-hosted.md` (line 40 still describes the reused token) and the
   references in `docs/memory/` that name the shared item.

Last rotation / migration status: not started.
