# Plan: move pdns4-shim from controlplane to core-infra

Context: controlplane is being decommissioned; this is the first step. The shim
impersonates the PowerDNS API for PCD's Designate `pdns4` target and writes
`DNSEndpoint` objects that `external-dns` publishes.

## What exists today (checked 2026-11-10)

- controlplane: `pdns4-shim` (+ Gateway `pdns4-shim` on `internal-eg`, VIP
  `fd97:45c2:b3a1:f00::9280`), `external-dns` (UniFi webhook, `registry: noop`,
  `policy: sync`, filter `rye.ninja`) and `external-dns-cloudflare` (TXT owner `controlplane`).
- Five `DNSEndpoint`s in `external-dns`: `usmnblm01.rye.ninja` (A + AAAA for
  `workload-vm`, **UniFi only**, not in Cloudflare) and four empty zone markers
  (`rye.ninja`, `10.45.71/73.x in-addr.arpa`, one `ip6.arpa`) carrying the
  `pdns4-shim.rye.ninja/axfr-masters` annotation.
- controlplane also publishes `bao.rye.ninja` and `ca.rye.ninja` (-> `2607:3640:1064:27f::9280`)
  from its own Gateways, and `pdns4-shim.rye.ninja` (Cloudflare -> the ULA VIP; UniFi too).
- Designate (`pcd-ce-deploy/tofu-pcd/terraform.tfvars`, pool `default`): nameserver
  `host = fd97:45c2:b3a1:f00::9280` (hard-coded, UDP NOTIFY), target
  `api_endpoint = https://pdns4-shim.rye.ninja:443`, token = 1Password
  `controlplane/pdns4-shim.rye.ninja` (copied to `core-infra/pdns4-shim-api-key`).
- core-infra has Cloudflare `external-dns` (owner `core-infra`) but **no UniFi publisher**.

## Constraints that shape it

- UniFi uses a `noop` registry with `policy: sync`: **two instances against one UniFi delete
  each other's records.** There must be exactly one UniFi publisher at any time.
- Cloudflare TXT ownership is per instance: the core-infra instance will not adopt records owned by
  `controlplane`. Two `sync` instances sharing an owner delete each other's records (seen 2026-10-24).
- Calico 3.33 names each Gateway's proxy after the Gateway, in the Gateway's namespace: the new Gateway is
  `pdns4-shim-gateway` (a Gateway called `pdns4-shim` would collide with the shim's own objects).

## Decision (2026-11-10)

The base (`applications/pdns4-shim/base`) is edited directly for core-infra (Gateway
`pdns4-shim-gateway` on `internal-dedicated`, NetworkPolicy admitting the same-namespace
proxy pods, ExternalSecret `pdns4-shim-api-key` in `clusters/core-infra/resources/`), and the shim and its
SOPS secret are removed from `clusters/controlplane`. No overlay, no staging: a short DNS gap is accepted.
Controlplane's `external-dns` (UniFi and Cloudflare) and its other services are untouched.

## Cutover sequence (order matters)

Designate talks to the shim two ways: HTTPS by **hostname** (`api_endpoint`) and UDP NOTIFY to a **hard-coded
VIP** (`nameservers[].host`). Both must end on the new shim before zones are re-created.

1. Merge the source PR. Two render PRs appear (controlplane, core-infra); merge **core-infra first**. The shim,
   its Gateway (new `lb-internal-routed` VIP) and certificate come up. Until step 3 the Cloudflare record still points at
   the old shim (owned by controlplane), so the core-infra `external-dns` skips it: no conflict, no effect.
2. Verify the new shim directly: pod Ready, Gateway `Programmed`, `curl --resolve ... -H "X-API-Key: ..."`
   to `/api/v1/servers/localhost/zones` returns 200, `nc -6 -z <VIP> 443` from the PCD host (VLAN 100).
3. Merge the **controlplane** render PR (removes the old shim). Its HTTPRoute disappears, so controlplane's
   Cloudflare instance deletes `pdns4-shim.rye.ninja` (it owns it) and controlplane's UniFi instance drops its local record;
   the core-infra Cloudflare instance then creates it at the new VIP (owner `core-infra`). Gap: a few minutes
   while the name flips; Designate calls to the shim fail meanwhile.
4. When `pdns4-shim.rye.ninja` resolves to the new VIP (`dig @1.1.1.1 AAAA`), set Designate's
   `nameservers[].host` to the new VIP in `pcd-ce-deploy/tofu-pcd/terraform.tfvars` and `tofu apply`
   (pool update re-creates the zones in the new shim; its AXFR pull repopulates records from designate-mdns).
5. Verify: `DNSEndpoint`s for the zones exist in core-infra `external-dns`; create/delete a test record in Designate.

Rollback: restore the shim in controlplane (revert the controlplane render PR; secret from 1Password
`controlplane/pdns4-shim.rye.ninja`), set Designate's `host` back to `fd97:45c2:b3a1:f00::9280`.

## Known gap: UniFi

core-infra has no UniFi publisher. After the cutover, records Designate manages (today only `workload-vm`, UniFi-only)
will **not** reach UniFi from core-infra. The old `DNSEndpoint`s left in controlplane keep controlplane's UniFi instance
publishing the stale `workload-vm` records until that instance is removed. Next step before decommissioning controlplane's
`external-dns`: a UniFi `external-dns` in core-infra with **`sources: [crd]` only** (distinct `releaseName`, `includeCRDs: false`,
credentials from 1Password via ESO) plus static `DNSEndpoint`s for `bao.rye.ninja` and `ca.rye.ninja`, then retire controlplane's.
UniFi uses `registry: noop` with `policy: sync`, so **never run two UniFi instances at once**: stop one before starting the other.
The UniFi `host`/`api-key` are SOPS-encrypted in `clusters/controlplane/resources/external-dns.unifi-credentials.sops.yaml`
and must be copied to 1Password (`core-infra` vault) first.
