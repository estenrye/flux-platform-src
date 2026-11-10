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
| `cloudflare-api-token` | core-infra | Caddy's ACME DNS challenge (**reused**: it is broader than needed; replace with a token scoped to `_acme-challenge` TXT edits) |

The VM-side secrets are all in Home_Lab, which the cluster cannot read (its External Secrets store is scoped to the core-infra vault).

## The check

`etcd-snapshot core-infra`: simple check, period 6 h, grace 2 h. The CronJob runs
at :17 past 00/06/12/18 UTC and pings after a successful R2 upload, and pings
`/fail` on any error in the upload step. **An alert fires after 8 h without a
ping**, or immediately on `/fail`. If the snapshot (init) step fails the upload
step never runs, so that case alerts via the missed ping rather than `/fail`.

## Test the alert path

```sh
URL=$(OP_ACCOUNT=ryefamily.1password.com op read "op://core-infra/healthchecks-ping-etcd-snapshot/url")
curl -fsS "$URL/fail"   # check goes down, Discord message
curl -fsS "$URL"        # recovers, Discord "up" message
```

## Rebuild / recover

The SQLite database is **not backed up**. If the VM is lost:
1. `tofu apply` in `pcd-ce-deploy/tofu-pcd-vms`, update the AAAA record if the address changed.
2. `ansible-playbook -i inventory.yml provision-healthchecks.yml` (set `ansible_host` first).
3. The bootstrap recreates the admin, channel and check with a **new check UUID**:
   put the new ping URL in the `healthchecks-ping-etcd-snapshot` item. External
   Secrets picks it up within its refresh interval.

## Known limits

- It is on the same PCD hypervisor as the cluster: a total PCD or hypervisor outage
  silences both. Consider a second, independent watcher.
- Deliberate weakness: the SQLite DB and Caddy certs live only on the VM.
- Pods reach the VM over the routed network; the security group allows
  `fd97:45c2:b3a1::/48` only. Verified from a pod on 2026-11-10.
- A new VM on PCD can fail with `NoUniqueMatch` if two security groups share a name
  (happened with a duplicate `talos-https`; fixed by deleting the unused one).
- The Ubuntu image only gets a SLAAC address by default, which Neutron port
  security drops. `user_data` in the tfvars forces DHCPv6; keep it.
