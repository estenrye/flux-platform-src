---
name: calico-operator-digest-pin
description: applications/calico/base pins the tigera-operator image by digest; bumping only the chart version does not upgrade Calico, so bump chart and digest together
metadata:
  type: project
---

`applications/calico/base/kustomization.yaml` has an `images:` override pinning `quay.io/tigera/operator` to a digest. The **operator binary decides which Calico version is deployed**, so changing only `helmCharts[0].version` leaves the old Calico running (the rendered diff shows just an env var changing, and the image reference stays the same).

**How to apply** (done for 3.32.2 and 3.33.0):
1. Set the chart `version`. Charts are git-ignored under `charts/` and fetched at render.
2. Read `tigeraOperator.version` from the fetched chart's `values.yaml`.
3. Look up its digest: `curl "https://quay.io/api/v1/repository/tigera/operator/tag/?specificTag=<tag>&onlyActiveTags=true"` and use `.tags[0].manifest_digest` as the `images:` digest.
4. Diff `kustomize build --enable-helm applications/calico/base` before/after: expect the operator version env value and the image to change (3.33.0 also adds operator RBAC rules and `-zap-devel=false`), and nothing else.

Mappings seen: chart v3.32.1 -> operator v1.42.3, v3.32.2 -> v1.42.6, v3.33.0 -> v1.44.0.

`.bin/install-calicoctl.sh` reads the Calico version from this same kustomization, so the local `calicoctl` follows automatically (a client newer than the cluster, as with a brew install, is a mismatch risk). From 3.33 most sub-components ship in one `quay.io/calico/calico` image; `kube-controllers`, `typha`, `cni` are no longer separate images.

The `controlplane` and `observability` Calico overlays are pinned independently (still v3.32.1, no digest pin). Upgrade notes: [[calico-33-gateway-namespace-mode]].
