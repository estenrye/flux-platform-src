---
name: minecraft-backup-on-terminate-deferred
description: itzg/minecraft chart 5.x mcbackup.backupOnTerminate (final backup on pod stop) is available but deliberately off; what enabling it would take
metadata:
  type: project
---

Chart 5.x (`itzg/minecraft` 5.3.1, adopted 2026-10-28 in `applications/minecraft`) added `mcbackup.backupOnTerminate`. It is NOT enabled: `base/values.yaml` leaves it at the chart default `false`.

**What it does:** adds a `preStop` hook to the `mc-backup` sidecar that waits for the server to shut down and then takes a final backup. If no custom `preStop` is set on the server container, the chart also adds one that marks the server paused after shutdown. Otherwise mc-backup would need RCON, which is gone by then. Hook logs do not appear in pod logs.

**Why it is deferred:** the default backup is periodic (`backupInterval: 24h`, rclone to Wasabi), so a pod stop can lose up to a day of play. Enabling it needs a larger `terminationGracePeriodSeconds` first. The chart default is 30 s, too short for a world shutdown plus an rclone upload. The right value is not measured yet. It is also untested whether the hook works with the repo's `readOnlyRootFilesystem: true` and the rclone init container. Nothing has hit data loss from this yet.

**How to apply:** when picking this up:
1. Measure shutdown plus backup time on the largest world (baked-goods, 8 GiB heap).
2. Set `mcbackup.backupOnTerminate: true` and a `terminationGracePeriodSeconds` with headroom in `applications/minecraft/base/values.yaml`. Then run `.bin/sync-minecraft-values.sh` to refresh the per-overlay copies.
3. Skip `pokehaan-craft`, which has `mcbackup.enabled: false`.
4. Confirm the backup lands in `minecraft-backups/<instance>` after a `kubectl delete pod`, and that the pod is not killed mid-upload.
5. Check the Deployment strategy (`Recreate`) still behaves, since the old pod must finish before the new one starts.
