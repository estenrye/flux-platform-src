# delegated-hosted-zone Composite Resource

## References

- [Crossplane Composite Resource Documentation](https://docs.crossplane.io/latest/composition/composite-resources/)
- [Crossplane Composite Resource Definition Documentation](https://docs.crossplane.io/latest/composition/composite-resource-definitions/)
- [Crossplane Compositions Documentation](https://docs.crossplane.io/latest/composition/compositions/)
- [Crossplane Composition Revisions Documentation](https://docs.crossplane.io/latest/composition/composition-revisions/)
- [Crossplane Environment Config Documentation](https://docs.crossplane.io/latest/composition/environment-configs/)

## Objective

This Composite Resource will provision a Delegated Hosted Zone in a supported
Public Cloud and create a Cloudflare NS Record delegating Name Resolution to
the created Zone.

## Design Decisions
- `apiextensions.crossplane.io/v1` is deprecated and is replaced by `apiextensions.crossplane.io/v2`.  For all composite resource definitions, we will use `apiextensions.crossplane.io/v2` as the apiVersion.
- This composite resource will focus only on DelegatedHostedZoneAWS that delivers a Route53 hosted zone as the target destination for the delegated hosted zone.
- Support for additional clouds may be added in the future.
  - This will be implemented by creating dedicated compositions for each supported cloud and a generic DelegatedHostedZone composite resource that references the appropriate composition based on the value of `targetCloud` in the claim.
  - The API specification of the claim will be shared across all supported clouds.

## API Specification

The Composite Resource should take in the following inputs:

### zoneId
Description:
  This is the Cloudflare Zone Id that will be used in the
  `Record.dns.upjet-cloudflare.m.upbound.io` resource to
  populate a record of type `NS` for each nameserver in
  the status fields of the delegated hosted zone.
Data Type: string
Required: yes

### zoneName
Description:
  This is the DNS Name of the Zone in Cloudflare the delegated hosted zone
  is delegated from.
Data Type: string
Required: yes

### subdomain
Description:
  This is the subdomain under the Cloudflare Zone being delegated to the delegated hosted zone.
Data Type: string
Required: yes

### ttl
Description:
  This is the ttl for the Cloudflare NS records for `${inputs.subdomain}.${inputs.zoneName}`
  The composite resource should default to a value of 1 for `automatic`
  Otherwise the Value must be between 60 and 86400, with the minimum reduced to 30 for enterprise zones.
Data Type: integer
Required: no

### delegatedZoneProviderConfigRef
FIELD: delegatedZoneProviderConfigRef <Object>

DESCRIPTION:
    ProviderConfigReference specifies how the provider that will be used to
    create, observe, update, and delete this managed resource should be
    configured.
    
FIELDS:
  kind  <string> -required-
    Kind of the referenced object.

  name  <string> -required-
    Name of the referenced object.

### cloudflareProviderConfigRef
FIELD: cloudflareProviderConfigRef <Object>

DESCRIPTION:
    ProviderConfigReference specifies how the provider that will be used to
    create, observe, update, and delete this managed resource should be
    configured.
    
FIELDS:
  kind  <string> -required-
    Kind of the referenced object.

  name  <string> -required-
    Name of the referenced object.

## Deployment Logic

The composite resource will provision a delegated hosted zone
in AWS Route53 using the AWS Crossplane provider. It will then interrogate the status
fields of that resource to determine the nameservers
for that delegated hosted zone and provision an NS Record in Cloudflare
for every nameserver in that list.

### Delegated Hosted Zone Resource Type

This composition uses the `Zone.route53.aws.m.upbound.io` resource type.

Below is a table describing the value mapping for the delegated hosted zone.

| Field in Zone | Value Source |
| --- | --- |
| `Zone.metadata.name` | `${inputs.subdomain.replace('.','-')}-${inputs.zoneName.replace('.','-')}` |
| `Zone.spec.forProvider.name` | `${inputs.subdomain}.${inputs.zoneName}` |
| `Zone.spec.forProvider.comment` | `Delgated Hosted Zone for ${inputs.subdomain}.${inputs.zoneName} from Cloudflare Zone ${inputs.zoneName}` |
| `Zone.spec.providerConfigRef` | `${inputs.delegatedZoneProviderConfigRef}` |


### Populating the NS records in Cloudflare

The NS Records are defined using a resource of type `Record.dns.upjet-cloudflare.m.upbound.io`

Below is a table describing the value mapping for each `ns,i` in `Zone.status.atProvider.nameServers`.

| Field in Record | Value Source |
| --- | --- |
| `Record.metadata.name`            | `ns${i}-${inputs.subdomain.replace('.','-')}-${inputs.zoneName.replace('.','-')}` |
| `Record.spec.forProvider.zoneId`  | `spec.zoneId` |
| `Record.spec.forProvider.type`    | `NS` |
| `Record.spec.forProvider.name`    | `${inputs.subdomain}` |
| `Record.spec.forProvider.comment` | `Delgated Hosted Zone NS-${i} for ${inputs.subdomain}.${inputs.zoneName} in aws` |
| `Record.spec.forProvider.ttl`     | `${inputs.ttl:-1}` |
| `Record.spec.forProvider.content` | `${ns}` |
| `Record.spec.providerConfigRef`   | `${inputs.cloudflareProviderConfigRef}` |


## Example Managed Resources

#### Input Resource

```yaml
metadata:
  name: crossplane-rye-ninja
  namespace: crossplane-system
  labels:
    rye.ninja/flux-src-repository: estenrye/flux-platform-src
    rye.ninja/flux-src-commit-hash: 6ede3848c41900a30f075195992057df671e3019
    rye.ninja/component: cert-manager
    rye.ninja/owner: platform-engineering
spec:
  subdomain: crossplane
  zoneName: rye.ninja
  zoneId: 186a0fa51e8dd54ee6910d0f35d5f0c8
  delegatedZoneProviderConfigRef:
    kind: ProviderConfig
    name: dns-admin
  cloudflareProviderConfigRef:
    kind: ProviderConfig
    name: default
```
#### Step 0: Provision the Delegated Hosted Zone Resource

```yaml
apiVersion: route53.aws.m.upbound.io/v1beta1
kind: Zone
metadata:
  namespace: crossplane-system
  name: crossplane-rye-ninja
  labels:
    rye.ninja/flux-src-repository: estenrye/flux-platform-src
    rye.ninja/flux-src-commit-hash: 6ede3848c41900a30f075195992057df671e3019
    rye.ninja/component: cert-manager
    rye.ninja/owner: platform-engineering
    rye.ninja/delegated-hosted-zone: crossplane.rye.ninja
    rye.ninja/delegated-hosted-zone-target-cloud: aws
spec:
  forProvider:
    comment: Delgated Hosted Zone for crossplane.rye.ninja from Cloudflare Zone rye.ninja
    name: crossplane.rye.ninja
  providerConfigRef:
    kind: ProviderConfig
    name: dns-admin
```

#### Step 1: Read the Delegated Hosted Zone Resource

```yaml
apiVersion: route53.aws.m.upbound.io/v1beta1
kind: Zone
metadata:
  annotations:
    crossplane.io/external-create-pending: "2026-04-30T06:58:12Z"
    crossplane.io/external-create-succeeded: "2026-04-30T06:58:13Z"
    crossplane.io/external-name: Z01586993DETLIPRFKSI4
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"route53.aws.m.upbound.io/v1beta1","kind":"Zone","metadata":{"annotations":{},"name":"crossplane-rye-ninja","namespace":"crossplane-system"},"spec":{"forProvider":{"comment":"Delgated Hosted Zone for crossplane.rye.ninja from Cloudflare Zone rye.ninja","name":"crossplane.rye.ninja"},"providerConfigRef":{"kind":"ProviderConfig","name":"dns-admin"}}}
  creationTimestamp: "2026-04-30T06:55:18Z"
  finalizers:
  - finalizer.managedresource.crossplane.io
  generation: 7
  labels:
    rye.ninja/flux-src-repository: estenrye/flux-platform-src
    rye.ninja/flux-src-commit-hash: 6ede3848c41900a30f075195992057df671e3019
    rye.ninja/component: cert-manager
    rye.ninja/owner: platform-engineering
    rye.ninja/delegated-hosted-zone: crossplane.rye.ninja
    rye.ninja/delegated-hosted-zone-target-cloud: aws
  name: crossplane-rye-ninja
  namespace: crossplane-system
  resourceVersion: "9240340"
  uid: 6eb8d6b3-205d-4973-951d-a7592dccac3e
spec:
  forProvider:
    comment: Delgated Hosted Zone for crossplane.rye.ninja from Cloudflare Zone rye.ninja
    name: crossplane.rye.ninja
    tags:
      crossplane-kind: zone.route53.aws.m.upbound.io
      crossplane-name: crossplane-rye-ninja
      crossplane-providerconfig: dns-admin
  initProvider: {}
  managementPolicies:
  - '*'
  providerConfigRef:
    kind: ProviderConfig
    name: dns-admin
status:
  atProvider:
    arn: arn:aws:route53:::hostedzone/Z01586993DETLIPRFKSI4
    comment: Delgated Hosted Zone for crossplane.rye.ninja from Cloudflare Zone rye.ninja
    delegationSetId: ""
    enableAcceleratedRecovery: false
    forceDestroy: false
    id: Z01586993DETLIPRFKSI4
    name: crossplane.rye.ninja
    nameServers:
    - ns-1455.awsdns-53.org
    - ns-147.awsdns-18.com
    - ns-1900.awsdns-45.co.uk
    - ns-851.awsdns-42.net
    primaryNameServer: ns-1455.awsdns-53.org
    tags:
      crossplane-kind: zone.route53.aws.m.upbound.io
      crossplane-name: crossplane-rye-ninja
      crossplane-providerconfig: dns-admin
    tagsAll:
      crossplane-kind: zone.route53.aws.m.upbound.io
      crossplane-name: crossplane-rye-ninja
      crossplane-providerconfig: dns-admin
    zoneId: Z01586993DETLIPRFKSI4
  conditions:
  - lastTransitionTime: "2026-04-30T06:58:46Z"
    observedGeneration: 7
    reason: ReconcileSuccess
    status: "True"
    type: Synced
  - lastTransitionTime: "2026-04-30T06:58:46Z"
    reason: Available
    status: "True"
    type: Ready
  - lastTransitionTime: "2026-04-30T06:58:43Z"
    reason: Success
    status: "True"
    type: LastAsyncOperation
```

#### Step 2: Provision the Cloudflare NS Records

```yaml
apiVersion: dns.upjet-cloudflare.m.upbound.io/v1alpha1
kind: Record
metadata:
  name: ns0-crossplane-rye-ninja
  namespace: crossplane-system
  labels:
    rye.ninja/flux-src-repository: estenrye/flux-platform-src
    rye.ninja/flux-src-commit-hash: 6ede3848c41900a30f075195992057df671e3019
    rye.ninja/component: cert-manager
    rye.ninja/owner: platform-engineering
    rye.ninja/delegated-hosted-zone: crossplane.rye.ninja
    rye.ninja/delegated-hosted-zone-nameserver: ns0
    rye.ninja/delegated-hosted-zone-target-cloud: aws
spec:
  forProvider:
    comment: Delgated Hosted Zone NS-0 for crossplane.rye.ninja in aws
    name: crossplane
    type: NS
    zoneId: 186a0fa51e8dd54ee6910d0f35d5f0c8
    content: ns-1455.awsdns-53.org
    ttl: 1
  providerConfigRef:
    kind: ProviderConfig
    name: default
---
apiVersion: dns.upjet-cloudflare.m.upbound.io/v1alpha1
kind: Record
metadata:
  name: ns1-crossplane-rye-ninja
  namespace: crossplane-system
  labels:
    rye.ninja/flux-src-repository: estenrye/flux-platform-src
    rye.ninja/flux-src-commit-hash: 6ede3848c41900a30f075195992057df671e3019
    rye.ninja/component: cert-manager
    rye.ninja/owner: platform-engineering
    rye.ninja/delegated-hosted-zone: crossplane.rye.ninja
    rye.ninja/delegated-hosted-zone-nameserver: ns1
    rye.ninja/delegated-hosted-zone-target-cloud: aws
spec:
  forProvider:
    comment: Delgated Hosted Zone NS-1 for crossplane.rye.ninja in aws
    name: crossplane
    type: NS
    zoneId: 186a0fa51e8dd54ee6910d0f35d5f0c8
    content: ns-147.awsdns-18.com
    ttl: 1
  providerConfigRef:
    kind: ProviderConfig
    name: default
---
apiVersion: dns.upjet-cloudflare.m.upbound.io/v1alpha1
kind: Record
metadata:
  name: ns2-crossplane-rye-ninja
  namespace: crossplane-system
  labels:
    rye.ninja/flux-src-repository: estenrye/flux-platform-src
    rye.ninja/flux-src-commit-hash: 6ede3848c41900a30f075195992057df671e3019
    rye.ninja/component: cert-manager
    rye.ninja/owner: platform-engineering
    rye.ninja/delegated-hosted-zone: crossplane.rye.ninja
    rye.ninja/delegated-hosted-zone-nameserver: ns2
    rye.ninja/delegated-hosted-zone-target-cloud: aws
spec:
  forProvider:
    comment: Delgated Hosted Zone NS-2 for crossplane.rye.ninja in aws
    name: crossplane
    type: NS
    zoneId: 186a0fa51e8dd54ee6910d0f35d5f0c8
    content: ns-1900.awsdns-45.co.uk
    ttl: 1
  providerConfigRef:
    kind: ProviderConfig
    name: default
---
apiVersion: dns.upjet-cloudflare.m.upbound.io/v1alpha1
kind: Record
metadata:
  name: ns3-crossplane-rye-ninja
  namespace: crossplane-system
  labels:
    rye.ninja/flux-src-repository: estenrye/flux-platform-src
    rye.ninja/flux-src-commit-hash: 6ede3848c41900a30f075195992057df671e3019
    rye.ninja/component: cert-manager
    rye.ninja/owner: platform-engineering
    rye.ninja/delegated-hosted-zone: crossplane.rye.ninja
    rye.ninja/delegated-hosted-zone-nameserver: ns3
    rye.ninja/delegated-hosted-zone-target-cloud: aws
spec:
  forProvider:
    comment: Delgated Hosted Zone NS-3 for crossplane.rye.ninja in aws
    name: crossplane
    type: NS
    zoneId: 186a0fa51e8dd54ee6910d0f35d5f0c8
    content: ns-851.awsdns-42.net
    ttl: 1
  providerConfigRef:
    kind: ProviderConfig
    name: default
```