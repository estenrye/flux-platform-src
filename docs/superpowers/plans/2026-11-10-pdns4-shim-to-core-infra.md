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

## Stage 1: staged, invisible to DNS (this PR)

Deploy the shim in core-infra (`applications/pdns4-shim/core-infra`), API key via ESO
(`pdns4-shim-api-key`), Gateway on `internal-dedicated`. The Gateway and routes carry
`external-dns.alpha.kubernetes.io/controller: disabled`, so neither external-dns publishes
`pdns4-shim.rye.ninja` to the new VIP. Designate keeps using controlplane.

Verify: pod Ready; Gateway `Programmed` with a VIP from `lb-internal-routed`; certificate Ready;
from the PCD host (VLAN 100) `nc -6 -z <new VIP> 443` and
`curl --resolve pdns4-shim.rye.ninja:443:[<VIP>] -H "X-API-Key: ..." https://pdns4-shim.rye.ninja/api/v1/servers/localhost/zones`
returns `200` (empty list).

## Stage 2: prepare the UniFi publisher in core-infra (not enabled)

- `external-dns-unifi` overlay for core-infra: distinct `releaseName` (see
  `docs/memory/external-dns-multi-instance-collision.md`), `includeCRDs: false`, **`sources: [crd]` only**
  (so it does not start publishing core-infra's Gateway names into UniFi), secret
  `external-dns-unifi-credentials` (`host`, `api-key`) from 1Password via ESO. Replicas 0 until cutover.
- `DNSEndpoint`s to carry over: the five above, plus static entries for `bao.rye.ninja`,
  `ca.rye.ninja` and `pdns4-shim.rye.ninja` (new VIP) so they survive the UniFi publisher change.
  Delete the `bao`/`ca` entries as those services leave controlplane.

## Stage 3: cutover (short planned gap)

1. Snapshot: UniFi static DNS list, Cloudflare records for `pdns4-shim|bao|ca`, `kubectl get dnsendpoints -o yaml`.
2. Scale controlplane `external-dns` (UniFi) to 0. Nothing is deleted when it stops.
3. core-infra: apply the carried-over `DNSEndpoint`s, scale `external-dns-unifi` to 1, verify the UniFi records.
4. Cloudflare `pdns4-shim.rye.ninja`: remove controlplane's HTTPRoute (its Cloudflare instance deletes the
   record it owns), then drop the `controller: disabled` annotation on core-infra's routes/Gateway so the
   core-infra instance creates it (owner `core-infra`).
5. `pcd-ce-deploy/tofu-pcd`: set the Designate nameserver `host` to the new VIP, `tofu apply` (pool update).
6. Verify: create and delete a test record in Designate; see the `DNSEndpoint` change in core-infra and the record in UniFi.
7. Remove pdns4-shim, its Gateway/routes and the controlplane UniFi `external-dns` from controlplane.

Rollback (until step 7): point Designate back at `fd97:45c2:b3a1:f00::9280`, scale controlplane
`external-dns` back to 1, scale core-infra `external-dns-unifi` to 0.

## Open items

- The UniFi API key and host are SOPS-encrypted in `clusters/controlplane/resources/external-dns.unifi-credentials.sops.yaml`
  and must be copied to 1Password (`core-infra` vault) before stage 2.
- Confirm VLAN 100 (PCD hypervisor) can reach the new ULA VIP and send UDP/53 NOTIFY to it (stage 1 verification).
