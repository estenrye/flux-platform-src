# Runbook: scheduled etcd snapshots (`core-infra`)

Added after the Nov 2026 NFS outage, when etcd lost quorum and the cluster had
**no etcd backup** ([incident notes](../memory/core-infra-nfs-outage-2026-11.md)).
(The `controlplane` cluster's snapshots are a different mechanism: see
[etcd-snapshot-restore.md](etcd-snapshot-restore.md).)

## How it works

`applications/etcd-snapshot` runs a CronJob in namespace `etcd-backup` every 6
hours (`17 */6 * * *`):

1. init container `talosctl etcd snapshot` against the control-plane VIP
   `fd97:45c2:b3a1:1179::2c2` (apid proxies to whichever node holds it).
   Auth is a talosconfig that Talos generates for the `talos.dev` ServiceAccount
   `etcd-snapshot`, limited to role **`os:etcd:backup`**.
2. `rclone` checks the file is > 1 MB, uploads
   `core-infra-etcd-<UTC ts>.snapshot` to the R2 bucket `etcd-snapshots`, and
   deletes objects older than 14 days.

Snapshots deliberately leave the cluster, the Cinder/NFS storage, and the NAS.
They contain every Kubernetes Secret: the R2 bucket must stay private.

## One-time rollout (order matters)

The Flux Kustomization is a single unit; the `talos.dev` ServiceAccount CRD does
not exist until step 2, so merging the Flux change first would fail it.

1. **Bucket + token** (needs your Cloudflare admin token; stores in 1Password
   only, the cluster reads it through External Secrets):
   ```sh
   CLUSTER=core-infra BUCKET_NAME=etcd-snapshots SECRET_NS=etcd-backup \
   SOPS_ENCRYPT=false CF_API_TOKEN=<admin-token> \
   .bin/provision-cloudflare-r2-bucket.sh
   ```
   Creates 1Password item `cloudflare-r2-etcd-snapshots` (fields
   `access-key-id`, `secret-access-key`, `endpoint`, `bucket`).
2. **Talos API access** (`pcd-ce-deploy/tofu-pcd-talos-cluster/talos.tf`,
   `machine.features.kubernetesTalosAPIAccess`): `tofu plan` shows 3 in-place
   updates of `talos_machine_configuration_apply.controlplane`; `tofu apply`.
   Verify: `kubectl get crd serviceaccounts.talos.dev`.
3. **Merge/render the flux-platform change.** Verify:
   ```sh
   kubectl -n etcd-backup get serviceaccounts.talos.dev,secret
   kubectl -n etcd-backup create job --from=cronjob/etcd-snapshot etcd-snapshot-test
   kubectl -n etcd-backup logs job/etcd-snapshot-test -c upload
   kubectl -n etcd-backup delete job etcd-snapshot-test
   ```

## Checking it is working

- `kubectl -n etcd-backup get cronjob,job` shows recent successful Jobs.
- The newest object in the R2 bucket is < 6 h old.
- TODO: alert on `kube_cronjob_status_last_successful_time` older than ~12 h
  (alerting must not depend only on the cluster being healthy).

## Restore

1. Download the newest good snapshot from R2 (rclone or the Cloudflare UI).
2. Follow the Talos disaster-recovery procedure: on a fresh/wiped control plane,
   `talosctl -n <cp> bootstrap --recover-from=<snapshot>`
   (same mechanics as [etcd-snapshot-restore.md](etcd-snapshot-restore.md)).
3. Before any destructive change, take a manual snapshot first:
   `talosctl --talosconfig ~/.kube/talosconfig.core-infra -e <vip> -n <vip> etcd snapshot <file>`
   (regenerate the talosconfig with `tofu output -raw talosconfig` in
   `pcd-ce-deploy/tofu-pcd-talos-cluster`).

**Restore has not been drilled for core-infra.** Do a drill before relying on it.
