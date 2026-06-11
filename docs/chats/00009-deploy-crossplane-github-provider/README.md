# Deploy Crossplane GitHub Provider with GitHub App Authentication

Date: May 26, 2026
Chat ID: 00009
Status: In progress (auth model and ESO template corrected; final in-cluster reconciliation pending)

## Objective

Set up provider-upjet-github authentication in the Crossplane control plane using a GitHub App and External Secrets Operator (ESO) with 1Password as the secret backend.

## Prompt Timeline

1. How do I create a GitHub application for authenticating the GitHub Crossplane provider?
2. What is the installation ID? Is it equivalent to the client secret?
3. Can I use the client ID instead of the app ID?
4. Document the creation of the GitHub Auth App in the Provisioning section of the cluster README.
5. Yes (apply GitHub App auth changes to ESO manifest).
6. The secret I am pulling from has 1Password UUID qok5yzeh4j7k44ckqjpjdrq4ue in vault psqynbegdx52mzknfzo55zmlwi.
7. The pem file is not named pem_file.
8. Explain why I am getting SecretSyncedError for ExternalSecret.
9. Document the prompts, context, and learnings in this chat folder.

## Repository Context

Relevant files in this session:
- [clusters/crossplane/README.md](clusters/crossplane/README.md)
- [clusters/crossplane/resources/eso.external-secret.github.yaml](clusters/crossplane/resources/eso.external-secret.github.yaml)
- [clusters/crossplane/kustomization.yaml](clusters/crossplane/kustomization.yaml)
- [applications/crossplane-providers/provider-github/resources/provider.yaml](applications/crossplane-providers/provider-github/resources/provider.yaml)

Environment context:
- Cluster access used with KUBECONFIG=/Users/esten/.kube/crossplane-controlplane-cluster.yaml
- ExternalSecret resource: github-token in namespace crossplane-system
- ClusterSecretStore: 1password-sdk (validated Ready=True)

## What Was Implemented

### 1. Documentation updates

Added GitHub App provisioning guidance to:
- [clusters/crossplane/README.md](clusters/crossplane/README.md)

The section now covers:
- Creating a GitHub App
- Choosing least-privilege permissions
- Installing the app to target owner
- Collecting App ID, Installation ID, owner, and private key PEM
- Clarifying App ID vs Client ID and Installation ID vs Client Secret

### 2. ESO manifest migration from token auth to app auth

Updated:
- [clusters/crossplane/resources/eso.external-secret.github.yaml](clusters/crossplane/resources/eso.external-secret.github.yaml)

Changes made:
- Replaced token-based template output with provider credentials JSON under key credentials
- Added app_auth payload with id, installation_id, pem_file and owner
- Added newline escaping for PEM in JSON payload
- Switched 1Password source paths to the provided vault/item UUID
- Pointed PEM source to the actual attached file name in 1Password item

## Live Cluster Debugging: SecretSyncedError

Observed condition from kubectl describe externalsecret github-token -n crossplane-system:
- Reason: SecretSyncedError
- Message: could not update secret
- Event detail: template execution failed at .app_id with map has no entry for key app_id

Root cause:
- spec.target.template.data.credentials referenced template keys app_id, installation_id, pem_file, owner
- spec.data entries had incorrect secretKey values (same UUID string for every mapping)
- ESO template context is keyed by secretKey names, so app_id did not exist in the template map

Conclusion:
- Secret store connectivity was healthy
- Failure was template variable/key mismatch in ExternalSecret spec

## Key Learnings

1. provider-upjet-github GitHub App auth uses:
- App ID (numeric)
- Installation ID (numeric)
- Private key PEM
- Owner

2. Installation ID is not client secret
- Installation ID identifies a specific app installation on org/user
- Client secret belongs to OAuth flow and is not used by this provider auth path

3. Client ID cannot replace App ID
- App ID is required for GitHub App JWT/token exchange

4. ESO template variables are strict
- Template references must match spec.data secretKey values exactly
- A mismatch causes SecretSyncedError with template execution failures

5. 1Password file attachments can be read directly via op:// path
- The PEM can come from attachment name path, not only from a text field

## Operational Notes

Commands used for verification included:
- kubectl get externalsecret -n crossplane-system -o yaml
- kubectl describe externalsecret github-token -n crossplane-system
- kubectl get clustersecretstore 1password-sdk -o yaml
- op item get qok5yzeh4j7k44ckqjpjdrq4ue --vault psqynbegdx52mzknfzo55zmlwi --format json
- op read op://psqynbegdx52mzknfzo55zmlwi/qok5yzeh4j7k44ckqjpjdrq4ue/crossplane-rye-ninja.2026-05-25.private-key.pem

## Remaining Work

1. Ensure the ExternalSecret manifest currently in git has secretKey names aligned to template keys:
- app_id
- installation_id
- pem_file
- owner

2. If this resource should reconcile via current overlay, include it in:
- [clusters/crossplane/kustomization.yaml](clusters/crossplane/kustomization.yaml)

3. Verify end-to-end provider auth:
- ExternalSecret Ready=True
- Secret github-token contains credentials
- ProviderConfig references key credentials
- A simple GitHub managed resource reconciles successfully
