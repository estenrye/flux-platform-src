# Core Infra

## Provisioning Requirements

### SeaweedFS Barman Cloudflare R2 Bucket and Secret

Use the following commands to provision a bucket. `SOPS_ENCRYPT=false` keeps the
credentials out of the repository: no `.sops.yaml` file is written, and they are
stored only in the 1Password item `cloudflare-r2-seaweedfs-db-barman` in the
`core-infra` vault. The `seaweedfs-db-barman-credentials` ExternalSecret in
`applications/seaweedfs-db` reads them from there.

```bash
export CF_API_TOKEN=`op read "op://crossplane-controlplane-secrets/Cloudflare R2 Admin Service API Token/credential"`
CLUSTER=core-infra BUCKET_NAME=seaweedfs-db-barman SECRET_NS=seaweedfs SOPS_ENCRYPT=false make provision-cloudflare-r2-bucket
```

To rotate the token later, pass the same flag (see
`docs/runbooks/cloudflare-r2-token-rotation.md`):

```bash
CLUSTER=core-infra BUCKET_NAME=seaweedfs-db-barman SOPS_ENCRYPT=false make rotate-cloudflare-r2-token
```
