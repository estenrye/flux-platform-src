# Runbook: GUA prefix renumber (ISP re-delegation)

The delegated prefix (`gua_prefix` in providers/kvm/network.yaml, currently
`2607:3640:1064:270::/64`) can change if TFiber re-delegates. By design (M1
design §4.1) node identity, etcd, and internal VIPs are ULA and immune —
only v6 internet egress, the ingress GUA VIP pool, and public AAAA records
are affected, and node egress self-heals via SLAAC.

## Detection

- BGP sessions to the gateway drop (listen range no longer matches node
  source addresses) and external v6 reachability of ingress VIPs fails.
- `ip -6 addr` on the gateway / UniFi UI shows the new prefix.

## Procedure

1. **Update the variable**: `gua_prefix` in `providers/kvm/network.yaml`.
2. **Regenerate + re-upload the FRR config**: update the two GUA-derived
   lines in `providers/kvm/unifi-frr.conf` (listen range, CALICO-VIPS-IN seq
   20) to the new prefix; upload via UniFi UI. (ULA lines never change.)
3. **Re-render cluster config**: the ingress VIP pool
   (`<gua_prefix>:ffff::/112`) lives in the Calico IPPool/BGP config and the
   cluster EnvironmentConfig — re-render and let Flux reconcile.
4. **Nodes**: nothing to do — SLAAC picks up the new prefix from RA;
   maintenance-mode EUI-64 derivation in create-controlplane-cluster.sh
   reads gua_prefix at run time.
5. **DNS**: external-dns re-publishes AAAA records for LoadBalancer/Gateway
   VIPs automatically; manually re-check any hand-created AAAA records
   (nas.rye.ninja is on the same prefix — TrueNAS gets its new GUA via
   SLAAC/static config on the NAS side).
6. **Verify**: BGP established on the gateway; ingress VIP reachable from an
   external v6 vantage; `tests/controlplane-baseline/` network + lb suites
   green; ULA/GUA VIP prefixes still NOT visible from the WAN side.

## Mitigation to pursue

Ask TFiber / configure UniFi for a stable PD hint so the prefix survives
gateway reboots (M1 design §10).
