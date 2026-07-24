---
name: m3-step6-secret-migration-eligibility
description: Rule for which secrets are safe to move to ESO+OpenBao in M3 step 6 and beyond — never migrate anything on OpenBao's own boot/dependency chain; Crossplane provider secrets confirmed clean
metadata:
  type: project
---

Decided 2026-07-24, at the user's explicit direction, before starting
[[m3-step-tracker]] step 6. `controlplane` is a specialty cluster that
bootstraps/provisions other infrastructure — moving a secret that
OpenBao itself (directly or via a dependency) needs to be unsealed or
operating into OpenBao-backed ESO creates a circular bootstrap: you'd
need OpenBao up to fetch the credential that something upstream of
OpenBao needs to run.

## The rule

Never migrate a secret into ESO+OpenBao if it belongs to something on
OpenBao's own dependency chain. Everything else is fair game.

## OpenBao's confirmed dependency chain (stays on SOPS, never migrates)

Traced via live cluster state (`kubectl get managed -A`, PVC
StorageClass refs, Secret annotations), not assumption:

- Talos/K8s API, Calico (foundational, out of scope for any secret
  discussion)
- cert-manager + `csi-driver-spiffe-ca` ClusterIssuer + trust-manager +
  cert-manager-approver-policy — OpenBao's own TLS `Certificate`
  chains through these (see [[m3-step-tracker]] step 5's SPIFFE-CSI
  detail)
- CNPG operator + `cnpg-barman-plugin` (cnpg-system)
- **democratic-csi + its TrueNAS API credential** — confirmed live:
  `openbao-db-{1,2,3}` PVCs are all on StorageClass
  `democratic-csi-nfs-pg`. The TrueNAS credential lives in
  `democratic-csi-{nfs,iscsi}-driver-config` Secrets in the
  `democratic-csi` namespace, SOPS-encrypted directly in-repo, **not**
  ESO-managed today — confirming this exclusion is already the de
  facto pattern, not just a new proposal.
- **Garage + its admin token + the `openbao-db-barman` /
  `step-ca-db-barman` Garage access keys** — `openbao-db`'s CNPG
  Cluster WAL-archives to Garage; those barman credentials
  (`openbao-db-barman-credentials.sops.yaml`,
  `step-ca-db-barman-credentials.sops.yaml`) and `garage-admin.sops.yaml`
  are SOPS today, same reasoning.
- Flux itself (`flux-system/sops-age`, `flux-ssh-key-secret`) — Flux
  deploys OpenBao in the first place; obviously can never be
  OpenBao-sourced. Confirmed live: `flux-ssh-key-secret` is applied
  out-of-band by `.bin/bootstrap-controlplane-flux-key.sh`, entirely
  separate from Crossplane's `github-token` (different secret, despite
  both being "GitHub credentials" by name — don't conflate them).
- `openbao-unseal.sops.yaml` itself, obviously.

## Crossplane provider secrets — confirmed clean, no circularity

Checked whether Crossplane is upstream of OpenBao in any way:
`kubectl get managed -A` shows Crossplane's **only** live managed
resources are DNS delegation (`Zone`, `Record` x4 NS records) and IAM
Roles-Anywhere plumbing (`Role`, `Policy`, `RolePolicyAttachment`,
`Profile`) for the `controlplane-rye-ninja` delegated zone — nothing
touching storage, CNPG, cert-manager, or CSI. OpenBao doesn't consume
anything Crossplane produces (it's ClusterIP-only, no external-dns
record, no ACME dependency). So migrating Crossplane's own credentials
to OpenBao is one-directional (Crossplane → OpenBao) with no path back
— safe.

Two ExternalSecrets already exist in `crossplane-system`, both
currently sourced from the `1password-sdk` ClusterSecretStore
(`clusters/controlplane/resources/eso.external-secret.{github,cloudflare}.yaml`):

- `github-token` — GitHub App creds (`app_id`, `installation_id`,
  `pem_file`, `owner`) for `provider-github`. Templated into a
  multi-field JSON blob — a more thorough test of the ESO+OpenBao
  templating path.
- `cloudflare-creds` — a single `api_token` field for
  `family-cloudflare` (DNS + zone providers). Simpler, minimal proof.

Either is a valid pick for step 6's one proof-of-concept
`ExternalSecret` (A4 scope: exactly one). Not yet decided which.

## How to apply

Before adding any future secret to the ESO+OpenBao migration list
(this step or later ones, e.g. a Keycloak local-admin credential in
step 9), re-run this same check: does OpenBao (or anything it
transitively needs to become Ready and serve) consume this secret or
anything downstream of it? If yes, it stays in SOPS. If the dependency
only runs the other direction, it's a valid migration candidate.
