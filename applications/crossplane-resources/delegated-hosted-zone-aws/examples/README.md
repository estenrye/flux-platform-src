# Examples

This directory contains example usage of the DelegatedHostedZone composite resource.

## Prerequisites

Before using this composite resource, ensure you have:

1. Crossplane installed in your cluster
2. AWS Provider for Crossplane configured with appropriate credentials
3. Cloudflare Provider for Crossplane configured with appropriate credentials  
4. ProviderConfig resources created for both AWS and Cloudflare providers

## Usage

To create a delegated hosted zone:

```bash
kubectl apply -f example-claim.yaml
```

This will:
1. Create an AWS Route53 hosted zone for `crossplane.rye.ninja`
2. Wait for the zone to be provisioned and retrieve its nameservers
3. Create NS records in Cloudflare pointing the subdomain `crossplane` to the AWS nameservers

## Monitoring

Check the status of your composite resource:

```bash
kubectl get delegatedhostedzone crossplane-rye-ninja -n crossplane-system
kubectl describe delegatedhostedzone crossplane-rye-ninja -n crossplane-system
```

## Troubleshooting

If the resource is not becoming ready:

1. Check the status of the underlying managed resources:
```bash
kubectl get zones.route53.aws.m.upbound.io
kubectl get records.dns.upjet-cloudflare.m.upbound.io
```

2. Check provider logs for any authentication or permission issues:
```bash
kubectl logs -n crossplane-system -l app=crossplane
```