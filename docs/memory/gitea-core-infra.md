---
name: gitea-core-infra
description: Gitea on core-infra (git.rye.ninja, 2026-11-11): the controlplane target no longer existed; Gitea 1.27 can't do PKCE as an OIDC client so Keycloak uses a confidential client; backchannel-dynamic hostname for the pod hairpin
metadata:
  type: project
---

Asked to deploy Gitea "on the controlplane cluster" the day it was decommissioned ([[controlplane-decommission]]);
Esten chose **core-infra** instead. Layout and rollout steps: `docs/runbooks/gitea.md`.

**Why a confidential client, not PKCE.** Gitea 1.27's OIDC client (goth `openidConnect` v1.82.0) never sends a
`code_challenge`, and `gitea admin auth add-oauth` has no PKCE flag; PKCE exists only on Gitea's provider side.
Esten approved a client-secret client. Keycloak PKCE enforcement must stay off for the `gitea` client.

**Hairpin.** Pods can't reach `id.rye.ninja` ([[calico-33-gateway-namespace-mode]] for the gateway layout), and Gitea
takes token/userinfo URLs from the discovery document, so Keycloak got `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true`
(approved) and Gitea discovers via `keycloak-http.keycloak.svc`. Unverified live at the time of writing.

**Shared secret.** The client secret is generated in `keycloak`, pushed to 1Password (`gitea-oidc-client`) and
read back in `gitea`, which required adding `keycloak` and `gitea` to the `1password-sdk` ClusterSecretStore
namespace conditions.

**How to apply.** Nothing was applied to a cluster or committed in the first session: rendering and
kube-linter/checkov were clean, but the SeaweedFS IAM Secret (CreatedOnce) and Keycloak Job re-run are manual.

**Repo storage.** Repos go on a TrueNAS NFSv4 dataset (`gitea-repos`, 50 GiB refquota) via a static PV, not SeaweedFS
FUSE; provisioning is in `pcd-ce-deploy/tofu-truenas/gitea.tf`. NAS UID/GID 3004: GIDs 3002/3003 were taken
(app_shares, replication), 3000-3001 are esten/hp-scan/replication users. The NAS already had NFSv3+v4 enabled; v4 is
enforced by the PV mount option only, because disabling v3 on the server would hit the PCD Cinder/Glance exports. HA
(Valkey, RWX, indexer) was deliberately deferred; see [[core-infra-nfs-outage-2026-11]] for why the shared NAS
dependency matters.

**Rolled out 2026-11-12 (PRs #312-#315).** Live and serving at https://git.rye.ninja; Keycloak redirect and in-cluster
discovery verified, an interactive login was not (needs a human). Three things only the live cluster showed:
- CNPG 1.30's `bootstrap.initdb` has **no `template` field** (Flux's dry-run rejected the whole apply); `encoding` and
  `localeCollate/CType` go to Postgres's initdb, so the app database inherits them.
- CNPG with cert-manager certs: setting `serverCASecret` alone makes the operator try to sign client certs with it and fail
  on a missing `ca.key`; also issue a `streaming_replica` client cert and set `clientCASecret` + `replicationTLSSecret`.
  A **denied** CertificateRequest is final and cert-manager then backs off ~1h: delete the Certificate to reissue.
- A volume mounted **inside** another volume (NFS at `/data/git/gitea-repositories` under the Cinder `/data`) makes kubelet
  create the mountpoint as root and breaks `mkdir` for UID 1000; mount it elsewhere (`/repos`, `repository.ROOT`).
Rollout steps that were manual: deleting the CreatedOnce `seaweedfs-iam-config` Secret and restarting the filers (existing
databases' archiving stayed healthy), and nothing for Keycloak (the config Job had already run; its 10-minute TTL had removed it).

**Mirroring from GitHub (PRs #317-#319, 2026-11-12).** Verified working end to end (mirror of a private repo, sign-out).
- Gitea's default `external` migration rule treats `64:ff9b::/96` as reserved, and DNS64 makes github.com resolve there
  from the IPv6-only nodes, so every import was "disallowed hosts". Fix: `migrations.ALLOWED_DOMAINS` hostname list.
- The Gitea NetworkPolicy had no internet egress; the next failure was an i/o timeout to the NAT64 address. Fix: TCP 443
  to `64:ff9b::/96`.
- Gitea's sign-out link failed with an invalid redirect URI until the Keycloak client got `post.logout.redirect.uris`.
- The 1Password item's token is in the `token` field. A fine-grained PAT is scoped to one resource owner and cannot see a
  private org repo (404); a classic PAT with `repo` worked. Gitea does not resolve `op://` references.

