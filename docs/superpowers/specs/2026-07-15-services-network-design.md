# Services-Network Design: Routed VIP Subnets + Zone Firewall

Date: 2026-07-15
Status: **Partially executed 2026-07-15.** Routed VIP subnets (design §2
items 1–2, migration steps 1–5) are done and validated. Zone-based
firewall (§2 item 3) is still open — not blocking, routing correctness
didn't depend on it.
Parent: [M2 design](2026-07-13-m2-migration-design.md) §4.6 deferred item; amends ADR-22 (UniFi BGP) and ADR-23 (IPv6-only), both amended 2026-07-15
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

| Where | What | Status |
|---|---|---|
| `providers/kvm/network.yaml` | `gua_pd_prefix` added; `internal_lb_vip_pool` + `ingress_vip_subnet`/`ingress_vip_pool` replace the `:ffff::/112` entries | Done |
| Calico (`applications/calico/controlplane`) | **Not an in-place re-CIDR** — `IPPool.spec.cidr` is immutable (Flux dry-run rejected the original attempt). New pools `lb-internal-ula-routed`/`lb-ingress-gua-routed` added; old `lb-internal-ula`/`lb-ingress-gua` disabled, not deleted; `BGPConfiguration.serviceLoadBalancerIPs` points at the new pools | Done |
| `providers/kvm/unifi-frr.conf` | `CALICO-VIPS-IN` regenerated for the new prefixes | Done, uploaded and applied |
| UniFi | client-VLAN move ✓, PD size check ✓; zones/policies still open | Partial |
| Cleanup | `workstation-nat64-route.md` rewritten (retired, not deleted); this doc and the M2 design §4.6 caveat updated to reflect execution | Done |
| ADRs | ADR-22/ADR-23 amended directly (not deferred to M2 ADR pass step 14 — done now while the context is fresh) | Done |
| Envoy Gateway (`applications/envoy-gateway`) | *(not in original scope — found during step 4 validation)* `EnvoyProxy` custom-proxy-config: 6 replicas, required anti-affinity, control-plane taint toleration, `maxSurge:0`/`maxUnavailable:1`; mitigates a separate Calico BGP-advertisement bug for `externalTrafficPolicy: Local` services (ADR-22 amendment) | Done |

## 4. Migration order (VIP churn is LAN-only; no fleet consumers yet)

1. **[Done, partial]** UniFi prep: PD check ✓ (`/60`, confirmed via
   odhcp6c — `docs/memory/unifi-gateway-pd-discovery.md`), client VLAN ✓
   (VLAN 101). Zones: **not done** — VLAN 100 and 101 both still in
   UniFi's default "internal" zone; tracked separately, not blocking.
2. **Done.** PR: network.yaml + Calico pools + BGPConfig + FRR regen.
   Calico's `IPPool.spec.cidr` is immutable — this became a new-pool
   swap (old pools disabled, not deleted) rather than an in-place edit;
   see the Changes table note below.
3. **Done.** FRR uploaded and applied; BGP sessions re-established
   clean. Rendered PRs merged, Flux reconciled.
4. **Done.** Validated from VLAN 101 with zero manual routes:
   `ca.rye.ninja` health 15/15 after the full fix. The flap test caught a
   second, unrelated bug — Calico doesn't restrict BGP advertisement of a
   LoadBalancer's host route to nodes with a local endpoint under
   `externalTrafficPolicy: Local` (ADR-22 amendment) — fixed by spreading
   Envoy across all 6 nodes with anti-affinity, not by this design's own
   scope. WAN-side negative check not yet re-run since the renumber.
5. **Done.** Interim artifacts retired:
   `docs/memory/workstation-nat64-route.md` rewritten to record
   retirement (not deleted — kept as historical root-cause reference);
   this §4.6 caveat replaced with a resolved summary in the M2 design.

## 5. Risks

| Risk | Handling | Outcome |
|---|---|---|
| PD is /64-only | ULA-only LAN VIPs; public-GUA question moves to M6 where its consumers live | N/A — PD confirmed `/60`, both pools routed |
| UniFi zone semantics for routed BGP prefixes unclear | address-group firewall rules as fallback; validate in step 1 | Still open — zones not yet configured for VLAN 100/101; the routed VIP `/64`s aren't bound to any UniFi network at all, so this needs the address-group fallback when tackled |
| VIP churn breaks something mid-migration | do before the soak; only LAN consumers exist; step-ca in-cluster paths use service DNS, not VIPs | Confirmed — the one live consumer (`ca.rye.ninja`) briefly broke during the pool swap and Service recreation, as expected; no other consumers affected |
| Node-GUA NS mystery persists for node-initiated flows | out of scope here — client paths no longer depend on it; tracked for the M11 chaos/hardening pass | Not encountered during this work — the flakiness that did surface (ECMP + `externalTrafficPolicy: Local`) was a different, unrelated Calico bug (ADR-22 amendment), not this one |
