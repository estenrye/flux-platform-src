# Runbook: UniFi DNS publisher cutover (controlplane -> core-infra)

`applications/external-dns/unifi/core-infra` is the UniFi publisher for core-infra. It ships
**dormant (replicas 0)**. controlplane's UniFi `external-dns`
(`applications/external-dns/unifi/base`, 3 replicas) still owns UniFi DNS until you run this.

## Why exactly one at a time

UniFi static DNS has no TXT type, so the provider runs `registry: noop` with `policy: sync`: every
sync deletes any record the running instance does not itself want. Two instances with different
inputs delete each other's records on every loop. **Stop one before starting the other. Never overlap.**
Do not rely on `--dry-run`: for a webhook provider the webhook may still apply changes.

## What the new instance publishes

Namespace `external-dns` only (`--namespace`, `--gateway-namespace`), sources `crd` + `gateway-httproute`:

| Record | Source |
|---|---|
| `bao.rye.ninja`, `ca.rye.ninja` AAAA `2607:3640:1064:27f::9280` | static `DNSEndpoint controlplane-legacy` (controlplane's Gateways) |
| `pdns4-shim.rye.ninja` AAAA | the pdns4-shim `HTTPRoute` -> its Gateway address (after the shim moved: `docs/superpowers/plans/2026-11-10-pdns4-shim-to-core-infra.md`) |
| zones/records Designate manages (today `workload-vm.usmnblm01.rye.ninja` A + AAAA) | `DNSEndpoint`s the shim writes |

core-infra's other Gateways (grafana, keycloak, netdata, ...) are intentionally **not** published into UniFi.
UniFi held 5 records on 2026-11-10: bao, ca, pdns4-shim (old VIP), workload-vm A + AAAA.

## Before the cutover

- The shim move is done and Designate repointed (otherwise `workload-vm` is absent from core-infra and is
  removed from UniFi: a test VM, but check you are fine with that).
- core-infra: `kubectl -n external-dns get externalsecret external-dns-unifi-credentials` is `SecretSynced`;
  `kubectl -n external-dns get dnsendpoint` shows `controlplane-legacy` and the Designate zones;
  `kubectl -n external-dns get deploy external-dns-unifi` is `0/0`.
- Snapshot UniFi records (read-only), from controlplane:
  ```sh
  export KUBECONFIG=~/.kube/homelab/controlplane.yaml
  P=$(kubectl -n external-dns get pods -l app.kubernetes.io/name=external-dns -o name | head -1)
  kubectl -n external-dns port-forward $P 18888:8888 &
  curl -s -H 'Accept: application/external.dns.webhook+json;version=1' http://127.0.0.1:18888/records
  ```

## Cutover (two PRs, in this order)

1. **Stop controlplane's:** set `/spec/replicas` to `0` in `applications/external-dns/unifi/base/patches/deployment.yaml`
   (only controlplane uses that base; keep the Deployment: it owns the `DNSEndpoint` CRD). Merge, let Flux apply, confirm
   `kubectl -n external-dns get deploy external-dns` is `0/0` on controlplane. Stopping deletes nothing.
2. **Start core-infra's:** set `/spec/replicas` to `1` in `applications/external-dns/unifi/core-infra/patches/deployment.yaml`.
   Merge, reconcile, then immediately check:
   ```sh
   kubectl -n external-dns logs deploy/external-dns-unifi -c external-dns --tail=50
   ```
   Expect the desired set above and **no unexpected DELETEs**. If it plans to delete a record you need, scale it back
   to 0 (PR, or `kubectl scale` as an emergency stop: Flux will revert it) and investigate.
3. Verify from a LAN client against UniFi: `dig @10.45.0.1 AAAA bao.rye.ninja ca.rye.ninja pdns4-shim.rye.ninja`
   and the `workload-vm` records; compare with the snapshot.

## Rollback

Stop core-infra's first (replicas 0), then restore controlplane's (replicas 3). It republishes its own set
within a sync interval (3 min). Never start it while core-infra's is running.

## Later

As each controlplane service moves, delete its entry from `clusters/core-infra/resources/dnsendpoint.controlplane-legacy.yaml`.
When controlplane is decommissioned, remove `applications/external-dns/unifi/base` along with the rest of it.
