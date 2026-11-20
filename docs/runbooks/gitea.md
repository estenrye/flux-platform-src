# Gitea (git.rye.ninja)

Gitea on core-infra: `applications/gitea` (Helm chart 12.7.0, Gitea 1.27.0 rootless),
database `applications/gitea-db` (CNPG, 3 instances, barman backups to the SeaweedFS
bucket `gitea-db-barman`, daily 04:00 UTC), exposed by the `gitea-gateway` Gateway
(class `external-dedicated`, Let's Encrypt) with the chart-rendered HTTPRoute, plus a
TCP listener on 22 for Git over SSH (see "Git over SSH").

## Rollout order

Everything is in `clusters/core-infra/kustomization.yaml`; two pieces need a manual nudge
because they are created once:

1. **SeaweedFS IAM** (`GiteaDbBarman` role) lives in the CreatedOnce Secret
   `seaweedfs-iam-config`. Roll it out as described in
   `applications/seaweedfs/base/resources/eso.external-secret.iam-config.yaml`
   (delete the Secret, restart the filers). The `gitea-db-barman` bucket comes from
   `createBuckets`; confirm it exists before the first backup.
2. **Keycloak**: re-run the keycloak-config-cli Job so the `gitea` client and the
   `ACL_gitea-users` / `ACL_gitea-admins` groups exist, and restart Keycloak so
   `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` takes effect. The client secret is generated in the
   `keycloak` namespace (`keycloak-gitea-client`), pushed to 1Password
   (`core-infra` vault, item `gitea-oidc-client`, field `client-secret`) and read back
   into `gitea/gitea-oidc-client`. Gitea's init container fails until that Secret
   exists; it retries.

## Authentication

- Keycloak realm `ryezone-labs`, client `gitea`, **confidential** (authorization code
  with a client secret). Gitea 1.27 cannot act as a PKCE client: its OIDC provider
  sends no `code_challenge`, and `gitea admin auth add-oauth` has no PKCE option. Do not
  turn on "Proof Key for Code Exchange" for this client in Keycloak, Gitea's requests
  would be rejected.
- Sign-in requires the Keycloak group `ACL_gitea-users`; `ACL_gitea-admins` sets the
  Gitea admin flag on each login. Add admins to both (groups do not nest).
- Redirect URI: `https://git.rye.ninja/user/oauth2/Keycloak/callback` (the source name
  `Keycloak` is part of the path).
- The pod cannot reach `id.rye.ninja` through the gateway (hairpin), so discovery is
  fetched from `keycloak-http.keycloak.svc.cluster.local`. Keycloak's
  `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` makes that document list in-cluster token and
  userinfo URLs, while the issuer and authorization URL stay public.
- Sign-out: the client's `post.logout.redirect.uris` is `https://git.rye.ninja/*`; without
  it Keycloak rejects Gitea's logout redirect as an invalid redirect URI.
- Break-glass local admin: Secret `gitea/gitea-admin` (`username`, `password`).

## Git over SSH

- Clone URL: `git@git.rye.ninja:owner/repo.git` (port 22). The `gitea-gateway` Gateway has a
  TCP listener `ssh` on 22 and the chart's TCPRoute sends it to the `gitea-ssh` Service
  (22 -> pod port 2222). `git.rye.ninja` already resolves to the Gateway's address, so no
  extra DNS record. Envoy binds privileged ports as 10000+port, so an edge firewall or
  anything inspecting the proxy sees 10022 inside the cluster.
- Gitea's built-in SSH server (rootless image) listens on 2222 as a non-root user; it only
  accepts public keys. Users add keys under Settings -> SSH / GPG Keys after signing in
  through Keycloak. Host keys are generated on first start under `/data/ssh` (Cinder
  volume), so they survive restarts; clients will see a host key change if `/data` is
  ever lost.
- Who can connect is decided in three places, and all three must allow a client:
  1. The `ssh` security group (`pcd-ce-deploy/tofu-pcd-talos-cluster`,
     `ssh_allowed_prefixes`): the ULA prefixes `fd97:45c2:b3a1::/48` and
     `fd92:b792:95e:db94::/64` plus the ISP-delegated GUA `/60`
     (`2607:3640:1064:270::/60`). The Gateway's address is a public GUA, so a LAN client
     reaches it from its own **GUA** source address, not its ULA; a ULA-only list times
     out for ordinary clients (found live: a connect with `-s <ULA>` worked, the default
     source did not). The `/60` changes if the ISP re-delegates, see
     `gua-prefix-renumber.md`. Anything else (for example a WireGuard client sourcing
     from `fd54:616c:6f73::`) is dropped until its prefix is added.
  2. The UniFi zone firewall: VIPs are routed prefixes that belong to no zone, so another
     zone needs a Policy Table rule scoped to the destination IP and port 22
     (`unifi-zone-firewall.md`). Internal LAN clients already work without one.
  3. Nothing further in the cluster: the NetworkPolicy below only admits Envoy.
- Connection cap: `gitea-gateway-ssh-connection-limit` (ClientTrafficPolicy on the `ssh`
  listener) limits concurrent connections to 100 per Envoy pod, closing extras after 1s.
  It is a ceiling, not a per-client rate limit, and was chosen well above real use (a person
  plus CI needs under 20). A per-client new-connection limit
  (`BackendTrafficPolicy` `rateLimit.local` on the TCPRoute) was not added: it is not
  verified that Envoy Gateway applies it to TCP routes, so test that before relying on it.
- Monitoring: the Healthchecks check `gitea-ssh` (5 minute period, 10 minute grace) is pinged
  by `gitea-ssh-probe.timer` on the Healthchecks VM (`pcd-ce-deploy` ansible,
  `files/gitea-ssh-probe.py`), which connects to `git.rye.ninja:22` and reads the
  `SSH-2.0-` banner. It runs outside the cluster because pods cannot reach the Gateway's
  own VIP. It proves the path end to end but does not authenticate. Envoy's TCP listener
  metrics are scraped by the `envoy-proxy` PodMonitor; there is no alert rule on them.
  Gitea only sees Envoy's pod IP as the client address (PROXY protocol is not enabled).
- `gitea-ssh` is a headless Service (the chart default): a Service's `clusterIP` cannot be
  changed in place, and Envoy resolves it through the EndpointSlice, which works.
- The `gitea` NetworkPolicy allows ingress from the Gateway's Envoy pods on 2222 (the pod
  port: Calico evaluates after DNAT).

