# Runbook: `crossplane` SOPS age-key exposure + credential rotation

Security incident + rotation plan for the leak of
`clusters/crossplane/.sops.age-key`.

## What happened

The **private** age key that decrypts the `crossplane` cluster's SOPS secrets
was committed to this repository, which is **public on GitHub**.

| | |
|---|---|
| Leaked artifact | `clusters/crossplane/.sops.age-key` (age *private* key) |
| Public recipient | `age15z6w9twdzawlgnupcrwjk29jj2xnyh5kkxgwgxxc8tcs298hu42q2fq7sl` |
| Entered history | 2026-06-09, commit `afe949f` ("Shell fixes", #57) |
| Untracked / gitignored | 2026-07-13, #66 — **but remains in public git history** |
| Exposure window | ~34 days, internet-readable |

Untracking the file (#66) stopped *future* commits from carrying it, but does
**not** remediate the leak: the key is still in the public commit history, and
anyone who cloned/forked in the window has it. The only real fix is to **rotate
everything it could decrypt** so the leaked key becomes worthless.

## Blast radius

The leaked key decrypts exactly one file in the repo today —
`clusters/crossplane/resources/eso.service-account-secret.yaml` — but that file
is the linchpin, so the effective exposure is transitive:

```
clusters/crossplane/.sops.age-key   (leaked, public)
        │ decrypts
        ▼
eso.service-account-secret.yaml  →  1Password service-account token
        │                            (secret onepassword-sdk-token,
        │                             ns external-secrets-operator;
        │                             read access to the `crossplane` vault)
        │ ESO ClusterSecretStore `1password-sdk` pulls from that vault:
        ├─► cloudflare-api-token/credential   → cloudflare-creds  (DNS control)
        ├─► github-auth-app/{app_id,installation_id,private key} → github-token
        └─► the crossplane sops-age-key + SA token themselves (vault is self-referential)
```

**Treat every credential in the `crossplane` 1Password vault as compromised.**

### Ranked by real-world impact

1. **Cloudflare API token** — controls DNS for the managed zones. Highest
   impact (record hijack, subdomain takeover, ACME/DNS-01 abuse). **Org-wide —
   outlives the crossplane cluster.**
2. **GitHub App private key** (`github-auth-app`) — the render/GitOps App's
   credential; write access to the rendered repos and read to source. Could
   push malicious manifests into the delivery path. **Org-wide — outlives
   crossplane.** (`app_id`/`installation_id` are not secret; the private key
   is.) *Realized risk is low: this App was never actually used —
   `provider-github` never authenticated with it, so no live installation
   tokens depended on the key. The exposed key and client
   secret were revoked in the GitHub App settings on 2026-07-13; a new key was
   generated and stored in 1Password. **DONE.***
3. **1Password service-account token** (`crossplane` vault) — read access to
   the whole vault; the pivot that unlocks 1 and 2. **Crossplane-scoped.**
   Revoked 2026-07-21 as part of M2 decommission closeout. **DONE.**
4. **Crossplane age key** — decrypts the cluster's SOPS secrets. This is the
   leaked artifact itself. **Crossplane-scoped.** Retired (not rotated) with
   the cluster at M2 decommission, 2026-07-21. **MOOT.**

### Not exposed by this key

- **AWS** — access is via IAM Roles Anywhere (X.509 / SPIFFE certs issued by
  cert-manager), not a static secret in the vault.
- **`controlplane` cluster secrets** — a *different* age key (gitignored,
  never committed).

## Rotation plan

Rotate underlying credentials **first** (revoke the old value, mint a new one),
**then** re-encrypt with a fresh age key. Re-encrypting alone is insufficient —
it would just re-wrap the *same already-leaked* secret values.

Priorities 1–2 are org-wide credentials that **must** be rotated regardless of
the crossplane cluster's fate (M2 decommissions crossplane, but Cloudflare and
the GitHub App live on). Priorities 3–4 are crossplane-scoped and die with the
cluster — rotate them now, or accept the residual risk only if M2 decommission
is imminent and the vault access is otherwise contained.

### 0. Check for abuse (do first, in parallel)

Review audit logs across the exposure window (2026-06-09 → 2026-07-13):
Cloudflare audit log (DNS edits, new tokens), GitHub App/org audit log
(installations, pushes, key generations), 1Password service-account access
report, and AWS CloudTrail (in case roles-anywhere trust was touched). Note
anything anomalous before rotating (rotation destroys some forensic state).

### 1. Cloudflare API token  — org-wide, do now

1. Cloudflare dashboard → create a **new** scoped token (same zone/DNS scope as
   the current one), then **revoke the old token**.
2. Update the 1Password item `cloudflare-api-token` (field `credential`).
3. ESO re-syncs `cloudflare-creds` to every cluster that consumes it; confirm
   external-dns / provider-cloudflare still reconcile.

### 2. GitHub App private key  — org-wide, do now

1. `.bin/rotate-github-app-credentials.sh` (or manually: GitHub App settings →
   *Generate a new private key*, update 1Password `github-auth-app`, then
   **delete the old key** in GitHub).
2. ESO re-syncs `github-token`; confirm the render pipeline and
   provider-github still authenticate.

### 3. 1Password service-account token  — crossplane-scoped

1. `.bin/rotate-cluster-service-account-token.sh` for `CLUSTER=crossplane`
   (or manually: revoke the old SA in 1Password, mint a new one scoped to the
   `crossplane` vault with `read_items`, and re-encrypt
   `eso.service-account-secret.yaml`).
2. This immediately cuts the transitive path even if someone holds the old
   token.

### 4. Crossplane age key + re-encrypt  — crossplane-scoped, do last

**Do NOT use the stock `.bin/rotate-cluster-sops-key.sh` here.** It updates the
on-cluster `sops-age` secret to the new key *before* pushing, and assumes Flux
reads the repo it pushes to. But this cluster's Flux reads the **rendered** repo
(`flux-platform-rendered`, path `./clusters/crossplane`, decrypt `sops-age`) via
a CI render pipeline. A hard key-swap would leave Flux unable to decrypt the
still-rendered old-key content until a merge + render lands — an open-ended
decryption outage on the crossplane Kustomization.

Use a **dual-key transition** instead (zero gap):

1. Generate the new age keypair. Set the on-cluster `flux-system/sops-age`
   secret's `age.agekey` to hold **both** the old and new private keys
   (newline-separated) — Flux tries each identity, so both old-recipient
   (currently rendered) and new-recipient content decrypt.
2. Point `clusters/crossplane/.sops.yaml` at the new recipient and
   `SOPS_CONFIG=clusters/crossplane/.sops.yaml sops updatekeys --yes` every
   `clusters/crossplane/**` SOPS file (with `SOPS_AGE_KEY` = old private key to
   decrypt). Commit `.sops.yaml` + the re-wrapped files. **The new private key
   is never committed** — `.gitignore` covers `clusters/crossplane/.sops.age-key`;
   it lives only in 1Password and on the cluster.
3. Merge → CI renders → `flux-platform-rendered` gets the new-key content →
   Flux decrypts it with the new key (already present). Verify the
   `flux-platform` Kustomization reconciles Ready with no decryption errors.
4. **Only then**, remove the old key from `flux-system/sops-age` (set it to the
   new key alone). The leaked key now decrypts nothing on the cluster.

Status (2026-07-13): steps 1–2 DONE (new recipient
`age18zfz6h2nt…`, dual-key secret live, re-wrapped file on PR #68, new key in
1Password `sops-age-key`). Steps 3–4 pending PR #68 merge + render.

**Status (2026-07-21) — moot by decommission.** M2 step 13 is deleting
the `crossplane` cluster entirely (Spot cloudspace destroyed, `clusters/
crossplane/` archived out of the live tree — see [ADR-24](../adr/0024-m2-control-plane-service-migration-off-spot.md)
and [[m2-step13-decommission]]). Completing steps 3–4 (dual-key
re-encryption merge/render) for a cluster about to stop existing buys
nothing — the leaked key's blast radius is closed by decommission itself,
not by finishing the transition. **Priority 3 (1Password service-account
token) rotation was completed directly by Esten as part of step 13's
incident closeout.** Priority 4 (crossplane age key) is retired, not
rotated — the key, the secret it protects, and the cluster it decrypts
for all cease to exist together.

### 5. Git history

Leave it. Once every credential above is rotated, the historical key decrypts
nothing of value. Rewriting public history (`git filter-repo`/BFG + force-push)
is disruptive to clones/forks and buys nothing after rotation — do it only if a
policy requires scrubbing the artifact itself.

## Prevention

- `.gitignore` now carries `clusters/crossplane/.sops.age-key` (and the
  per-cluster key path pattern) so a private key can't be re-added casually.
- Consider a pre-commit / CI guard (e.g. gitleaks) that fails on an
  `AGE-SECRET-KEY-` literal or a tracked `*.age-key`, since this repo is public.
- SOPS *encrypted* files are safe to commit; the **private** age key never is.
