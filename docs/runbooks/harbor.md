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
- Registry blobs are in SeaweedFS (`s3`, `disableredirect: true`). The registry authenticates
  with the projected ServiceAccount token (audience `seaweedfs-s3`, `AWS_ROLE_ARN` etc. in
  `values.yaml`), no static keys. **Unverified until first deploy**; if the registry cannot use web
  identity, use a static key limited to `harbor-registry` (not the admin identity).

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
- Registry storage over web identity: `kubectl -n harbor logs deploy/harbor-registry -c registry`
  must show no S3/STS errors; push a test image through the port-forward and list the bucket.
- Local admin: user `admin`, password `kubectl -n harbor get secret harbor-secrets -o
  jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d`.
- **Token realm:** Harbor puts `externalURL` (`https://harbor.rye.ninja`) in the registry's
  `Www-Authenticate` realm. From a pod, `curl -sk -D- https://harbor.harbor.svc.cluster.local/v2/`
  and read the realm. If it points at the public name, in-cluster clients can only authenticate
  if that name resolves to the Service inside the cluster (phase 2/4 decision: split-horizon
  DNS for `harbor.rye.ninja`).

## Known gaps (later phases)

- Database connection uses `sslmode: require` (encrypted, not verified); the chart cannot mount the
  CA for `verify-full`.
- No Gateway, no Keycloak sign-in, no proxy-cache projects, runners do not use it yet.
- Trivy is disabled.