## Merge signing

Gitea signs every **PR merge commit** it creates, with one instance SSH key, so `applier-01`
(pcd-lab-manager's pull-based reconciler, AP-D6) can check that a commit on `main` really came from
Gitea's merge and not from a push. Requirements: `esten/pcd-lab-manager`
`docs/superpowers/specs/2026-11-16-gitea-merge-signing-requirements.md`.

- **Config:** `[repository.signing]` in `applications/gitea/base/values.yaml`: `SIGNING_FORMAT=ssh`,
  `MERGES=always`, key at `/etc/gitea-signing/signing-key.pub` (the private half sits next to it).
  `always` signs merges by any user, API or UI, so `scotty`'s API merges and esten's UI merges are
  treated the same. `INITIAL_COMMIT`, `WIKI` and `CRUD_ACTIONS` are `never`, so nothing but merges is
  signed.
- **Instance-wide effect:** the setting is global. Merges in **every** repo on git.rye.ninja are now
  signed by this key. Nothing else changes: no repo is required to have signed commits, and users'
  own keys are not involved.
- **Secret:** 1Password `core-infra/gitea-signing-key` (`private-key`, `public-key`), read by the
  ExternalSecret `gitea-signing-key`, mounted `0400`. Not in git.
- **Public key** (no login needed): `https://git.rye.ninja/api/v1/signing-key.pub`
  (`curl -fsS https://git.rye.ninja/api/v1/signing-key.pub`).
- **Signer identity:** the key, not a name. Gitea writes the *merging user* as author and committer
  of the merge commit (for example `Scotty Agent`), and `SIGNING_NAME`/`SIGNING_EMAIL`
  (`Gitea Merge Signer <gitea-signer@rye.ninja>`) are the key's label (also the comment on the
  public key), not what the commit shows. Pin the **key** (SHA256 fingerprint
  `SHA256:9oU63ACedEpEQxf39uaFB24EE0RFKfV/ra6CLnCLTiI` for the first key) and use the wildcard principal
  `*`, because `git verify-commit` looks the principal up by the committer's email.
