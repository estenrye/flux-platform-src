---
name: crossplane-credential-rotation
description: How the crossplane cluster's SOPS age key and 1Password SA token were rotated; Flux reads the rendered repo so age rotation needs a dual-key transition
metadata:
  type: project
---

Lessons from the 2026-07-13 crossplane SOPS-key exposure remediation (leaked
`clusters/crossplane/.sops.age-key` in a public repo). Full runbook:
`docs/runbooks/crossplane-sops-key-exposure.md`.

**Flux on the crossplane cluster reads the RENDERED repo, not source.**
`GitRepository` → `flux-platform-rendered` (branch `main`, path
`./clusters/crossplane`), decrypting with the `flux-system/sops-age` secret.
So the stock `.bin/rotate-cluster-sops-key.sh` is unsafe here — it swaps the
on-cluster key before the new-key content is rendered, breaking decryption
until a merge+render lands.

**Age-key rotation = dual-key transition (zero gap):**
1. Generate the new age key.
2. Set `flux-system/sops-age` `age.agekey` to hold BOTH old + new private keys
   (newline-separated). Flux tries each identity, so old-recipient (currently
   rendered) and new-recipient content both decrypt.
3. Point `clusters/crossplane/.sops.yaml` at the new recipient and re-key files:
   `SOPS_AGE_KEY=<old> SOPS_CONFIG=clusters/crossplane/.sops.yaml sops updatekeys --yes <file>`
   (`updatekeys` takes no `--config` flag; it reads `SOPS_CONFIG`).
4. Commit → merge → render → merge the rendered PR → Flux applies with the new
   key. Verify the `flux-platform` kustomization is Ready on the new revision.
5. Only then remove the old key from `sops-age`.

**1Password SA-token rotation gotcha:** the ClusterSecretStore `1password-sdk`
references `vault: crossplane`, and all items (`cloudflare-api-token`,
`github-auth-app`, `sops-age-key`, `service-account-token`) live in the
**`crossplane`** vault. When rotating the SA token, the new service account
MUST be granted the **`crossplane`** vault. A new SA defaulted to a different
vault (`crossplane-controlplane-secrets`) once, so ESO failed with
`failed to get store ID: vault crossplane not found` even though the store
showed `Valid` (validation checks auth, not vault access). The token is
delivered via the SOPS-encrypted `eso.service-account-secret.yaml`, so a live
`kubectl` patch is reverted by Flux until the re-encrypted secret is rendered.

**GitHub App key** is pulled by ESO from a stable `private-key` field on the
`github-auth-app` item (not a dated `.pem` file attachment) — future key
rotations are content-only, no ExternalSecret change.

**How to apply:** the crossplane cluster runs on Rackspace Spot; get its
kubeconfig via [[cluster-kubeconfig-lookup]]. Related:
[[sops-creation-rule-input-path]], [[rendered-repo-automerge-milestone]].
