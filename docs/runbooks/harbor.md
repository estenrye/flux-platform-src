# Harbor

Pull-through image registry for CI (`docs/adr/0031-harbor-pull-through-registry.md`).
Phase 1 (this runbook): Harbor 2.15.4 from chart 1.19.4 on core-infra, **ClusterIP only**.
Reach it with `kubectl -n harbor port-forward svc/harbor 8443:443`.

## Pieces

- `applications/harbor` (namespace `harbor`): chart, ESO-generated secrets
  (`harbor-secrets`: admin password, secretKey, component secrets), cert-manager CA
  (`harbor-ca`) with `harbor-tls` (nginx) and `harbor-token` (registry token signing),
  CertificateRequestPolicies, NetworkPolicy, VPAs.
- `applications/harbor-db`: CNPG cluster `harbor-db` (database `registry`, owner `harbor`),
  barman backups to SeaweedFS bucket `harbor-db-barman` (role `HarborDbBarman`), daily 04:15 UTC.
- SeaweedFS: buckets `harbor-db-barman` and `harbor-registry`, STS roles `HarborDbBarman`
  (ServiceAccount `harbor:harbor-db`) and `HarborRegistry` (`harbor:harbor-registry`).
- Registry blobs are in SeaweedFS (`s3`, `disableredirect: true`) with a **static key limited to the
  bucket**: identity `harbor-registry` (`Read/Write/List/ReadAcp/WriteAcp:harbor-registry`; the registry always sends `x-amz-acl: private`, which SeaweedFS rejects without the ACP actions) in `seaweedfs-s3-config`,
  key in 1Password `core-infra/harbor-registry-s3` (fields `accessKey`, `secretKey`), read into
  `harbor/harbor-registry-s3` by ESO. Harbor's registry (distribution 2.8.3, aws-sdk-go v1) has no
  web-identity credential provider (`NoCredentialProviders`), so the `HarborRegistry` STS role in the
  SeaweedFS IAM config is unused (remove it with the next IAM change). `seaweedfs-s3-config` is
  CreatedOnce: the identity was added to the live Secret by patching it, then the filers were
  restarted; the ExternalSecret template only matters for a fresh bootstrap. Rotating the key means
  changing the 1Password item, patching the SeaweedFS Secret to match, restarting the filers.

## Rollout order

1. Merge the SeaweedFS PR (buckets + roles). The roles live in the CreatedOnce Secret
   `seaweedfs-iam-config`; roll them out as described in
   `applications/seaweedfs/base/resources/eso.external-secret.iam-config.yaml`
   (delete the Secret, restart the filers). Confirm the buckets `harbor-db-barman` and
   `harbor-registry` exist (`createBuckets`).
2. Merge the Harbor PR and its render PR. Flux creates the `harbor` namespace, the CA and
   certificates, `harbor-db`, the secrets and the chart.
3. Verify (below).

## Verify

- `kubectl -n harbor get certificate` : `harbor-ca`, `harbor-tls`, `harbor-token` Ready (if one
  stays WaitingForApproval, check the CertificateRequestPolicy and its `use` ClusterRole).
- `kubectl -n harbor get cluster harbor-db` healthy with 3 instances; the first ScheduledBackup
  completes (`kubectl -n harbor get backup`).
- `kubectl -n harbor get pods`: core, jobservice, nginx, portal, registry, redis Running. The core
  pod waits for the database; check `kubectl -n harbor logs deploy/harbor-core`.
- Registry storage: `kubectl -n harbor logs deploy/harbor-registry -c registry` must show no S3
  errors; push a test image (crane copy from a pod labelled `app=harbor`, or through the
  port-forward) and list the `harbor-registry` bucket.
- Local admin: user `admin`, password `kubectl -n harbor get secret harbor-secrets -o
  jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d`.
- **Token realm (verified 2026-11-14):** Harbor builds the registry's `Www-Authenticate` realm from the
  request host, so a client using `harbor.harbor.svc.cluster.local` is sent to
  `https://harbor.harbor.svc.cluster.local/service/token`, not the public name. In-cluster clients
  stay on the Service name (trusting `harbor-ca`).

## Known gaps (later phases)

- Database connection uses `sslmode: require` (encrypted, not verified); the chart cannot mount the
  CA for `verify-full`.
- No Gateway, no Keycloak sign-in, no proxy-cache projects, runners do not use it yet.
- Trivy is disabled.
