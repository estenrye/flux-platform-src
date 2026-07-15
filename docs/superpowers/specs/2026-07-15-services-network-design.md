# Services-Network Design: Routed VIP Subnets + Zone Firewall

Date: 2026-07-15
Status: Draft for review (Esten's proposal, step-5 debugging outcome)
Parent: [M2 design](2026-07-13-m2-migration-design.md) §4.6 deferred item; amends ADR-22 (UniFi BGP) and ADR-23 (IPv6-only) when executed
Execute: before the M2 step-10 soak (steps 6-8 are network-indifferent and proceed in parallel)

## 1. Problem

Both BGP VIP pools are carved from VLAN-100's on-link /64s, and the
workstation shares that VLAN with the servers. Consequences, all observed
2026-07-15: clients NDP for VIPs instead of routing (manual /112 host
routes required per machine); the return leg is delivered on-link straight
to client MACs, so node→client neighbor-discovery flakiness (aggravated by
macOS MAC rotation; root cause of node-GUA NS non-answers still unproven)
makes VIP connections flap; nothing traverses the gateway symmetrically,
so no firewall policy can be expressed for client→service traffic.

## 2. Design

1. **VIP pools become dedicated routed subnets** — inside no VLAN, in no
   RA, on-link nowhere; reachable only via the gateway's BGP routes:
   - internal: `fd97:45c2:b3a1:f00::/112` (from the site /48, replaces
     `…:100:ffff::/112`)
   - ingress GUA: **[H] check TFiber's PD size in UniFi first.** If ≥/56,
     dedicate one spare /64 (e.g. `<pd>:f0::/64`, VIPs from `…:f0::/112`)
     — in-PD, so upstream return routing is free. If PD is /64-only: LAN
     VIP stays ULA-only, `ca.rye.ninja` LAN record targets the ULA VIP,
     and public exposure defers to M6 (WAN static IPv4 + v4→v6 proxy, or
     Cloudflare Tunnel for plain-HTTPS endpoints only).
2. **Workstation leaves VLAN 100** for a client VLAN. Client↔VIP and
   client↔node flows then route via the gateway both directions: no host
   routes, no cross-segment NDP, MAC rotation irrelevant. kubectl keeps
   working — the M1 static route to the apiserver VIP already serves
   off-VLAN clients.
3. **Zone-based firewall** (UniFi 10.x): zones `infra` (VLAN 100),
   `clients`, `services` (the VIP prefixes), `wan`. Baseline policy:
   clients→services 443/80 allow; clients→infra apiserver + ssh only;
   wan→services deny (M6 opens 443 per-VIP); everything else per current
   posture. **[H] validate** how UniFi zones bind to BGP-learned prefixes
   (address-group fallback if zones require an interface).

## 3. Changes

| Where | What |
|---|---|
| `providers/kvm/network.yaml` | new `vip_internal` / `vip_ingress` allocations; retire the `:ffff::/112` entries |
| Calico (`applications/calico/controlplane`) | IPPools `lb-internal-ula`/`lb-ingress-gua` re-CIDRed; `BGPConfiguration.serviceLoadBalancerIPs` updated |
| `providers/kvm/unifi-frr.conf` | regenerate `CALICO-VIPS-IN` for the new prefixes; **[H] re-upload** |
| UniFi | **[H]** client-VLAN move, zones/policies, PD size check |
| Cleanup | delete both workstation host routes; simplify `workstation-nat64-route.md` memory; drop the M2 design §4.6 interim note |
| ADRs | amend ADR-22/ADR-23 with the routed-VIP topology (fold into the M2 migration ADR pass, step 14) |

## 4. Migration order (VIP churn is LAN-only; no fleet consumers yet)

1. [H] UniFi prep: PD check, client VLAN, zones. Move the Mac; confirm
   kubectl + ULA paths.
2. PR: network.yaml + Calico pools + BGPConfig + FRR regen (render/lint).
3. [H] Upload FRR config; merge render. Envoy service picks up new VIPs;
   external-dns republishes `ca.rye.ninja` automatically.
4. Validate from the client VLAN, no host routes: `ca.rye.ninja` health
   ×5 spaced past ND expiry (the flap test), `lb` suite, WAN-side
   negative check (VIP prefixes must not leak — DENY-ALL-OUT unchanged).
5. Retire interim artifacts (routes, memory notes, §4.6 caveat).

## 5. Risks

| Risk | Handling |
|---|---|
| PD is /64-only | ULA-only LAN VIPs; public-GUA question moves to M6 where its consumers live |
| UniFi zone semantics for routed BGP prefixes unclear | address-group firewall rules as fallback; validate in step 1 |
| VIP churn breaks something mid-migration | do before the soak; only LAN consumers exist; step-ca in-cluster paths use service DNS, not VIPs |
| Node-GUA NS mystery persists for node-initiated flows | out of scope here — client paths no longer depend on it; tracked for the M11 chaos/hardening pass |
