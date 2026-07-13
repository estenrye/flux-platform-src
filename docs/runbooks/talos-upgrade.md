# Runbook: Talos & Kubernetes upgrade (`controlplane`)

Upgrades are deliberate (M1 design §2): the version is pinned in
[providers/kvm/versions.yaml](../../providers/kvm/versions.yaml) and rolled
node-by-node. Never upgrade by editing VM definitions — Talos upgrades
in-place from its installer image.

## Pre-flight

1. Read the Talos release notes for breaking changes (IPv6, extensions,
   machine-config deprecations).
2. Snapshot etcd: `.bin/backup-controlplane-etcd.sh`.
3. Update the pin: `talos.version` (and `talos.kubernetes_version` if
   applicable) in `providers/kvm/versions.yaml`; PR + merge.
4. Match the client: `.bin/install-talosctl.sh`.
5. Compute the new installer ref:

   ```sh
   SCHEMATIC=$(yq -o=yaml '.talos.schematic' providers/kvm/versions.yaml \
     | curl -fsS -X POST --data-binary @- https://factory.talos.dev/schematics | jq -r .id)
   VERSION=$(yq -r '.talos.version' providers/kvm/versions.yaml)
   echo "factory.talos.dev/installer/${SCHEMATIC}:${VERSION}"
   ```

## Talos upgrade (one node at a time)

```sh
export TALOSCONFIG=~/.talos/homelab-controlplane.yaml
# control plane first: ::11, ::12, ::13 — wait for health between nodes
talosctl -n fd97:45c2:b3a1:100::11 upgrade --image factory.talos.dev/installer/${SCHEMATIC}:${VERSION}
talosctl -n fd97:45c2:b3a1:100::11 health --wait-timeout 10m
# then workers ::21, ::22, ::23 the same way
```

Single-host note: all VMs share one hypervisor — upgrade strictly serially
and let etcd settle (`talosctl etcd status`) before the next node.

## Kubernetes upgrade

```sh
talosctl -n fd97:45c2:b3a1:100::11 upgrade-k8s --to <kubernetes_version>
```

## Post-flight

- `talosctl health` clean; `kubectl get nodes` shows the new versions.
- Chainsaw baseline suites green (`tests/controlplane-baseline/`).
- Refresh the ISO pin for future rebuilds: rebuilds via
  `.bin/create-controlplane-cluster.sh` pick the new version up from
  versions.yaml automatically (new factory ISO volume on next apply).
