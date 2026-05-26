# crossplane.rye.ninja

## Provisioning the Github Auth Application

Create a GitHub App dedicated to Crossplane so the GitHub provider can authenticate
without using a personal access token.

1. Create the GitHub App
   - Go to GitHub Settings -> Developer settings -> GitHub Apps -> New GitHub App.
   - Set a descriptive app name (for example, crossplane-provider-github).
   - Set Homepage URL to your platform or repository URL.
   - Disable Webhook unless you explicitly need it.

2. Configure permissions (least privilege)
   - Add only the repository and organization permissions required by the resources
     Crossplane will manage.
   - Metadata read access is generally required.
   - Common permissions for repository management are:
     - Administration
     - Contents
     - Metadata
     - Webhooks
   - Add organization permissions only if managing org-scoped resources.

3. Install the app
   - Install the app to the target owner (organization or user account).
   - Select either all repositories or a restricted repository set as needed.

4. Collect required values
   - App ID (numeric) from the app settings page.
   - Installation ID (numeric) from the installation page URL:
     /settings/installations/<installation_id>
   - Private key PEM from "Generate a private key".
   - Owner value (the GitHub org or user name where resources are managed).

5. Store values in 1Password for External Secrets Operator
   - Save the following fields in the 1Password item used by the Crossplane GitHub
     ExternalSecret:
     - app_id
     - installation_id
     - pem_file
     - owner

Notes:
- For provider-upjet-github GitHub App auth, use App ID, not Client ID.
- Installation ID is not the OAuth client secret.
- The private key must be preserved exactly; if embedded in JSON, newlines must be
  escaped as \n.



## External Secrets Operator Initialization

To initilalize the External Secrets Operator, run the following command:

```bash
kubectl create secret generic \
  -n external-secrets-operator onepassword-sdk-token  \
  --from-literal=token=`op read --account ryefamily.1password.com op://psqynbegdx52mzknfzo55zmlwi/4qdx2ybgrw4ctrx475g7u7dnua/credential`
```
