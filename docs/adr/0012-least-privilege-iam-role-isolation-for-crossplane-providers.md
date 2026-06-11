# 12. Least-Privilege IAM Role Isolation for Crossplane Providers

Date: 2026-06-10

## Status

Accepted

## Context

Crossplane providers need cloud credentials to reconcile managed resources.
The platform uses multiple AWS providers (IAM, Route53, Roles Anywhere) that
each require different permission scopes. Using a single shared credential for
all providers would:

- Violate the principle of least privilege
- Increase the blast radius if a provider credential is compromised
- Make it difficult to audit which provider performed which action in CloudTrail

Each Crossplane provider uses a `ProviderConfig` that references a credential
source. Providers running with a shared service account and shared IAM role
cannot be distinguished in IAM policy conditions or audit logs.

## Decision

Each Crossplane provider gets its own isolated credential stack:

1. **A dedicated Kubernetes ServiceAccount** in the provider's runtime namespace
   (e.g., `crossplane-system`). This is configured via `DeploymentRuntimeConfig`.

2. **A dedicated IAM Role** scoped to the minimum permissions the provider
   needs. The role trust policy allows only the provider's ServiceAccount
   (via SPIFFE SVID + IAM Roles Anywhere) to assume it.

3. **A dedicated ProviderConfig** that references the IAM Role ARN and Roles
   Anywhere Profile ARN for that provider's credential stack.

### Current provider isolation

| Provider | ProviderConfig | IAM Role scope |
|----------|---------------|----------------|
| `provider-aws-route53` | `route53-dns-admin` | Route53 hosted zone management scoped to delegated zones |
| `provider-aws-iam` | `iam-admin` | IAM Role/Policy/Attachment management |
| `provider-aws-rolesanywhere` | `rolesanywhere-admin` | Roles Anywhere Profile management |

IAM and Roles Anywhere providers use a shared `platform-iam-rolesanywhere`
`EnvironmentConfig` to source their ProviderConfig references by default.
Per-composition overrides are available via `spec.iamProviderConfigRef` and
`spec.rolesAnywhereProviderConfigRef`.

### ABAC session tag enforcement

IAM role trust policies use `aws:PrincipalTag/x509SAN/URI` conditions to
restrict role assumption to a specific SPIFFE URI. This ensures that only the
intended provider's workload identity can assume the role, even if another
workload has a valid Roles Anywhere certificate.

Example trust policy condition:

```json
"Condition": {
  "StringEquals": {
    "aws:PrincipalTag/x509SAN/URI":
      "spiffe://<trustDomain>/ns/crossplane-system/sa/<provider-sa-name>"
  }
}
```

### Adding a new provider

1. Create a `DeploymentRuntimeConfig` in the provider's application directory
   specifying a new ServiceAccount name.
2. Bootstrap the IAM Role and Roles Anywhere Profile out-of-band (AWS CLI or
   Terraform) using the crossplane cluster's SPIFFE trust anchor certificate.
   See the bootstrap runbook in `docs/runbooks/`.
3. Create a `ProviderConfig` referencing the new IAM Role and Profile ARNs.
4. Reference the new `ProviderConfig` from composition steps that use this
   provider.

## Consequences

- Adding a new Crossplane provider requires an out-of-band bootstrap step
  to provision IAM credentials. This cannot be fully automated by Crossplane
  itself (bootstrapping problem: Crossplane needs credentials to provision
  the credentials it needs).
- The `OP_SERVICE_ACCOUNT_TOKEN` secret in 1Password must have access to the
  IAM Role ARNs so they can be injected into ProviderConfig resources via
  External Secrets Operator.
- Provider credential isolation means a bug in one provider cannot
  accidentally modify resources owned by another provider.

## References

- [ADR-5: Using cert-manager to issue SPIFFE X.509 SVID Certificates](0005-using-cert-manager-to-issue-spiffe-x-509-svid-certificates-for-iam-access-roles-anywhere.md)
- [ADR-7: Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere](0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md)
- [ADR-11: Crossplane Composition Design Pattern](0011-crossplane-composition-design-pattern.md)
- [AWS IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html)
- [Crossplane: DeploymentRuntimeConfig](https://docs.crossplane.io/latest/concepts/providers/#runtime-configuration)
