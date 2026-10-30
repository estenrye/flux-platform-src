# Core Infra

## Provisioning Requirements

### SeaweedFS Barman Cloudflare R2 Bucket and Secret

Use the following commands to provision a bucket.

```bash
export CF_API_TOKEN=`op read "op://crossplane-controlplane-secrets/Cloudflare R2 Admin Service API Token/credential"`
CLUSTER=core-infra BUCKET_NAME=seaweedfs-db-barman SECRET_NS=seaweedfs make provision-cloudflare-r2-bucket
```
