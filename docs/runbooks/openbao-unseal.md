# Runbook: OpenBao unseal ceremony (`controlplane`)

OpenBao (`applications/openbao`) runs HA with a Shamir seal on a
CNPG/PostgreSQL storage backend (`applications/openbao-db`), not
integrated Raft — see [[m3-step-tracker]] for why. That backend choice
changes how HA is coordinated (a Postgres lock table instead of Raft
peer discovery), but it does **not** change seal mechanics: seal state
is still per-pod-process, not shared via storage. Every replica that
boots sealed — the very first cold init, or any later pod restart —
needs the same threshold of unseal key shares applied to it
individually before it becomes Ready.

The StatefulSet uses `OrderedReady`, and the readiness probe is
`bao status -tls-skip-verify` (exits non-zero while sealed). So
`openbao-1` is not even created until `openbao-0` is unsealed, and
`openbao-2` not until `openbao-1` is. Expect to run the unseal step
three times per full cold start, once per pod, as each one appears.

Storage type reads `postgresql` and HA reads `true` in `bao status`
once initialized — if either of those looks wrong, stop and check
`applications/openbao/base/values.yaml`'s `server.ha.config` before
proceeding, since something has drifted from the intended design.

## When to use

- First-ever initialization of a fresh OpenBao deployment (`Initialized:
  false`).
- After any full cold start of the `controlplane` cluster (see
  `control-plane-cold-start.md` step 7) — OpenBao always boots sealed.
- After any individual `openbao-N` pod restart (image bump, node
  drain, `OnDelete` StatefulSet rollout) — that one pod boots sealed
  even though its peers stay unsealed and serving.

## Procedure

All commands assume:

```sh
export KUBECONFIG=~/.kube/homelab/controlplane.yaml
```

### 1. Initialize — once only, against whichever pod is up first

Skip this step entirely if `bao status` already shows
`Initialized: true` (i.e. this is a post-restart unseal, not a
first-ever cold init) — go straight to step 4 with the existing key
shares.

```sh
kubectl exec -n openbao openbao-0 -c openbao -- \
  bao operator init -tls-skip-verify -key-shares=5 -key-threshold=3 -format=json \
  > /tmp/openbao-init.json
```

`-key-shares=5 -key-threshold=3` is the Shamir default (any 3 of 5
shares unseal). Since step 3 below SOPS-encrypts every share into one
file together, the share/threshold split doesn't add protection
against a compromised SOPS file — it only matters if individual shares
are ever handed to different people. Lower it (e.g. `3`/`2`) if that
added complexity isn't buying anything in your operating model.

This is the one moment the unseal keys and initial root token exist in
plaintext. Treat `/tmp/openbao-init.json` as live secret material from
the instant it's created.

### 2. Read the keys and root token out of the temp file

```sh
python3 -m json.tool /tmp/openbao-init.json
```

Fields of interest: `unseal_keys_b64` (array) and `root_token`.

### 3. Preserve them, then destroy the plaintext

Mirrors how `step-ca-root.sops.yaml` handles offline root key material:
whole-file SOPS encryption, never applied to any cluster, never
referenced as a Kustomize resource. Add a dedicated rule to
`clusters/controlplane/.sops.yaml` (next to the `step-ca-root` /
`talos-secrets` whole-file rules):

```yaml
  - path_regex: secrets/openbao-unseal\.sops\.yaml$
    age: >-
      age16p6p30le4wlka4gpvjafnr87sunrynwseegl7gvf234qk53hv49q4tl0e7
```

then write `clusters/controlplane/secrets/openbao-unseal.sops.yaml`
with the key shares and root token and run `sops -e -i` on it from
inside `clusters/controlplane/` (so the rule above matches). Commit it
through the normal branch → PR → merge flow — it's inert reference
material, so no render/lint/dry-run gate applies to it beyond normal
YAML sanity.

Once committed, destroy `/tmp/openbao-init.json`
(`shred -u /tmp/openbao-init.json` or equivalent) — don't leave root
token plaintext sitting on disk after it's safely encrypted in the
repo.

### 4. Unseal `openbao-0`

Apply *threshold*-many distinct shares (3 of the 5, if defaults were
used):

```sh
kubectl exec -n openbao openbao-0 -c openbao -- bao operator unseal -tls-skip-verify <share-1>
kubectl exec -n openbao openbao-0 -c openbao -- bao operator unseal -tls-skip-verify <share-2>
kubectl exec -n openbao openbao-0 -c openbao -- bao operator unseal -tls-skip-verify <share-3>
```

Check progress between calls:

```sh
kubectl exec -n openbao openbao-0 -c openbao -- bao status -tls-skip-verify
```

`Unseal Progress` climbs toward the threshold; `Sealed` flips to
`false` on the last share.

### 5. Wait for `openbao-1`, unseal it the same way

```sh
kubectl get pods -n openbao -w   # Ctrl-C once openbao-1 appears
kubectl exec -n openbao openbao-1 -c openbao -- bao operator unseal -tls-skip-verify <share-1>
kubectl exec -n openbao openbao-1 -c openbao -- bao operator unseal -tls-skip-verify <share-2>
kubectl exec -n openbao openbao-1 -c openbao -- bao operator unseal -tls-skip-verify <share-3>
```

### 6. Same for `openbao-2` once it appears

### 7. Verify HA

```sh
kubectl exec -n openbao openbao-0 -c openbao -- bao status -tls-skip-verify
kubectl exec -n openbao openbao-1 -c openbao -- bao status -tls-skip-verify
kubectl exec -n openbao openbao-2 -c openbao -- bao status -tls-skip-verify
kubectl get pods -n openbao   # expect 3/3 Running, 1/1 Ready each
```

All three should report `Sealed: false`; exactly one reports
`HA Mode: active`, the other two `standby`.

### 8. Enable the audit log (first-ever init only)

Run against whichever pod is currently `active` (check via `bao status`
above):

```sh
kubectl exec -n openbao openbao-0 -c openbao -- bao login -tls-skip-verify <root-token>
kubectl exec -n openbao openbao-0 -c openbao -- bao audit enable -tls-skip-verify file file_path=stdout
```

Confirm entries land in `kubectl logs -n openbao openbao-0 -c openbao`
on subsequent requests.

## Post-ceremony hygiene

- The root token from step 1 is a full-access credential. Treat the
  SOPS file as break-glass only — day-to-day admin access should go
  through the `openbao-admin` Keycloak group once step 6 (ESO wiring)
  and the Keycloak/Pinniped stack (steps 9–10) are live, not the root
  token.
- Root token rotation/revocation policy is deferred to M11 hardening
  per the M3 design's A4 scope note — not addressed by this runbook.
- `openbao-server-test` (the Helm test-hook Pod) may land in `Error`
  status across an unseal cycle if it happens to run against a
  still-sealed pod; that's expected noise, not a signal — see
  [[m3-step-tracker]]. `kubectl delete pod openbao-server-test -n
  openbao` is safe any time.

## Ceremony log

| Date | Type (init / restart) | Pods unsealed | Result |
|---|---|---|---|
