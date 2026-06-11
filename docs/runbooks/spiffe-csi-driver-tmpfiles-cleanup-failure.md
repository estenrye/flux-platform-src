# Runbook: SPIFFE CSI Driver Failing to Provision Volumes After systemd-tmpfiles Cleanup

> **Status**: TESTED — identified and reproduced on `crossplane-controlplane-cluster`,
> May 30, 2026.

## Overview

The `cert-manager-csi-driver-spiffe-driver` DaemonSet uses a `hostPath` volume
backed by `/tmp/cert-manager-csi-driver` to store its in-memory filesystem
(`inmemfs`). Because this path lives under `/tmp`, `systemd-tmpfiles-clean.service`
can delete it on long-lived nodes — even while the DaemonSet pod is still running
and showing 0 restarts. The pod's bind mount becomes a dangling reference to a
deleted inode, and the driver can no longer provision SPIFFE volumes for any new
pod scheduled to that node.

**Impact**: Any pod requesting a `spiffe.csi.cert-manager.io` volume on the
affected node is stuck in `ContainerCreating` indefinitely. Existing pods with
already-provisioned volumes are not affected. For this platform, the affected
workloads are the `aws-iam-admin-provider` and `aws-rolesanywhere-admin-provider`
Crossplane providers, which lose the ability to restart or reschedule.

**Scope**: Single-node failure. Other nodes with intact `/tmp/cert-manager-csi-driver`
directories continue to serve SPIFFE volumes normally.

## Symptoms

- Provider pods (or any pod with a SPIFFE CSI volume) are stuck in
  `ContainerCreating` on one specific node for more than ~2 minutes.
- `kubectl describe pod` shows a repeating warning event:
  ```
  Warning  FailedMount  <age>  kubelet  MountVolume.SetUp failed for volume "spiffe" :
  rpc error: code = Unknown desc = mkdir csi-data-dir/inmemfs: no such file or directory
  ```
- Other pods on different nodes start and mount SPIFFE volumes without issue.
- The CSI driver DaemonSet pod on the affected node shows `3/3 Running` and
  **0 restarts**, which masks the failure.

## Detection signals

### 1. Identify the stuck pod and its node

```bash
kubectl get pods -n crossplane-system -o wide | grep ContainerCreating
```

Note the node name from the `NODE` column.

### 2. Confirm the error is from the SPIFFE CSI driver

```bash
kubectl describe pod -n crossplane-system <stuck-pod-name> | grep -A 3 FailedMount
```

Look for: `mkdir csi-data-dir/inmemfs: no such file or directory`

### 3. Confirm the host path is missing on the affected node

```bash
kubectl debug node/<node-name> -it --image=busybox -- \
  sh -c "ls /host/tmp/cert-manager-csi-driver 2>&1 || echo 'HOST PATH MISSING'"
```

Expected output when this issue is present: `HOST PATH MISSING` or
`No such file or directory`.

### 4. Confirm the CSI driver pod's bind mount is a deleted inode

Find the CSI driver pod running on the affected node:

```bash
kubectl get pods -n cert-manager \
  --field-selector spec.nodeName=<node-name> \
  -l app.kubernetes.io/name=cert-manager-csi-driver-spiffe
```

Then check the pod's mountinfo. Because the container is distroless (no shell),
use `kubectl debug` targeting the container's pid namespace:

```bash
kubectl debug -n cert-manager <driver-pod-name> \
  --image=busybox --profile=sysadmin --target=cert-manager-csi-driver-spiffe -- \
  grep 'cert-manager-csi\|csi-data-dir' /proc/1/mountinfo
```

A `//deleted` suffix on the source path confirms the issue:
```
... /tmp/cert-manager-csi-driver//deleted /csi-data-dir rw,relatime ...
```

## Root cause analysis

The Helm chart for `cert-manager-csi-driver-spiffe` (tested against v0.12.0)
configures the driver's data directory as a `hostPath` volume:

```yaml
# templates/daemonset.yaml (excerpt, simplified)
- --data-root=csi-data-dir          # relative to container CWD (/)
...
volumeMounts:
  - mountPath: /csi-data-dir
    name: csi-data-dir
...
volumes:
  - name: csi-data-dir
    hostPath:
      path: /tmp/cert-manager-csi-driver   # value of .Values.app.driver.csiDataDir
      type: DirectoryOrCreate
```

