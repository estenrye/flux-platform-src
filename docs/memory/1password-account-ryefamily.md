---
name: 1password-account-ryefamily
description: The vault holding sops-age-key/service-account-token/etc. lives under ryefamily.1password.com; the vault itself is named "controlplane", not "crossplane" (renamed at some point since crossplane-credential-rotation.md was written)
metadata:
  type: reference
---

Esten has two 1Password accounts signed into `op` locally:
`familyrye.1password.com` (david.rye01@gmail.com) and
`ryefamily.1password.com` (esten.rye@ryezone.com). This platform's
automation/secrets live under **ryefamily.1password.com**. Confirmed
2026-08-15 per explicit instruction after a 1Password lookup ambiguity
mid-session.

**Vault name correction (2026-08-15):** [[crossplane-credential-rotation]]
documents the vault as `crossplane`, and that name was tried first this
session (`op://crossplane/sops-age-key/private-key`) — it did not resolve
with the working service account token. `op vault list` with that token
showed only a vault named **`controlplane`**, and `op item list --vault
controlplane` confirmed the same item set the older memory describes
(`sops-age-key`, `service-account-token`, `cloudflare-api-token`,
`github-auth-app`, plus newer ones: `openbao-root-token`,
`truenas-api-key`, `cloudflare-r2-openbao-snapshots`,
`unifi-os-external-dns`, `unifi-os-xnetworksegment`). Either the vault was
renamed `crossplane` → `controlplane` at some point after that memory was
written, or the working token is scoped to a differently-named vault
holding an equivalent item set — not fully disambiguated, but **use
`controlplane` going forward** since that's what actually resolves. The
`sops-age-key` item's actual field is labeled `private-key` (id
`yecnf7fdzgto7pnzcsxmwndysq`, type CONCEALED) — `op://controlplane/sops-age-key/private-key`
confirmed working.

**How to apply:** default to `ryefamily.1password.com` for any `op` command
touching this repo's secrets, and use vault name `controlplane` (not
`crossplane`) unless a fresh check shows otherwise — vault naming here has
already drifted once.

**Related gotcha (from [[crossplane-credential-rotation]], worth repeating
since it'll bite again)**: a new/replacement service account must be
explicitly granted the correct vault — one created previously defaulted to
`crossplane-controlplane-secrets` instead, and ESO failed with `vault
crossplane not found` despite the store showing `Valid`. Two dead service
account tokens were also hit this session before finding a working one
(`403 Forbidden — Service Account Deleted`) — worth an audit of stale
service accounts in this vault's admin page.
