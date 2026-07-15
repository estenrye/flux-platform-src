# Runbook: GUA prefix renumber (ISP re-delegation)

The delegated PD (`gua_pd_prefix` in providers/kvm/network.yaml, currently
`2607:3640:1064:270::/60`, confirmed via
[docs/memory/unifi-gateway-pd-discovery.md](../memory/unifi-gateway-pd-discovery.md))
can change if TFiber re-delegates. VLAN 100's `gua_prefix` (`2607:3640:1064:270::/64`)
and the ingress VIP `/64` (`ingress_vip_subnet`, currently `2607:3640:1064:27f::/64`,
chosen 2026-07-15) are both carved from it. By design (M1 design §4.1) node
identity, etcd, and internal VIPs are ULA and immune — only v6 internet
egress, the ingress GUA VIP pool, and public AAAA records are affected, and
node egress self-heals via SLAAC.

Since the services-network redesign (2026-07-15,
[services-network-design](../superpowers/specs/2026-07-15-services-network-design.md)),
the ingress VIP pool is a **manually picked spare `/64`** within the PD, not
a formulaic suffix of `gua_prefix` — a re-delegation may require picking a
new spare nibble, not just updating one variable.

## Detection

- BGP sessions to the gateway drop (listen range no longer matches node
  source addresses) and external v6 reachability of ingress VIPs fails.
- `ip -6 addr` on the gateway / UniFi UI shows the new prefix, or check
  `/var/log/wan-diag-dhcpv6.log` on the gateway directly (see
  docs/memory/unifi-gateway-pd-discovery.md) for the current `IA_PD` grant.

## Procedure

1. **Update the variables** in `providers/kvm/network.yaml`: `gua_pd_prefix`
   (the new PD), `gua_prefix` (VLAN 100's `/64` within it — usually the same
   nibble as before), and `ingress_vip_subnet` / `ingress_vip_pool` — pick a
   spare nibble in the new PD not used by any VLAN (check UniFi's configured
   Networks first) and record the choice the same way `27f` was chosen
   2026-07-15.
2. **Regenerate + re-upload the FRR config**: update the GUA-derived lines
   in `providers/kvm/unifi-frr.conf` (BGP listen range uses `gua_prefix`;
   `CALICO-VIPS-IN` seq 20 uses `ingress_vip_pool`) to the new values;
   upload via UniFi UI. (ULA lines never change.) Do **not** create a UniFi
   Network/VLAN for the ingress VIP `/64` — it must stay unprovisioned
   (no RA, no on-link membership) or the gateway will misroute it exactly
   as root-caused 2026-07-15 (BGP-learned routes nested inside a UniFi
   connected-subnet ipset get misclassified and silently dropped).
3. **Re-render cluster config**: the ingress VIP pool
   (`ingress_vip_pool`) lives in the Calico IPPool (`ippool-lb-ingress.yaml`)
   and `BGPConfiguration.serviceLoadBalancerIPs` — re-render and let Flux
   reconcile.
4. **Nodes**: nothing to do — SLAAC picks up the new `gua_prefix` from RA;
   maintenance-mode EUI-64 derivation in create-controlplane-cluster.sh
   reads `gua_prefix` at run time.
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
