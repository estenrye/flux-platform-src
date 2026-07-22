# Runbook: Cloudflare R2 Token Rotation

Applies to all R2 buckets provisioned by `.bin/provision-cloudflare-r2-bucket.sh`
(openbao-snapshots, step-ca-db-barman, keycloak-db-barman, lgtm, jwks, …).

## Rotation cadence

Rotate annually or immediately after any suspected credential exposure.
The token ID is stored in 1Password (`cloudflare-r2-<bucket>` item, `token-id`
field) so the rotation script can find and delete the old token automatically.

## Prerequisites

- `CLUSTER` — the cluster whose vault holds the credentials
- `BUCKET_NAME` — the bucket whose token is being rotated
- `CF_API_TOKEN` — a Cloudflare API token with **R2:Edit** and **Account:Read**
  permissions (your personal admin token; not stored anywhere by the script)

Verify you have the admin token available:

```bash
curl -sf -H "Authorization: Bearer ${CF_API_TOKEN}" \
  "https://api.cloudflare.com/client/v4/accounts" | jq '.result[0].name'
```

## Rotation steps

```bash
CLUSTER=controlplane \
BUCKET_NAME=openbao-snapshots \
CF_API_TOKEN=<your-admin-token> \
make rotate-cloudflare-r2-token
```

The script:
1. Reads the old token ID from 1Password
2. Creates a new scoped R2 token with identical bucket permissions
3. Updates 1Password with the new credentials
4. Re-encrypts the SOPS Secret at `clusters/${CLUSTER}/secrets/cloudflare-r2-${BUCKET_NAME}.sops.yaml`
5. Deletes the old Cloudflare token

## After rotation

```bash
# Commit the re-encrypted secret
git add clusters/${CLUSTER}/secrets/cloudflare-r2-${BUCKET_NAME}.sops.yaml
git commit -m "chore: rotate cloudflare-r2-${BUCKET_NAME} token for ${CLUSTER}"
# Open a PR and merge through normal flow
```

After the rendered PR merges and Flux reconciles, force-sync ESO to pick up
the new credentials immediately rather than waiting for the next refresh cycle:

```bash
# Find the ExternalSecret that references this Secret
kubectl get externalsecret -A | grep "${BUCKET_NAME}"

# Force a sync
kubectl annotate externalsecret <name> -n <namespace> \
  force-sync=$(date +%s) --overwrite
```

Verify the consuming CronJob or Deployment can still write to R2 by triggering
a manual backup run and checking for a new object in the bucket.

## Provisioning a new cluster

When bootstrapping a new cluster that needs R2 buckets, run the provision
script for each bucket:

```bash
CLUSTER=<new-cluster> \
BUCKET_NAME=openbao-snapshots \
SECRET_NS=openbao \
CF_API_TOKEN=<your-admin-token> \
make provision-cloudflare-r2-bucket
```

Repeat for each bucket the cluster needs. Each bucket gets its own
1Password item and SOPS Secret, scoped to that cluster's vault and age key.

## Troubleshooting

**"R2 token creation failed"** — check that `CF_API_TOKEN` has `R2:Edit`
permission at the account level, not just zone level. R2 is an account-scoped
product.

**"token-id not found in 1Password"** — the bucket may have been provisioned
before this runbook existed. Manually create the 1Password item with the
fields `token-id`, `access-key-id`, `secret-access-key`, `account-id`,
`endpoint`, `bucket`, then re-run the rotation script.

**API shape errors ("missing 'accessKeyId'")** — Cloudflare may have changed
the R2 token API response shape. Check `https://developers.cloudflare.com/r2/`
and update the `jq` paths in `.bin/provision-cloudflare-r2-bucket.sh` and
`.bin/rotate-cloudflare-r2-token.sh` accordingly.
