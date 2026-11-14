# Harbor

Pull-through image registry for CI (`docs/adr/0031-harbor-pull-through-registry.md`).
Phases 1-2: Harbor 2.15.4 from chart 1.19.4 on core-infra. Public at `https://harbor.rye.ninja` (phase 2:
`harbor-gateway` on the `external-dedicated` class, Let's Encrypt certificate `harbor-rye-ninja-tls`, an HTTPRoute
straight to `harbor-core` / `harbor-portal`, sign-in with Keycloak). In-cluster clients use the `harbor` Service
(nginx, private CA `harbor-ca`); `kubectl -n harbor port-forward svc/harbor 8443:443` also works.

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

## Sign-in (phase 2)

- Harbor runs in `oidc_auth` mode (`CONFIG_OVERWRITE_JSON` from the ESO Secret `harbor-oidc`, applied on every
  start): issuer `https://id.rye.ninja/realms/ryezone-labs`, client `harbor`, scope
  `openid,email,profile,groups,offline_access`, groups claim `groups`, admin group `ACL_harbor-admins`,
  `project_creation_restriction: adminonly`. Harbor cannot limit sign-in by group: any realm user can onboard
  but has no projects.
- The client secret is generated in `keycloak` (`keycloak-harbor-client`), pushed to 1Password
  (`core-infra/harbor-oidc-client`, field `client-secret`) and read back into `harbor/harbor-oidc`. The Keycloak
  `harbor` client (confidential, PKCE S256 enforced) and group `ACL_harbor-admins` come from keycloak-config-cli:
  **re-run the keycloak-config-cli Job** after the Keycloak change merges, then restart `harbor-core`.
- Harbor core reaches `id.rye.ninja` through the keycloak-gateway Envoy pods on port 10443 (NetworkPolicy
  egress; Calico evaluates after DNAT).
- **Break-glass:** local `admin` still works at `https://harbor.rye.ninja/account/sign-in` (password in
  `harbor-secrets`); it is the only way in while Keycloak or public DNS is down.
- OIDC users pull with their per-user CLI secret (user profile in the UI); CI uses robot accounts (phase 3).

## Proxy-cache projects (phase 3)

- The CronJob `harbor-bootstrap` (daily 05:17 UTC; script `applications/harbor/base/resources/bootstrap.py`)
  reconciles through the API as the local admin: registry endpoints `dockerhub` (docker-hub),
  `gitea-images` (docker.gitea.com), `ghcr`, `quay`; **private** proxy-cache projects `dockerhub`, `gitea`,
  `ghcr`, `quay`; and the system robot `robot$runner-pull` with `repository:pull` on those four projects.
  After changing the script: `kubectl -n harbor create job --from=cronjob/harbor-bootstrap harbor-bootstrap-manual`.
- Image paths: `harbor.harbor.svc.cluster.local/dockerhub/library/alpine:3`,
  `.../gitea/runner-images:ubuntu-latest`, `.../ghcr/<owner>/<image>`, `.../quay/<owner>/<image>`.
- The robot's secret is generated by ESO (`harbor/harbor-robot-runner`), set on the robot by the job and
  pushed to 1Password (`core-infra/harbor-robot-runner`, field `secret`) for the runners (phase 4).
- Docker Hub credentials (anonymous pulls are rate limited): create the Secret `harbor-dockerhub` in `harbor`
  with keys `username` and `token` (a Docker Hub access token); the job sets them on the `dockerhub` endpoint.
- No quota or retention is set yet; a project's storage limit can be set in the UI or API once sizes are known.

## Known gaps (later phases)

- Database connection uses `sslmode: require` (encrypted, not verified); the chart cannot mount the
  CA for `verify-full`.
- Runners do not use it yet (phase 4); no Docker Hub credentials yet.
- Trivy is disabled.
