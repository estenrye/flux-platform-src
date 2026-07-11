# Runbook: NAT64/DNS64 appliance rebuild + break-glass

The `nat64-01` VM (Tayga + unbound, `fd97:45c2:b3a1:100::64`) is fully
declarative cloud-init — never repair it, rebuild it. Its outage breaks ONLY
IPv4-only egress (GitHub/ghcr pulls); running workloads and v6-native traffic
are unaffected (M1 design §4.3).

## Rebuild (minutes)

```sh
tofu -chdir=providers/kvm/controlplane taint module.nat64.libvirt_domain.vm
tofu -chdir=providers/kvm/controlplane taint module.nat64.libvirt_volume.system
.bin/create-controlplane-cluster.sh   # re-applies; talos steps no-op on a healthy cluster
```

## Verify

From a host using the appliance as resolver (`fd97:45c2:b3a1:100::64`):

```sh
ping -6 -c1 64:ff9b::8c52:7003                # github.com via NAT64 (140.82.112.3)
dig AAAA github.com @fd97:45c2:b3a1:100::64   # DNS64-synthesized 64:ff9b:: answer
curl -6 -sI https://github.com | head -1      # end-to-end through tayga
```

On the VM (`ssh nat64admin@fd97:45c2:b3a1:100::64`, break-glass key from
tofu var `nat64_authorized_ssh_keys`): `systemctl status tayga unbound`;
`ip addr show lan` shows ULA `::64` + `10.45.0.64`.

## Break-glass: appliance down and you need code/images NOW

Manual side-load path (M1 design §4.3):

1. **Git**: `git bundle create repo.bundle --all` on a dual-stack machine,
   copy over IPv6 (scp to any node's workload, or via TrueNAS NFS), fetch
   from the bundle.
2. **Images**: `docker pull` + `docker save` on a dual-stack machine, copy,
   then `ctr -n k8s.io images import` via `talosctl` on the target node — or
   push to a registry that has AAAA records.

## Retirement flag

If UniFi ships native NAT64 or GitHub publishes AAAA records, the appliance
retires with zero cluster changes: move the DNS64 resolver (machine config
`machine.network.nameservers`) to the gateway or drop DNS64 entirely, then
`tofu destroy -target=module.nat64`.
