# Runbook: self-hosted Healthchecks (`healthchecks.rye.ninja`)

Dead-man's-switch for jobs that must not silently stop, starting with the
core-infra etcd snapshot CronJob ([etcd-snapshot-core-infra.md](etcd-snapshot-core-infra.md)).
It exists because the Nov 2026 outage went unnoticed for 71 hours: every
in-cluster alert path died with the cluster.

## Where it runs

- A VM, `healthchecks-vm`, on PCD (`vlan1000-net`, `fd97:45c2:b3a1:1000::30e`),
  **outside the core-infra cluster**. 2 vCPU / 2 GB / 20 GB, flavor `healthchecks`.
- Its disk is image-backed local hypervisor storage, **not NFS-backed Cinder**,
  so a NAS outage does not take it down with the cluster.
- Docker Compose, host networking (the VM is IPv6-only): `healthchecks`
  (`healthchecks/healthchecks:v5.0.3`, SQLite in `/opt/healthchecks/data`) and
  `caddy` (`caddybuilds/caddy-cloudflare`, Let's Encrypt via Cloudflare DNS-01).
- DNS: AAAA `healthchecks.rye.ninja` -> the VM's ULA address (Cloudflare,
  zone `rye.ninja`). Only reachable from the internal network.
- Alerts: a Webhook integration posting to a Discord channel (Slack-compatible
  `/slack` webhook URL). No SMTP is configured, so email integrations will not work.

## Built from

| What | Where |
|---|---|
| VM, flavor, security group | `pcd-ce-deploy/tofu-pcd-vms/terraform.tfvars` (`healthchecks-vm`) |
| Software + first-run setup | `pcd-ce-deploy/ansible/provision-healthchecks.yml`, `files/healthchecks-bootstrap.py` |
| Cluster heartbeat | `applications/etcd-snapshot` (CronJob) + `clusters/core-infra/resources/eso.external-secret.healthchecks-ping-etcd-snapshot.yaml` |

## Secrets (1Password, account `ryefamily.1password.com`)

| Item | Vault | Used by |
|---|---|---|
| `healthchecks-secret-key` | Home_Lab | Django `SECRET_KEY` (Ansible) |
| `healthchecks-admin` | Home_Lab | admin login (Ansible bootstrap) |
| `healthchecks-discord-webhook` | Home_Lab | alert channel (Ansible bootstrap) |
| `healthchecks-ping-etcd-snapshot` | core-infra | ping URL, read by the cluster via External Secrets |
| `cloudflare-r2-healthchecks-db`, `healthchecks-db-backup-age-key` | Home_Lab | DB backup upload credentials and age keypair (VM-side) |
| `healthchecks-ping-cnpg-backups` | core-infra | three ping URLs, read by the cluster via External Secrets |
| `cloudflare-api-token` | core-infra | Caddy's ACME DNS challenge (**reused**: it is broader than needed; replace with a token scoped to `_acme-challenge` TXT edits) |

The VM-side secrets are all in Home_Lab, which the cluster cannot read (its External Secrets store is scoped to the core-infra vault).

## The check

`etcd-snapshot core-infra`: simple check, period 6 h, grace 2 h. The CronJob runs
at :17 past 00/06/12/18 UTC and pings after a successful R2 upload, and pings
`/fail` on any error in the upload step. **An alert fires after 8 h without a
ping**, or immediately on `/fail`. If the snapshot (init) step fails the upload
step never runs, so that case alerts via the missed ping rather than `/fail`.

## CNPG backup checks

`applications/cnpg-backup-watcher` runs daily at 05:00 UTC (after the 03:15 / 03:45
UTC ScheduledBackups) and pings one check per database: `cnpg-backup-keycloak-db`,
`-grafana-db`, `-seaweedfs-db` (period 1 day, grace 3 h). For each database it checks:

- the newest **completed** `Backup` is less than 26 h old,
- the **latest** `Backup` did not fail,
- the Cluster's `ContinuousArchiving` condition is `True` (WAL is flowing).