- **Verify:** put `* namespaces="git" <the public key line>` in an allowed-signers file and run
  `git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=allowed_signers verify-commit <merge-sha>`. It prints
  `Good "git" signature for * with ED25519 key SHA256:...`. A commit signed by any other key (for
  example the author's own) fails with `No principal matched`, and an unsigned one fails too.
- **Tested 2026-11-16** (scratch repo, non-admin user with Write, API merge): the merge commit carried an
  SSH signature that verified against only the published key; a commit signed by a different key and an
  unsigned commit did not verify.
- **Direct pushes to `main`** are not blocked by this change: signing only marks merges Gitea made. A
  pusher cannot forge the instance signature, so the applier's rule is "the merge commit verifies
  against the pinned key"; an unsigned or other-signed commit on `main` is not applied. Branch
  protection against direct pushes is a separate decision (access spec 8.3).

### Rotating the key

1. Generate a new key off-cluster: `ssh-keygen -t ed25519 -N "" -C gitea-signer@rye.ninja -f new-key`.
2. Edit the 1Password item `core-infra/gitea-signing-key`: put `new-key` in `private-key` and
   `new-key.pub` in `public-key`. Delete the local files.
3. Force the sync, then restart Gitea so it picks the files up at once:
   `kubectl -n gitea annotate externalsecret gitea-signing-key force-sync=$(date +%s) --overwrite`,
   `kubectl -n gitea rollout restart deploy/gitea`.
4. Confirm `curl -fsS https://git.rye.ninja/api/v1/signing-key.pub` shows the new key, then merge a
   throwaway PR and verify it against the new key.
5. **Tell Scotty before step 3**: open an issue on `esten/pcd-lab-manager`. The applier refuses
   merges signed by a key it doesn't have pinned, so the pinned key must be updated first or
   at the same time.
6. The old public key keeps verifying the merges it signed. Keep it in the allowed-signers list for
   as long as older commits need re-verifying (the applier acts on new commits only, so one
   release cycle is enough); list it under `TRUSTED_SSH_KEYS` in `[repository.signing]` if the
   Gitea UI should keep showing those commits as verified.

## Actions runners

`applications/gitea-runner` (namespace `gitea-runner`): **ephemeral** runners. A KEDA `ScaledJob`
creates one pod per queued Actions job (max 4 at once); each pod is a `gitea/runner` container plus a
**rootless** `docker:dind-rootless` native sidecar sharing a Unix socket (`/run/user/1000/docker.sock`).
The runner registers with `GITEA_RUNNER_EPHEMERAL`, takes exactly one job, Gitea deletes the
registration, and the pod exits. Nothing persists between jobs (workspace, image layers and build cache
are emptyDirs), so no job can break because of what another left behind. Runners are registered
instance-wide (any repo on git.rye.ninja can use them). Idle cost is zero; every job pays the pod start
and the image pull (~3 min for the runner image) until a pull-through registry (Harbor) exists.
KEDA counts jobs with `GET /api/v1/admin/actions/jobs?status=queued` using the token in 1Password
(`core-infra/gitea-runner-scaler`, Gitea token `keda-runner-scaler`, scope `read:admin`, owner
`gitea_admin`); `activeDeadlineSeconds` (3 h) removes a runner that never gets a job. Workflow labels: `ubuntu-latest`, `ubuntu-24.04`,
`ubuntu-22.04` (images from `docker.gitea.com/runner-images`, pulled through Harbor's `gitea` proxy-cache project: `harbor.rye.ninja/gitea/runner-images:<tag>`, `docs/runbooks/harbor.md`).

Add `runs-on: ubuntu-slim` for jobs that need only node, git, curl and tar (lint, release scripts, Go builds without cgo): the image is 132 MB compressed instead of 569 MB, which cuts a cold pull from about 160 s to about 60 s. It has no gcc/make, python, docker CLI, jq/yq or unzip, so Rust, Docker image builds and anything that compiles stay on `ubuntu-latest`. Layer unpacking (about 1 core, gzip) dominates the pull, not the network; zstd-recompressed layers saved only about 45 s on `ubuntu-latest` and would need a conversion job, so they are not used (measured 2026-11-15).

`runs-on: ubuntu-slim-py` is ubuntu-slim plus python3 (3.13) and make, for jobs that need only those. It is our own image (`applications/gitea-runner/images/ubuntu-slim-py/Dockerfile`) in the plain Harbor project `ci` (proxy-cache projects reject pushes), pinned by digest in `config.yaml`. The base is pinned by digest too and runs as root. To update it:

```sh
docker pull --platform linux/amd64 harbor.rye.ninja/gitea/runner-images:ubuntu-latest-slim   # new base digest -> Dockerfile FROM
docker build --builder default --platform linux/amd64 -t harbor.rye.ninja/ci/runner-images:ubuntu-slim-py3-make applications/gitea-runner/images/ubuntu-slim-py
docker push harbor.rye.ninja/ci/runner-images:ubuntu-slim-py3-make   # new digest -> label in config.yaml
```

`robot$runner-pull` needs pull on `ci` (set by `harbor-bootstrap`; it resets the robot's permissions, so keep `ci` in `OWN_PROJECTS` in `bootstrap.py`).


- **Where they run:** only on the tainted node pool `pool=rootless-test` (nodeSelector and toleration
  in the ScaledJob pod template), a single worker defined in `pcd-ce-deploy/tofu-pcd-talos-cluster/rootless_test_node.tf`
  (`rootless_test_node_enabled`, 80 GiB root disk). Talos disables user namespaces
  (`user.max_user_namespaces=0`); that node raises it to 11255, so the exposure stays off the other
  workers. If the node is gone the runners stay Pending and jobs queue.
- **Isolation:** not privileged, no added capabilities except `SETUID`/`SETGID` (for the
  `newuidmap`/`newgidmap` helpers), Unconfined seccomp/AppArmor, and `hostUsers: false` so root in the
  pod is an unprivileged UID on the node. `procMount: Unmasked` (needed because rootless dockerd writes
  `/proc/sys` in its own network namespace) is only allowed with `hostUsers: false`. The namespace is
  labelled Pod Security `privileged` for this. `container.privileged` is off and `valid_volumes` is
  empty in the runner config. Image layers live in an emptyDir (30 Gi limit) and go with the pod.
- **Actions cache:** one shared `gitea-runner cache-server` (`gitea-runner-cache` Deployment, 20 Gi PVC,
  Service on 8088) serves `actions/cache` for all ephemeral runners. Each runner's own embedded cache
  endpoint forwards to it (`cache.external_server`), so entries survive the pod. The shared secret
  (`core-infra/gitea-runner-cache`, field `secret`) is substituted into a per-pod copy of the runner
  config at start; each job's token is registered with the server, so a job only reaches its own repo's
  entries. **Jobs reach the runner's endpoint by name, not address:** `cache.host: runner-cache.internal`,
  mapped to the pod IP by `container.options: --add-host=runner-cache.internal:$POD_IP` at start. Node's
  HTTP client cannot dial the `http://[ipv6]:port` URL the runner would otherwise hand out
  (`getaddrinfo ENOTFOUND [fd00:...]`, still true on 6.0.0). The server itself is given its Service DNS
  name as `-s`, because it embeds that host in the download URLs it returns. After a runner major
  upgrade clear `/cache` (`bolt.db`, `cache/`) if the new server misbehaves; entries are disposable.
- **Action mirrors:** `uses: owner/repo@ref` is cloned by the runner container, from github.com by default
  (minutes per job over NAT64, and again for every ephemeral pod). `runner.github_mirror` rewrites
  `https://github.com` to the in-cluster Gitea, which holds public **pull mirrors** (8 h interval, all tags)
  of the actions in use: `actions/{checkout,cache,upload-artifact,download-artifact,setup-go,setup-python}`,
  `docker/{setup-buildx-action,build-push-action,login-action,metadata-action,setup-qemu-action}`,
  `dtolnay/rust-toolchain`, `Swatinem/rust-cache`, `golangci/golangci-lint-action`,
  `goreleaser/goreleaser-action`, `azure/setup-helm`, `helm/{chart-testing-action,chart-releaser-action}`,
  `pypa/gh-action-pypi-publish`, `astral-sh/setup-uv`. The mirrors live in Gitea (one public org per
  owner), not in git. **An action that is not mirrored fails to resolve.** To add one, create the org if
  needed and migrate the repo as a pull mirror (New Migration -> GitHub, "This repository will be a mirror",
  or `POST /api/v1/repos/migrate` with `mirror: true`). Docker-based actions (for example
  `pypa/gh-action-pypi-publish`) also pull their image at run time. `actions/upload-artifact` and
  `download-artifact` v4 do not work on Gitea; use v3 (the tags are mirrored).
- **Extra pieces rootless needs:**
  - `devic.es/tun`: slirp4netns needs `/dev/net/tun`. The `generic-device-plugin` DaemonSet
    (`resources/device-plugin.daemonset.yaml`, privileged, pool only) advertises it, and the docker
    container requests one.
  - `/etc/subuid` and `/etc/subgid` come from the ConfigMap `gitea-runner-subid`
    (`rootless:10000:50000`): a pod user namespace has 65536 IDs, so the image's `100000:65536` does not fit.
  - The emptyDir for Docker's data is mounted at `~/.local/share`, not `~/.local/share/docker`, because
    dockerd chmods its data dir and the volume root is not owned by UID 1000.
- **IPv6 / NAT64:** nodes are IPv6-only, so job containers need IPv6. dockerd runs with
  `--ipv6 --ip6tables` and rootlesskit with `--ipv6` (slirp4netns). slirp4netns gives the daemon's
  namespace an IPv6 address but no default route, so the sidecar adds `default via fd00::2 dev tap0`
  through `nsenter` after start and re-asserts it every 30 s. The default bridge (`fd00:d0c:a::/64`) and
  the `gitea-actions` network (`fd00:d0c:b::/64`, set as `container.network`) are dual-stack and masquerade.
  Hosts that only have an A record resolve through DNS64 to `64:ff9b::/96` and work; IPv4 *literals* do
  not, because the pod has no IPv4 route. NAT64 is a hard dependency: if `nat64-01` is down, image pulls
  from IPv4-only registries fail (see `nat64-appliance-rebuild.md`).
- **Registration:** the token comes from 1Password (`core-infra/gitea-runner-registration`, field
  `token`) through ESO. Generate it with `kubectl -n gitea exec deploy/gitea -c gitea -- gitea actions generate-runner-token`.
  Every pod registers with it; ephemeral registrations are removed by Gitea after the job. A pod killed
  mid-job can leave an offline runner behind (Site Administration -> Actions -> Runners).
- **Network:** the runner and the jobs talk to Gitea at `http://gitea-http.gitea.svc.cluster.local:3000`
  (act_runner passes its instance URL to jobs as the server URL, so `actions/checkout` fetches from it).
  Pods cannot reach the Gateway VIP `git.rye.ninja` (the known pod-to-own-VIP hairpin), and nothing
  needs it. Egress is DNS, Gitea on 3000, and TCP 80/443 to the internet (including NAT64) but not to
  the cluster ULAs or the site's delegated GUA `/60` (the `/60` changes on re-delegation, see
  `gua-prefix-renumber.md`). Nothing may connect to a runner pod (the daemon's TCP 2375 is published
  inside the pod network, so the policy's empty ingress matters).
- **DNS in jobs:** dockerd runs with `--dns=fd00::3` (slirp4netns' IPv6 forwarder). By default Docker's
  embedded resolver also lists `10.0.2.3` first, which cannot reach the IPv6-only pod resolver, so every
  lookup waited ~5 s and some failed.
- **Verified (2026-11-13/14)** with the private repo `gitea_admin/actions-smoke`: a workflow on
  `ubuntu-latest` (`actions/checkout@v4`, `curl` to an IPv4-only host through NAT64 (github.com, ghcr.io), a
  native-IPv6 host and an IPv6-only host, `docker version` and `docker build` inside a job) and a cache
  workflow (`actions/cache@v4` saves in one pod and restores, `cache-hit=true`, in a different pod). On the
  ephemeral runners: KEDA creates the pod, the runner registers, runs and deregisters, the Job completes
  (the dockerd native sidecar stops on its own), and the runner list in Gitea is empty afterwards.
- **Pod lifecycle details:**
  - The dockerd sidecar is a native sidecar (`initContainers` with `restartPolicy: Always`) with a startup
    probe, so the runner container starts once, after the daemon and the `gitea-actions` network are ready.
  - KEDA can start a second pod while the first is still claiming a queued job. Runner pods exit cleanly
    after 5 minutes without a task (the wrapper greps the runner log for `task started`; change it if a
    runner upgrade changes that message, or it will kill running jobs at 5 minutes).
  - The CronJob `gitea-runner-cleaner` (every 10 minutes, `core-infra/gitea-runner-cleaner`, Gitea token
    scope `write:admin`) deletes offline ephemeral runner records that a killed pod leaves behind.
- **Runner version:** `gitea/runner` 6.0.0 (needs Gitea >= 1.26.2; we run 1.27). act_runner 0.6.1 fetched
  `uses:` actions with go-git: about 4 minutes per action from the in-cluster mirror, and even a no-op
  re-fetch into an existing clone took 2 minutes (measured with go-git 5.16 in-cluster; native git does the
  same clone in 26 s, a depth-1 clone in 1 s). So persisting the action cache could not have helped, and NFS
  cannot be mounted into `hostUsers: false` pods anyway (`MOUNT_ATTR_IDMAP: invalid argument`). 6.0.0
  downloads actions as archives (`Prepare all required actions` takes about 2 s) and shallow-clones the
  rest. Rollback: revert the upgrade PR (images and the wrapper's log match).
- **Known costs:** every job pulls `docker.gitea.com/runner-images:ubuntu-latest` (~3 min) until a
  pull-through registry (Harbor) exists.
- **If jobs stall or pulls fail,** check NAT64 first (`nat64-appliance-rebuild.md`; Healthchecks
  `nat64-wkp`), then `kubectl -n gitea-runner get pods` and the node `talos-rootless-test-1`. Queued job but no pod: `kubectl -n gitea-runner get scaledjob,triggerauthentication` and
  the keda-operator logs (the scaler token or the Gitea ingress rule for the `keda` namespace).

## Mirrors and migrations from GitHub

The nodes are IPv6-only, so github.com is reached through DNS64/NAT64 (`64:ff9b::/96`).
Two settings make that work, and both are needed:

- `migrations.ALLOWED_DOMAINS` (`applications/gitea/base/values.yaml`) is a hostname
  allow-list: github.com, `*.github.com`, `*.githubusercontent.com`. Gitea's default
  `external` rule rejects `64:ff9b::/96` as a reserved range ("You cannot import from
  disallowed hosts"). To mirror from another host, add it here.
- The `gitea` NetworkPolicy allows egress TCP 443 to `64:ff9b::/96`. Without it the
  clone fails with `dial tcp [64:ff9b::...]:443: i/o timeout` (the policy drops it).

Private repos need a token the form can use: paste the token value, not a 1Password
`op://` reference. A classic PAT needs the `repo` scope (and SSO authorization if the
org enforces it); a fine-grained token is scoped to one owner, so for an org's private
repo its resource owner must be that org. GitHub answers 404 for a repo the token
cannot see. A failed migration leaves a broken repository record; delete it before retrying.

## Database TLS

cert-manager chain in the `gitea` namespace: `gitea-db-selfsigned` Issuer ->
`gitea-db-ca` Certificate (10 y) -> `gitea-db-ca` Issuer -> `gitea-db-server-tls`
Certificate (90 d, renewed 30 d early, CNPG reloads it via the `cnpg.io/reload` label).
Approver-policy needs the `gitea-db-ca` / `gitea-db-server` CertificateRequestPolicies
and the `cert-manager-policy:gitea-db` grant. Gitea connects with
`SSL_MODE=verify-full` and trusts the CA through `PGSSLROOTCERT`
(`/etc/gitea-db-ca/ca.crt`, only `ca.crt` of the Secret is mounted).

## Repository storage (NFS)

Repositories live on the NAS dataset `flash-pool/gitea-repos` (50 GiB refquota),
exported over NFSv4 as `nfs.nas.rye.ninja:/mnt/flash-pool/gitea-repos` and mounted
at `/repos` (`repository.ROOT`; not under `/data`, because kubelet would create the nested mountpoint as root in the Cinder volume) through the static PV/PVC `gitea-repos`
(`applications/gitea/base/resources/repos.pv.yaml`, `ReadWriteMany`, mount options
`nfsvers=4.1,hard,noatime`). `/data` (app.ini, queue, attachments) stays on the
20 Gi Cinder volume. The dataset, the NAS user/group `gitea` (UID/GID 3004), the
export (every client mapped to that user, limited to the VLAN 1179 node network (bgp-net))
and the snapshot tasks are provisioned by `pcd-ce-deploy/tofu-truenas/gitea.tf`.

- **Snapshots:** hourly (kept 2 days) and daily at 23:15 America/Chicago (kept 30
  days), which is after gitea-db's 04:00 UTC backup in both CST and CDT. Restore a
  repository by cloning from `.zfs/snapshot/<name>` on the dataset.
- **Capacity check:** the CronJob `gitea-repos-capacity` runs hourly, reads the
  volume's size and usage, and pings the Healthchecks check on `/fail` at 75% or
  more, otherwise success. It also fails if the reported size exceeds the expected
  50 GiB (quota not applied). Check `gitea-repos-capacity` (period 1 hour, grace 30
  minutes); its ping URL is in 1Password `core-infra/healthchecks-ping-gitea-repos`,
  field `capacity`. Resizing means changing `var.gitea_repos_quota_gib`, the PV
  `capacity` and the CronJob's `EXPECTED_SIZE_GIB` together.
- **Snapshot check:** the same CronJob lists `/repos/.zfs/snapshot` (the NAS exports
  the snapshot directory over NFS) and pings check `gitea-repos-snapshots` (period 1
  hour, grace 30 minutes, URL in field `snapshots` of the same 1Password item) while
  the newest snapshot is under 26 hours old, `/fail` when older or when none is
  listed. Only the daily snapshot is guaranteed: its task has `allow_empty = true`,
  while the hourly one is skipped on an idle dataset.
- **NAS unreachable:** `hard` mounts block I/O instead of erroring, so Gitea hangs
  until the NAS returns, and the capacity job's pod sits in ContainerCreating (the
  silent check alerts on its own).

## Backup and restore

Database backups are watched by `cnpg-backup-watcher` (check `cnpg-backup-gitea-db`, daily; URL in
1Password `core-infra/healthchecks-ping-cnpg-backups`, field `gitea-db`): it fails when the latest
backup is older than 26 hours or WAL archiving is unhealthy. Restore: same procedure as grafana-db, see `keycloak-realm-restore.md` and
`grafana-db.md`, substituting `gitea-db`, `gitea-db-barman` and the `gitea`
namespace. Repositories: ZFS snapshots above (same NAS as the data, so not
off-site).

## Not done yet

- No restore-operator Role / SeaweedFS operator role (grafana-db has one).
- No off-site copy of the repositories or the `/data` volume.
- Not applied yet: the tofu in pcd-ce-deploy, and the node-to-NAS NFS path over
  IPv6 (UniFi firewall between VLAN 1179 and the NAS) is unverified.
