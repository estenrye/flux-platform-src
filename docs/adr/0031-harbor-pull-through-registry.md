# 31. Harbor as the pull-through image registry for CI

Date: 2026-11-14

## Status

Proposed

## Context

Gitea Actions runs on ephemeral rootless runners (`applications/gitea-runner`). Every job pulls
`docker.gitea.com/runner-images:ubuntu-latest` (about 3 minutes) and any base images its
`docker build` steps use, from the internet through NAT64. Spegel cannot help: the dockerd in a
runner pod has its own image store, never uses the node's containerd mirrors, and Docker's
`registry-mirrors` only supports Docker Hub. Builds must keep working without internet access
(Go, Rust, Docker, Python and Helm builds), so the images have to be served from inside the
homelab.

Constraints found while building the runners:

- Pods in the restricted runner namespace did not reach the Gateway VIPs (the pod-to-VIP path was
  blocked or hairpinned; a pod in an unrestricted namespace does reach `https://id.rye.ninja`), and
  an offline build must not depend on public DNS or the VIP at all, so CI uses an in-cluster
  Service name, not `harbor.rye.ninja`.
- The nodes and the runner pods are IPv6-only; IPv4-only upstreams work through DNS64/NAT64.
- SeaweedFS S3 on core-infra authenticates workloads with web identity (projected ServiceAccount
  tokens, `AssumeRoleWithWebIdentity`), plus one static admin identity
  (`applications/seaweedfs/base/resources/eso.external-secret.iam-config.yaml`).
- A pull-through cache only holds what has been pulled once, so offline use needs a warm-up step.

## Decision

Run Harbor (`goharbor/harbor-helm`, chart 1.19.x, Harbor 2.15) on core-infra as
`applications/harbor` and `applications/harbor-db`, with:

- **Exposure:** `harbor.rye.ninja` on an `external-dedicated` Gateway (like Gitea and Keycloak),
  cert-manager `letsencrypt-prod`, the trace-header sanitising ClientTrafficPolicy, UI sign-in
  with Keycloak OIDC (see below). All proxy-cache projects are **private**: an open pull-through cache on a
  public address would let anyone on the internet fill the cache and spend the uplink.
- **Sign-in (Keycloak OIDC):** Harbor's `oidc_auth` mode, set through the chart's
  `core.configureUserSettings` (`oidc_endpoint: https://id.rye.ninja/realms/ryezone-labs`,
  `oidc_client_id: harbor`, scope `openid,email,profile,groups`, `oidc_groups_claim: groups`,
  `oidc_admin_group: ACL_harbor-admins`, `oidc_user_claim: preferred_username`, auto-onboard on).
  Keycloak gets a confidential client `harbor` (redirect
  `https://harbor.rye.ninja/c/oidc/callback`, the existing `groups` scope) and groups
  `ACL_harbor-users` / `ACL_harbor-admins` in the keycloak-config-cli ConfigMap, with the client
  secret generated in the `keycloak` namespace, shared through 1Password and read back by ESO, as
  for Gitea. Harbor requires the discovery document's issuer to equal `oidc_endpoint` exactly (no
  separate discovery URL), so Harbor core reaches Keycloak through the public issuer URL and its
  NetworkPolicy must allow that egress. Auth mode must be chosen before any local users beyond
  `admin` exist, so it is set at first install. The local `admin` (password from ESO) stays as
  break-glass at `/account/sign-in`, and is the only way in while Keycloak or public DNS is down.
  OIDC users pull with their per-user CLI secret; CI uses robot accounts, not OIDC identities.
- **Database:** a CNPG cluster `harbor-db` modelled on `gitea-db` (verify-full TLS from the
  cert-manager self-signed CA, barman backups to SeaweedFS). Harbor's bundled Redis (valkey) stays
  in-chart with a small volume.
- **Blob storage:** the SeaweedFS S3 gateway, bucket `harbor-registry`, through a dedicated
  `HarborRegistry` role bound to the registry's ServiceAccount with web identity. If the registry
  image cannot use web identity, fall back to a dedicated static key limited to that bucket, not
  the admin identity.
- **In-cluster TLS:** Harbor's internal Service is served over TLS with a certificate from a
  cluster CA (cert-manager), with the CA bundle distributed by trust-manager into the runner
  pods' dockerd (`/etc/docker/certs.d/<service-name>/ca.crt`). The runners pull
  `harbor.harbor.svc.cluster.local` names, never the public VIP.
- **Proxy-cache projects:** `dockerhub` (docker.io), `gitea` (docker.gitea.com), `ghcr`
  (ghcr.io) and `quay` (quay.io). Harbor has no declarative API objects, so a bootstrap Job
  (idempotent, API based, like the Healthchecks bootstrap) creates the registry endpoints, the
  projects and a read-only robot account for the runners. Docker Hub credentials from 1Password
  avoid anonymous rate limits.
- **Runner integration:** the runner labels point at the Harbor project paths
  (`harbor.harbor.svc.cluster.local/gitea/runner-images:ubuntu-latest`), dockerd gets
  `--registry-mirror` for Docker Hub plus the robot's `config.json` from an ESO Secret, and the
  runner NetworkPolicy allows the Harbor Service.
- **Warm-up:** a CronJob pulls the images that builds depend on (runner images, the base images
  and tools used by Go/Rust/Python/Helm workflows) through Harbor so they exist before the
  internet disappears.

## Phases (one PR or small series each)

1. **Foundations:** `harbor` namespace, `harbor-db`, SeaweedFS `HarborRegistry` role and
   bucket, ESO secrets (admin password, core/jobservice/registry secrets), internal TLS
   certificates, the chart with `expose.type: clusterIP`, NetworkPolicies, VPA, catalog entries.
   Verify with `kubectl port-forward`.
2. **Gateway and sign-in:** Gateway, certificate, HTTPRoute, DNS, Keycloak `harbor` client and
   groups, ClientTrafficPolicy.
3. **Proxy-cache bootstrap Job** and the Docker Hub credentials.
4. **Runner integration:** trust-manager bundle, dockerd settings, registry login, labels,
   NetworkPolicy. Verify a cold job pulls through Harbor, then a second pod hits the cache.
5. **Warm-up CronJob, monitoring (ServiceMonitor, Healthchecks ping) and a restore drill.**

## Risks and open questions

- Whether Harbor's registry (distribution) takes web-identity credentials against SeaweedFS STS;
  the fallback is a bucket-scoped static key.
- Harbor chart IPv6 support (`ipFamily.ipv6.enabled`) on an IPv6-only cluster, including its
  nginx. Gateway routing may allow dropping the chart's nginx proxy.
- Harbor's Trivy and ChartMuseum are not needed for a cache; start with them disabled to save
  resources (Trivy can be added later).
- An externally exposed registry needs strict authentication and rate limiting; confirm the
  Gateway's client policies before DNS goes public.
- Pull-through quota: a cache of the runner images, base images and tool images needs a size
  budget and a retention policy.

## Consequences

- CI image pulls come from the cluster after the first pull, and builds keep working through an
  internet outage for anything warmed up.
- A new stateful service to back up (database through barman, blobs in SeaweedFS) and monitor.
- Images that are not pulled through the Harbor path still use the internet; workflows and
  Dockerfiles for CI must reference the Harbor project paths.