The `type: DirectoryOrCreate` ensures the directory is created when the pod first
starts. However, `systemd-tmpfiles-clean.service` (which runs daily by default on
Ubuntu/Debian nodes) removes directories under `/tmp` that have not been accessed
recently. On a long-lived node where no new SPIFFE volumes were provisioned for
several days, the OS reclaims `/tmp/cert-manager-csi-driver`.

Linux preserves the inode (and the bind mount inside the container) via the
mount reference, so the DaemonSet pod keeps running with 0 restarts. But the
driver creates the `inmemfs` in-memory filesystem lazily — when it processes a
`NodePublishVolume` gRPC call, it attempts `os.MkdirAll("csi-data-dir/inmemfs")`
(path relative to `/`, so `/csi-data-dir/inmemfs`). Because the directory tree
backing the bind mount was deleted from the host, this `mkdir` call fails with
`ENOENT`, and the volume mount for the requesting pod is rejected.

**The DaemonSet pod's 0-restart count is a false-positive health signal.**
The pod is alive; the filesystem state it depends on is not.

### Why `/tmp` is dangerous for this use case

`systemd-tmpfiles-clean.timer` runs `systemd-tmpfiles --clean` based on rules
in `/usr/lib/tmpfiles.d/tmp.conf`, which typically configures `q /tmp 1777 root
root 10d` — removing files/directories in `/tmp` not accessed in 10 days. On a
stable cluster where providers restart infrequently, this threshold is easily
exceeded.

## Remediation

### Immediate fix: restart the CSI driver pod on the affected node

Deleting the pod forces the DaemonSet controller to recreate it. On startup,
Kubernetes re-applies `type: DirectoryOrCreate`, which recreates
`/tmp/cert-manager-csi-driver` on the host. This resolves the `inmemfs` failure
and unblocks stuck pods within ~30 seconds.

> **Safety**: Restarting the CSI driver pod does NOT unmount SPIFFE volumes
> already provisioned on that node. The kubelet's bind mounts for existing pods
> remain intact. Only pods that are currently stuck in `ContainerCreating` are
> affected, and they will complete their mounts once the driver restarts.

```bash
# 1. Find the driver pod on the affected node
DRIVER_POD=$(kubectl get pods -n cert-manager \
  --field-selector spec.nodeName=<node-name> \
  -l app.kubernetes.io/name=cert-manager-csi-driver-spiffe \
  --no-headers -o custom-columns=":metadata.name" \
  | grep driver)

echo "Deleting: $DRIVER_POD"

# 2. Delete it (DaemonSet will immediately reschedule)
kubectl delete pod -n cert-manager "$DRIVER_POD"

# 3. Wait for the replacement pod to be ready
kubectl rollout status daemonset -n cert-manager cert-manager-csi-driver-spiffe-driver --timeout=120s

# 4. Verify the host path now exists
kubectl debug node/<node-name> -it --image=busybox -- \
  sh -c "ls /host/tmp/cert-manager-csi-driver && echo OK"
```

After the driver pod is ready, the stuck pods should transition from
`ContainerCreating` to `Running` automatically within a few seconds as kubelet
retries the volume mount.

### Verify recovery

```bash
kubectl get pods -n crossplane-system -o wide | grep -E "aws-iam|rolesanywhere"
```

Both pods should show `Running` status.

### Long-term fix: move csiDataDir out of /tmp

Change the `csiDataDir` value in
`applications/cert-manager-spiffe-csi-driver/base/values.yaml` to a path that
is not subject to tmpfiles cleanup:

```yaml
# applications/cert-manager-spiffe-csi-driver/base/values.yaml
app:
  driver:
    csiDataDir: /var/lib/cert-manager-csi-driver   # was: /tmp/cert-manager-csi-driver
```

`/var/lib` is persistent across reboots and is never cleaned by
`systemd-tmpfiles`. After applying this change via Flux, the DaemonSet pods will
roll and recreate the data directory at the new path. This eliminates the
recurrence risk entirely.

> **Note**: After the DaemonSet rolls to the new path, any existing
> `/tmp/cert-manager-csi-driver` directories on nodes can be left to be cleaned
> by tmpfiles naturally; there is no manual cleanup required.
