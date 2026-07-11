# Runbook: replace a Talos node VM (`controlplane`)

For a corrupted/unbootable node VM. Node identity (ULA, hostname, MAC)
is fixed by `providers/kvm/network.yaml` + the tofu locals, so a replacement
comes back as the *same* node.

## Worker (`controlplane-wk-N`)

```sh
export TALOSCONFIG=~/.talos/homelab-controlplane.yaml
kubectl --kubeconfig ~/.kube/homelab/controlplane.yaml drain controlplane-wk-N \
  --ignore-daemonsets --delete-emptydir-data
tofu -chdir=providers/kvm/controlplane taint 'module.talos_node["controlplane-wk-N"].libvirt_volume.system'
tofu -chdir=providers/kvm/controlplane taint 'module.talos_node["controlplane-wk-N"].libvirt_domain.vm'
.bin/create-controlplane-cluster.sh   # re-applies infra, re-applies config in maintenance mode
kubectl --kubeconfig ~/.kube/homelab/controlplane.yaml uncordon controlplane-wk-N
```

## Control plane (`controlplane-cp-N`)

etcd must forget the dead member before the replacement joins:

```sh
talosctl -n <healthy-cp-ula> etcd members                     # note the dead member id
talosctl -n <healthy-cp-ula> etcd remove-member <member-id>
# then taint + re-create exactly as the worker flow above (skip drain if the VM is already gone)
talosctl -n fd97:45c2:b3a1:100::11,::12,::13 etcd status      # wait for 3 members, all healthy
```

Never remove a member while etcd lacks quorum — with 3 members, one loss
keeps quorum; two losses means restore from snapshot instead
([etcd-snapshot-restore.md](etcd-snapshot-restore.md)).

## Verify

`talosctl health` clean; node Ready; PVCs on the node re-attached
(democratic-csi re-mounts iSCSI/NFS from TrueNAS).
