# 14. Workload Cluster Bootstrap and Lifecycle

Date: 2026-06-10

## Status

Accepted

## Context

The Crossplane control plane cluster (see ADR-3) manages infrastructure for
workload clusters, but workload clusters themselves need Flux installed and
configured to receive application manifests from the rendered repository.
Each workload cluster also requires:

- A unique SPIFFE trust domain for workload identity isolation (see ADR-16)
- Registration with the Crossplane control plane so that its infrastructure
  claims can be reconciled
- Network policies, priority classes, and other platform baseline components
  that must be present before application workloads are deployed

The bootstrap sequence is distinct from the control plane bootstrap (ADR-3)
because workload clusters do not run Crossplane — they consume platform
infrastructure provisioned by the control plane cluster.

## Decision

We bootstrap workload clusters using a defined sequence executed via scripts
in the `.bin/` directory. The sequence is:

### Phase 1: Cluster provisioning and initial deployment

Provision the Kubernetes cluster using the appropriate provider tooling
(e.g., `spotctl` for Rackspace Spot, `eksctl` for AWS EKS, `talosctl` for
Talos Linux). The cluster must be reachable via `kubectl` before proceeding.

Deploy the cluster configuration (Kustomize manifests) to establish platform
baseline components:

```bash
.bin/deploy-cluster.sh
```

This script:
- Uses `kustomize build` to render manifests from the cluster directory
- Applies them server-side to the cluster using `kubectl apply --server-side`
- Installs Flux via the `applications/flux/base/kustomization.yaml` resource,
  which references the official Flux v2 release manifest
- Retries with configurable timeout and interval until all resources are
  deployed successfully

At this point, the `flux-system` namespace is created and Flux controllers
are running.

### Phase 2: SOPS key delivery

Each cluster needs the age private key to decrypt SOPS-encrypted secrets
committed to the rendered repository. The `.bin/bootstrap-cluster-sops-key.sh`
script orchestrates this delivery:

```bash
.bin/bootstrap-cluster-sops-key.sh
```

This script:
1. Creates a 1Password vault named after the cluster to securely store secrets
2. Generates an age keypair and stores the private key in the vault
3. Grants vault access to specified users
4. Retrieves the age key from the vault and creates a Kubernetes secret:
   ```bash
   kubectl create secret generic sops-age \
     --namespace=flux-system \
     --from-file=age.agekey=/path/to/age.key
   ```

The secret must exist before Flux can reconcile any SOPS-encrypted manifest.

### Phase 3: Rendered repository bootstrap

Create or configure the rendered (machine-generated manifests) GitHub repository:

```bash
.bin/bootstrap-cluster-rendered-repo.sh
```

This script:
- Reads the cluster catalog to extract the GitHub repository slug
- Creates the private GitHub repository if it doesn't exist
- Initializes it with a README and auto-merge enabled

### Phase 4: Deploy key creation

Configure Flux to authenticate with the rendered repository:

```bash
.bin/bootstrap-cluster-deploy-key.sh
```

This script creates a Kubernetes secret containing an SSH deploy key, which
External Secrets Operator will use to provision a GitHub deploy key on the
rendered repository for Flux to use during reconciliation.

### Phase 5: SPIFFE trust domain configuration

Before cert-manager-spiffe-csi-driver is deployed, configure the cluster's
unique trust domain. See ADR-16 for requirements and the exact configuration
steps. The trust domain must match the `status.trustDomain` of the cluster's
`XDelegatedHostedZoneAWS` claim on the Crossplane control plane.

### Phase 6: Control plane registration

Create the `XDelegatedHostedZoneAWS` claim on the Crossplane control plane
cluster to provision the cluster's delegated DNS zone, IAM role, and Roles
Anywhere profile. This step requires the Crossplane control plane to be
healthy and the `csi-driver-spiffe-ca` trust anchor to be registered with
AWS IAM Roles Anywhere (see ADR-7 Phase 2).

### Decommissioning

The `.bin/teardown-cluster.sh` script orchestrates decommissioning in two
modes:

**Partial teardown** (re-bootstrap mode):
```bash
.bin/teardown-cluster.sh
```

This removes local cluster state to allow re-bootstrapping:
1. Deletes the deploy key from the rendered repository
2. Deletes the sops-age Kubernetes secret from the cluster
3. Removes local SOPS files (.sops.yaml, .sops.age-key)
4. Deletes the 1Password vault (includes stored secrets)
5. Removes the cluster directory from git

**Full teardown** (complete decommission):
```bash
.bin/teardown-cluster.sh --full
```

In addition to the partial teardown steps, also:
6. Deletes the GitHub Environment from the platform source repository
7. Permanently deletes the rendered repository
8. (Manual step) Delete the 1Password service account via the web UI
9. (Manual step) Delete the `XDelegatedHostedZoneAWS` claim from Crossplane

## Consequences

- Workload cluster bootstrap is a multi-step manual process. It cannot be
  fully automated yet because Flux bootstrap requires interactive credential
  handling and the SPIFFE trust domain must be configured before cert-manager
  deploys.
- The SOPS age key must be securely transferred to the cluster out-of-band.
  It must never be committed to any repository.
- A cluster that loses its SOPS secret will fail to reconcile SOPS-encrypted
  manifests until the secret is restored.
- Cluster lifecycle (provisioning and decommissioning) must be coordinated
  with the Crossplane control plane to avoid orphaned AWS resources.

## References

- [ADR-2: Bootstrapping a Flux-Enabled Kubernetes Cluster](0002-managing-a-consistent-development-environment.md)
- [ADR-3: Bootstrapping the Crossplane Controlplane Cluster](0003-bootstrapping-the-crossplane-controlplane-cluster.md)
- [ADR-7: Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere](0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md)
- [ADR-16: SPIFFE Trust Domain Configuration per Cluster](0016-spiffe-trust-domain-configuration-per-cluster.md)
- [FluxCD: Bootstrap](https://fluxcd.io/flux/installation/bootstrap/)