Healthy -> success ping; any problem -> `/fail` with the reasons (Discord alert).
No ping for 1 day + 3 h also alerts. It reads Backup objects because
`Cluster.status.lastSuccessfulBackup` stays empty with the barman-cloud plugin.
It proves a backup *ran*, not that it is restorable or off-site: keycloak-db and
grafana-db back up to the in-cluster SeaweedFS (same storage as the data);
seaweedfs-db backs up to Cloudflare R2.

Ping URLs: 1Password `core-infra/healthchecks-ping-cnpg-backups` (one field per database).
Add a database by adding a `Check` to `ansible/files/healthchecks-bootstrap.py`, a field
to that item, and an entry in the CronJob's `TARGETS` and env.

## Test the alert path

```sh
URL=$(OP_ACCOUNT=ryefamily.1password.com op read "op://core-infra/healthchecks-ping-etcd-snapshot/url")
curl -fsS "$URL/fail"   # check goes down, Discord message
curl -fsS "$URL"        # recovers, Discord "up" message
```

## Database backup (SQLite -> R2, age-encrypted)

Healthchecks uses **SQLite** (`/opt/healthchecks/data/hc.sqlite`), not Postgres.
`healthchecks-db-backup.timer` on the VM runs daily at 02:30 UTC (+ up to 5 min jitter):

1. SQLite online-backup API inside the app container (consistent while running) + `PRAGMA integrity_check`.
2. `gzip` then `age` encrypt to the **public** key; the plaintext copy is deleted immediately.
3. Upload `healthchecks-db-<UTC ts>.sqlite.gz.age` to the private R2 bucket `healthchecks-db`
   (rclone in a `--network host` container: the VM is IPv6-only, bridge containers cannot reach R2),
   then delete objects older than 30 days.
4. Ping the `healthchecks-db-backup` check (1 day + 3 h grace; `/fail` on any error).
   That check lives on this same instance, so it catches a failing backup but not the loss of the VM.

Secrets (1Password, vault `Home_Lab`): `cloudflare-r2-healthchecks-db` (bucket-scoped R2 token),
`healthchecks-db-backup-age-key` (`private-key` is **only** here, never on the VM; `public-key` is on the VM).

Run one now: `sudo systemctl start healthchecks-db-backup.service` (takes ~5 s; `journalctl -u healthchecks-db-backup`).

### Restore

```sh
export OP_ACCOUNT=ryefamily.1password.com
# download the newest object from R2 (rclone / Cloudflare UI), then:
op read "op://Home_Lab/healthchecks-db-backup-age-key/private-key" > key.txt   # chmod 600; delete afterwards
age -d -i key.txt healthchecks-db-<ts>.sqlite.gz.age | gunzip > hc.sqlite
sqlite3 hc.sqlite 'PRAGMA integrity_check'          # expect: ok
```
To restore onto the VM: `docker compose down` in `/opt/healthchecks`, replace
`data/hc.sqlite` (owner uid 999, mode 0640), `docker compose up -d`. Pings and
alerts resume with the same check URLs.

**Drilled 2026-11-10:** a manual backup was downloaded, decrypted with the key from
1Password, passed `integrity_check`, and matched the live database (1 user, 5 checks,
2 channels). Decrypting without the key fails, as intended.

## Rebuild / recover

1. `tofu apply` in `pcd-ce-deploy/tofu-pcd-vms`, update the AAAA record if the address changed.
2. `ansible-playbook -i inventory.yml provision-healthchecks.yml` (set `ansible_host` first).
3. Either restore the latest backup (above), which keeps every check URL, or let the
   bootstrap create fresh checks with **new** UUIDs and update the ping URLs in the
   `healthchecks-ping-*` items in `core-infra`.

## Known limits

- It is on the same PCD hypervisor as the cluster: a total PCD or hypervisor outage
  silences both. Consider a second, independent watcher.
- The DB is backed up daily to R2 (above). Caddy's certificate is re-issued automatically on rebuild.
- Pods reach the VM over the routed network; the security group allows
  `fd97:45c2:b3a1::/48` only. Verified from a pod on 2026-11-10.
- A new VM on PCD can fail with `NoUniqueMatch` if two security groups share a name
  (happened with a duplicate `talos-https`; fixed by deleting the unused one).
- The Ubuntu image only gets a SLAAC address by default, which Neutron port
  security drops. `user_data` in the tfvars forces DHCPv6; keep it.
