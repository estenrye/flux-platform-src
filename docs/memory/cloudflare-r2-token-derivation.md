---
name: cloudflare-r2-token-derivation
description: How to derive S3-compatible Access Key ID/Secret Access Key from a Cloudflare R2-scoped API token created via the generic accounts/{id}/tokens endpoint
metadata:
  type: reference
---

Discovered 2026-07-24 while automating a second off-site R2 backup bucket
(step-ca-db, mirroring [[m3-step-tracker]] step 7's openbao pattern).

**The generic Cloudflare API Token endpoint CAN mint R2-scoped credentials**
— `POST /accounts/{account_id}/tokens` with `permission_groups` "Workers R2
Storage Bucket Item Read" (`6a018a9f2fc74eb6b293b0c548f38b39`) / "...Item
Write" (`2efd5506f9c8494dacb1fa10a3e7d5b6`), `resources` keyed on
`com.cloudflare.edge.r2.bucket.<account_id>_default_<bucket_name>`. This
does **not** require dashboard access — an account-scoped admin token with
`Account.API Tokens Write` is sufficient (confirmed: also used to create
the R2 bucket itself via `POST /accounts/{account_id}/r2/buckets`).

The response's `id`/`value` are **not** directly usable as S3
`aws_access_key_id`/`aws_secret_access_key` — they need one transform:

- **Access Key ID = the token's `id` field, used as-is** (already a
  32-char hex string — no hashing).
- **Secret Access Key = `SHA256(token value)`**, hex digest (64 chars).

**Got this wrong on the first attempt**: guessed `SHA256(id)[:32]` for the
access key ID (over-engineered, hashing something that didn't need it) —
failed with a bare `Unauthorized` from the R2 S3 API, no other diagnostic.
Verified the corrected formula end-to-end: `aws s3 ls` / `cp` / `rm`
round-trip against the bucket, scoped correctly (only that bucket, per the
`resources` policy).

**How to apply**: next time an R2-scoped S3 credential needs minting
programmatically (not via dashboard), use this exact derivation and
verify with a live `aws s3 ls`/`cp` round-trip *before* trusting/encrypting
it — don't recall the formula from memory a second time without
re-verifying, since it's easy to get subtly wrong and the failure mode
(bare `Unauthorized`) doesn't tell you which half is wrong.
