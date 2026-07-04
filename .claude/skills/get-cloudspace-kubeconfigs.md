---
name: get-cloudspace-kubeconfigs
description: Use when kubectl context is needed for a Rackspace Spot cluster and kubeconfigs may be missing or stale.
---

# Get Cloudspace Kubeconfigs

## How to fetch kubeconfigs

Run from the repo root:

    make get-cloudspace-kubeconfigs

This iterates every cluster under `clusters/*/catalog.yaml`, reads the
`rye.ninja/spot-org` and `rye.ninja/spot-cloudspace-name` annotations, and writes
kubeconfigs to `~/.kube/spot/<org>/<cloudspace-name>.yaml`.

Requires `spotctl` to be authenticated. If the command fails with an auth error, the
user needs to run `spotctl configure` first.

## Finding the right KUBECONFIG path for a cluster

Read the `rye.ninja/kubeconfig` annotation from the cluster's catalog:

    yq e '.metadata.annotations["rye.ninja/kubeconfig"]' clusters/<name>/catalog.yaml

Set KUBECONFIG to that path (expanding `~` to `$HOME`) before running kubectl or flux
commands against the cluster.
