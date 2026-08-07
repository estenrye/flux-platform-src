---
name: bootstrap-cluster-generic-chain
description: How to bootstrap a real Flux instance onto a new non-controlplane cluster using the existing generic .bin/bootstrap-cluster-*.sh chain, and three bugs it had never surfaced before observability
metadata:
  type: reference
---

This repo has a generic, `CLUSTER=`-parameterized chain for giving any new
cluster its own Flux instance, distinct from `controlplane`'s own one-off
manual bootstrap scripts (which exist only because Flux/ESO didn't exist yet
when controlplane itself was bootstrapped). It had never been run end-to-end
before `observability` (2026-08-07), which surfaced three real bugs:

1. `.bin/bootstrap-cluster-sops-key.sh` templated stale, version-suffixed app
   paths (`flux/v2.7.5`, `external-secrets-operator/v2.4.1`,
   `priority-classes/v0.0.1`, `prometheus-operator-crds/v28.0.1`) that don't
   exist -- the real dirs are `applications/*/base` (or, for
   `priority-classes`, no version dir at all). Fixed to match
   `clusters/controlplane/kustomization.yaml`'s own working resource list.
2. `.gitignore` only excluded `clusters/controlplane/.sops.age-key` and
   `clusters/crossplane/.sops.age-key` -- any other cluster's private SOPS
   age key would get committed in plaintext by
   `bootstrap-cluster-sops-key.sh`'s own `git add`. Caught before the branch
   was ever pushed (amended the local-only commit). Fixed with a blanket
   `clusters/*/.sops.age-key` rule.
3. `images/docker/talos-cluster-bootstrap/bootstrap.sh` never wired up
   `cluster.allowSchedulingOnControlPlanes`, despite the XRD's own doc
   comment already describing 0-worker clusters relying on it. A 0-worker
   cluster's control-plane nodes keep the default `NoSchedule` taint, so
   nothing but Calico's `hostNetwork` DaemonSet can ever schedule -- Flux,
   ESO, everything else sits `Pending` forever. Now set automatically when
   `NODES_JSON` has no `worker` role. For an *already-provisioned* cluster
   hitting this, it's live-patchable without a reboot:
   `talosctl patch mc -n <node> -e <node> -p '[{"op":"add","path":"/cluster/allowSchedulingOnControlPlanes","value":true}]'`
   -- but the *client* `talosctl` must match the cluster's Talos version
   (this repo's `.venv/bin/talosctl` is pinned correctly; a stray
   system-installed `talosctl` at a much older version produces a cryptic
   `cannot unmarshal string into Go value of type jsonpatch.partialDoc`
   error that looks like a config problem but is a client/server skew
   problem).

**The actual working order** (see `make bootstrap-cluster-*` targets):
catalog -> environment -> rendered-repo -> `bootstrap-cluster-sops-key.sh`
(do **not** also run `bootstrap-cluster-secret-store.sh` for a brand-new
cluster -- that script requires `.sops.yaml` to already exist and is only
for retrofitting ESO onto a cluster whose SOPS key predates it, e.g.
controlplane's own M2 step 9) -> add the cluster's CNI kustomize dir as the
*first* resource (Talos installs with `cni: none`) -> `make deploy-cluster`
(one-time direct `kubectl apply`, bypasses Flux/rendered-repo entirely,
tolerates the SOPS-encrypted secret failing with `.sops: field not declared
in schema` -- expected, Flux decrypts it later) -> `make
bootstrap-cluster-deploy-key` -> push/merge so CI renders the real content
into the rendered repo -> `flux reconcile source git
flux-platform-rendered`.

See [[remote-cluster-manifest-delivery]] for the CNI-delivery mechanism this
supersedes once a cluster has its own Flux instance.
