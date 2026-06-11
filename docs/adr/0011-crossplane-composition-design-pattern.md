# 11. Crossplane Composition Design Pattern for Multi-Cloud Orchestration

Date: 2026-06-10

## Status

Accepted

## Context

The platform manages infrastructure across multiple cloud providers (AWS, Cloudflare,
GitHub, and others). Consumers of the platform — workload cluster operators and
application teams — should not need to understand the details of each provider API
to request infrastructure. They should interact with a single, consistent claim API
that hides provider-specific complexity.

We need a pattern for defining these abstractions that:

- Keeps provider-specific resources under Crossplane's reconciliation loop
- Derives all provider-specific inputs from a small set of consumer-facing inputs
  so that claims are simple to write
- Surfaces the outputs that downstream automation needs (ARNs, zone IDs, trust
  domains) in a discoverable, consistent location
- Handles multiple providers in a single claim lifecycle so that related resources
  are provisioned and deprovisioned atomically

## Decision

We use Crossplane Composite Resource Definitions (XRDs) and Compositions as the
abstraction layer. The canonical example is
`XDelegatedHostedZoneAWS` in
`applications/crossplane-resources/delegated-hosted-zone-aws/`.

### When to create a new XRD

Create a new XRD when:
- Multiple consumers will request the same type of infrastructure
- The infrastructure spans multiple Crossplane providers or requires
  non-trivial input derivation
- Lifecycle coupling is required (all resources must be created and destroyed
  as a unit)

Use a provider managed resource directly (without a composition) when:
- The resource is a one-off platform infrastructure component (not a consumer
  API)
- No input derivation or multi-provider orchestration is needed

### Composition function pipeline

Every composition uses a three-stage function pipeline:

1. **`function-environment-configs`** — injects platform-level defaults
   (e.g., shared trust anchor ARN, default zone name) from a Crossplane
   `EnvironmentConfig` into the composition context. This allows platform
   operators to set defaults once without requiring each claim to specify them.

2. **`function-go-templating`** — derives provider-specific resource specs
   from claim inputs and environment context. All resource names, labels,
   ARN templates, IAM policy documents, and cross-resource references are
   rendered here. This is the main composition logic.

3. **`function-auto-ready`** — marks the composite resource Ready=True when
   all composed resources are Ready. Without this, readiness must be managed
   manually in the `go-templating` step.

### Status outputs

Every composition must surface the values downstream automation needs in
`status` fields on the composite resource. For `XDelegatedHostedZoneAWS`:

```yaml
status:
  iamRoleArn: arn:aws:iam::123456789:role/crossplane-<subdomain>
  nameServers:
    - ns-1.awsdns-01.org
    - ns-2.awsdns-02.co.uk
  profileArn: arn:aws:rolesanywhere::123456789:profile/<uuid>
  trustAnchorArn: arn:aws:rolesanywhere::123456789:trust-anchor/<uuid>
  trustDomain: <subdomain>.<zoneName>
  zoneId: Z0123456789ABCDEFGHIJ
```

Downstream resources (ExternalDNS, cert-manager overlays) consume these values
via cross-resource references rather than requiring operators to look up and
copy ARNs manually.

### Input minimization

Composition inputs should derive as much as possible from the claim's primary
identifiers plus platform defaults. For `XDelegatedHostedZoneAWS`, the only
required input is `spec.subdomain`. All other values (zone name, trust anchor
ARN, provider configs) default from `EnvironmentConfig` and can be overridden
per-claim when needed.

## Consequences

- Every new XRD requires: an XRD YAML, a Composition YAML, and a ClusterRole
  granting claim access. Follow the structure in
  `applications/crossplane-resources/delegated-hosted-zone-aws/` as the
  reference implementation.
- Composition debugging requires the Crossplane CLI (`crossplane beta trace
  <claim-kind> <name>`) to inspect composed resource status.
- Environment defaults in `EnvironmentConfig` are cluster-wide. Changes to
  defaults affect all claims that rely on them. Test in a non-production
  environment before promoting.
- Status fields are only populated after the composition fully reconciles
  (all composed resources Ready). Downstream automation that reads status
  fields must handle the case where they are not yet set.

## References

- [ADR-7: Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere](0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md)
- [ADR-12: Least-Privilege IAM Role Isolation for Crossplane Providers](0012-least-privilege-iam-role-isolation-for-crossplane-providers.md)
- [Crossplane: Composite Resource Definitions](https://docs.crossplane.io/latest/concepts/composite-resource-definitions/)
- [Crossplane: Compositions](https://docs.crossplane.io/latest/concepts/compositions/)
- [function-go-templating](https://github.com/crossplane-contrib/function-go-templating)
- [Reference implementation: XDelegatedHostedZoneAWS](../../applications/crossplane-resources/delegated-hosted-zone-aws/)
