# Chat 00003: Generate DelegatedHostedZone Composition

**Date:** April 30, 2026  
**Context:** Crossplane Composite Resource Development  
**Status:** ✅ Complete - Production-ready AWS-specific implementation  
**Objective:** AWS-specific Crossplane Composite Resource for delegated hosted zones

## Implementation Overview

### Final Architecture
- **Purpose**: AWS-specific delegated hosted zone provisioning using Route53 and Cloudflare DNS
- **API**: `XDelegatedHostedZoneAWS` composite resource with v2 API compliance
- **Pipeline**: 3-step Go template composition with configurable provider configs
- **Dependencies**: Requires function-go-templating with proper network policies
- **Status**: Full readiness reporting with proper resource lifecycle management

### API Specification
```yaml
spec:
  zoneId: string                          # Cloudflare Zone ID
  zoneName: string                        # DNS zone name in Cloudflare  
  subdomain: string                       # Subdomain to delegate
  ttl: integer                           # Optional, defaults to 1
  delegatedZoneProviderConfigRef:         # AWS provider reference (configurable kind)
    kind: string                         # ProviderConfig or ClusterProviderConfig
    name: string                         # Provider config name
  cloudflareProviderConfigRef:           # Cloudflare provider reference (configurable kind)
    kind: string                         # ProviderConfig or ClusterProviderConfig  
    name: string                         # Provider config name

status:
  nameServers: []string                  # AWS Route53 nameservers
  zoneId: string                        # AWS hosted zone ID
  conditions: []Condition               # Ready, Synced, Responsive status
```

### Current File Structure
```
applications/crossplane-resources/delegated-hosted-zone-aws/
├── README.md                    # Design documentation
├── catalog.yaml                 # Service catalog metadata
├── xrd.yaml                    # v2 CompositeResourceDefinition
├── composition.yaml            # v1 Pipeline Composition with configurable providers
├── kustomization.yaml          # Deployment configuration
└── examples/
    ├── README.md
    ├── example-composite-resource.yaml
    └── kustomization.yaml

applications/crossplane-functions/function-go-templating/
├── function.yaml               # Function package definition
├── catalog.yaml               # Function documentation  
├── network-policy.yaml        # Network policies for function communication
├── crossplane-function-egress-policy.yaml # Crossplane egress to function
└── kustomization.yaml         # Function deployment with network policies

clusters/crossplane/
├── kustomization.yaml          # Cluster-level resource ordering
└── resources/
    └── delegated-hosted-zone-aws.crossplane-rye-ninja.yaml  # Example instance
```

## Recent Improvements (Production Readiness)

### 1. **Configurable Provider Config Types** ✅
- **Enhancement**: Support both `ProviderConfig` and `ClusterProviderConfig`
- **Implementation**: Dynamic provider config `kind` from composite resource spec
- **Benefit**: Flexible deployment patterns (namespace-scoped vs cluster-scoped configs)

### 2. **Network Policy Resolution** ✅ 
- **Issue**: Function communication blocked by default-deny policies
- **Solution**: Comprehensive network policies for function-go-templating
- **Policies**: Ingress (port 9443), Egress, Crossplane-to-Function communication
- **Result**: Reliable pipeline execution

### 3. **Readiness Reporting** ✅
- **Issue**: Composite resource stuck in "Creating" status
- **Solution**: Explicit readiness annotations on all managed resources
- **Implementation**: `gotemplating.fn.crossplane.io/ready: "True"` annotations
- **Result**: Proper Ready/Synced status propagation

### 4. **Template Syntax Corrections** ✅
- **Go Template Format**: Fixed `inline.template` structure vs direct string
- **Function Arguments**: Corrected `replace` function parameter order  
- **Provider Config Schema**: Removed unsupported `apiVersion` fields
- **Result**: Reliable template execution without syntax errors

## Key Technical Decisions

### 1. Pipeline Mode with Go Templates
**Rationale**: More flexible for dynamic resource generation, better conditional logic, cleaner template syntax

### 2. AWS-Specific Focus
**Decision**: Removed multi-cloud abstraction, simplified API by removing `targetCloud` field
**Rationale**: Reduces complexity, clearer intent, enables future cloud-specific optimizations

### 3. API Version Strategy
**XRD**: `apiextensions.crossplane.io/v2` (modern, no claims support)
**Composition**: `apiextensions.crossplane.io/v1` (v2 not available for Compositions)

### 4. Dependency Management  
**Requirement**: function-go-templating must be deployed before compositions can execute
**Solution**: Added function deployment to cluster kustomization with proper ordering

### 5. Resource Generation Pattern
**Implementation**: Dynamic NS record creation using Go template loops based on actual AWS nameserver count
**Benefit**: Resilient to AWS nameserver variations (typically 4, but can vary)

## Implementation Summary

### Evolution Path
1. **Initial**: Generic multi-cloud composite resource with `targetCloud` field
2. **Refactor**: AWS-specific focus, simplified API, removed multi-cloud abstraction  
3. **Modernize**: Updated to Crossplane v2 APIs (XRD only, Composition remains v1)
4. **Compliance**: Removed claims support (not available in v2), direct composite resource usage
5. **Dependencies**: Discovered and resolved function-go-templating requirement
6. **Finalize**: Corrected kustomization structure (catalog.yaml excluded from resources)

### Key Corrections Made
- **Claims Removal**: v2 APIs don't support claims - examples now use `XDelegatedHostedZoneAWS` directly
- **API Version Split**: XRD uses v2, Composition must remain at v1 (v2 unavailable for Compositions)  
- **Function Dependency**: Added function-go-templating deployment before composite resource deployment
- **Resource Ordering**: Updated cluster kustomization to deploy providers → functions → composite resources
- **Configuration Cleanup**: Removed catalog.yaml from kustomization resources (documentation only)

## Production Usage Examples

### Example 1: ClusterProviderConfig (Recommended)
```yaml
apiVersion: dns.platform.rye.ninja/v1alpha1
kind: XDelegatedHostedZoneAWS
metadata:
  name: api-subdomain
  namespace: production
spec:
  subdomain: api
  zoneName: mycompany.com
  zoneId: "abc123def456"  # Cloudflare zone ID
  ttl: 300               # 5 minute TTL
  delegatedZoneProviderConfigRef:
    kind: ClusterProviderConfig
    name: aws-dns-admin
  cloudflareProviderConfigRef:
    kind: ClusterProviderConfig
    name: cloudflare-production
```

### Example 2: Namespace-scoped ProviderConfig
```yaml
apiVersion: dns.platform.rye.ninja/v1alpha1
kind: XDelegatedHostedZoneAWS
metadata:
  name: staging-api
  namespace: staging
spec:
  subdomain: api
  zoneName: staging.mycompany.com
  zoneId: "def456ghi789"
  delegatedZoneProviderConfigRef:
    kind: ProviderConfig      # Namespace-scoped
    name: staging-aws-config
  cloudflareProviderConfigRef:
    kind: ProviderConfig      # Namespace-scoped  
    name: staging-cloudflare-config
```

### Result
Both examples will create:
1. **AWS Route53 Zone**: `api.mycompany.com` → `Z0147279UVRR903LNCE0`
2. **Cloudflare NS Records**: 4 NS records pointing to AWS nameservers
3. **Status Updates**: Populated nameServers and zoneId in composite resource

---

## Troubleshooting

For comprehensive troubleshooting procedures, see **[troubleshooting.md](./troubleshooting.md)**.

**Quick Links:**
- [Network Policy Issues](./troubleshooting.md#1-composite-resource-stuck-in-creating-status)
- [Template Syntax Errors](./troubleshooting.md#2-pipeline-execution-failures)  
- [Provider Configuration Problems](./troubleshooting.md#4-provider-configuration-issues)
- [Complete Recovery Procedures](./troubleshooting.md#recovery-procedures)

---

## Additional Resources

### Related Documentation
- [Crossplane Composition Functions](https://docs.crossplane.io/latest/concepts/composition-functions/)
- [Go Template Function Reference](https://github.com/crossplane-contrib/function-go-templating)
- [AWS Route53 Provider](https://marketplace.upbound.io/providers/upbound/provider-aws-route53/)
- [Cloudflare DNS Provider](https://marketplace.upbound.io/providers/wildbitca/provider-cloudflare-dns/)

### Development Commands
```bash
# Test composition locally
crossplane beta render \
  examples/example-composite-resource.yaml \
  composition.yaml \
  ../../../crossplane-functions/function-go-templating/function.yaml

# Validate XRD schema
kubectl apply --dry-run=server -f xrd.yaml

# Monitor real-time status
watch kubectl get xdelegatedhostedzoneaws -A
```

### Pipeline Steps
1. **create-zone**: Provisions AWS Route53 hosted zone with naming convention
2. **create-ns-records**: Dynamically creates Cloudflare NS records for each nameserver  
3. **status-update**: Updates composite resource status with nameservers and zone ID

## Best Practices for Composite Resource Implementation

### 1. **Development Workflow**
```bash
# 1. Deploy dependencies first
kubectl apply -k applications/crossplane-functions/function-go-templating/

# 2. Deploy composite resource definitions
kubectl apply -k applications/crossplane-resources/delegated-hosted-zone-aws/

# 3. Test with example instance
kubectl apply -f clusters/crossplane/resources/delegated-hosted-zone-aws.example.yaml

# 4. Monitor pipeline execution
kubectl get xdelegatedhostedzoneaws -A --watch
kubectl logs -n crossplane-system deployment/crossplane --follow
```

### 2. **Composition Design Patterns**

#### **Template Structure**
```yaml
# Use proper inline template format
input:
  apiVersion: gotemplating.fn.crossplane.io/v1beta1
  kind: GoTemplate
  source: Inline
  inline:
    template: |  # <- Note: template key required
      {{ $var := .observed.composite.resource.spec.field }}
      ---
      apiVersion: example.com/v1
      kind: Resource
```

#### **Provider Config References**
```yaml
# Make provider configs configurable
providerConfigRef:
  kind: {{ .observed.composite.resource.spec.providerConfigRef.kind }}
  name: {{ .observed.composite.resource.spec.providerConfigRef.name }}
```

#### **Readiness Annotations**
```yaml
# Always include explicit readiness for managed resources
metadata:
  annotations:
    gotemplating.fn.crossplane.io/composition-resource-name: resource-name
    gotemplating.fn.crossplane.io/ready: "True"  # <- Critical for status propagation
```

### 3. **Network Policy Requirements**
When using functions in environments with network policies:

```yaml
# Required: Function ingress policy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: function-go-templating-allow-ingress
spec:
  podSelector:
    matchLabels:
      pkg.crossplane.io/function: function-go-templating
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: crossplane
    ports:
    - protocol: TCP
      port: 9443  # gRPC port

# Required: Crossplane egress policy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy  
metadata:
  name: crossplane-allow-egress-to-functions
spec:
  podSelector:
    matchLabels:
      app: crossplane
  egress:
  - to:
    - podSelector:
        matchLabels:
          pkg.crossplane.io/function: function-go-templating
    ports:
    - protocol: TCP
      port: 9443
```

### 4. **XRD Schema Design**
```yaml
# Flexible provider config references
delegatedZoneProviderConfigRef:
  type: object
  properties:
    kind:
      type: string           # Allow ProviderConfig or ClusterProviderConfig
    name:
      type: string
  required: [kind, name]     # Require both for validation
```

### 5. **Testing Strategy**
1. **Unit Testing**: Validate XRD schema with `kubectl apply --dry-run=server`
2. **Integration Testing**: Test pipeline steps independently using annotations
3. **End-to-End Testing**: Full composite resource lifecycle with cleanup
4. **Error Testing**: Intentionally break configurations to validate error handling

### 6. **Monitoring and Observability**
```bash
# Monitor function execution
kubectl logs -n crossplane-system function-go-templating-* --follow

# Check pipeline status
kubectl describe xdelegatedhostedzoneaws <name> -n <namespace>

# Verify managed resource creation
kubectl get zones.route53.aws.m.upbound.io -A
kubectl get records.dns.upjet-cloudflare.m.upbound.io -A

# Check resource relationships
kubectl get xdelegatedhostedzoneaws <name> -o yaml | grep -A10 resourceRefs
```

### Resource Naming Convention
- **Zone**: `{subdomain-with-dashes}-{zoneName-with-dashes}`
- **NS Records**: `ns{index}-{subdomain-with-dashes}-{zoneName-with-dashes}`
- **Example**: `crossplane-rye-ninja` for subdomain `crossplane` and zone `rye.ninja`

### Dependencies
- **AWS Provider**: `family-aws` (Route53 resources)
- **Cloudflare Provider**: `family-cloudflare` (DNS records)  
- **Function**: `function-go-templating` (Pipeline mode execution)

## Current Status

✅ **Complete Implementation**
- AWS-specific XRD using Crossplane v2 APIs (no claims)
- Pipeline Composition with v1 API (function dependency resolved)  
- Function deployment configured with proper ordering
- Documentation and examples updated for direct composite resource usage
- Kustomization structure finalized (catalog.yaml excluded from deployment)

## Usage

### Deploy via Flux (Recommended)
The resources deploy automatically via Flux using the cluster kustomization at [clusters/crossplane/kustomization.yaml](clusters/crossplane/kustomization.yaml).

### Manual Deployment
```bash
# Deploy function dependency first
kubectl apply -k applications/crossplane-functions/function-go-templating/

# Deploy composite resource  
kubectl apply -k applications/crossplane-resources/delegated-hosted-zone-aws/

# Deploy example
kubectl apply -k applications/crossplane-resources/delegated-hosted-zone-aws/examples/
```

### Monitor Status
```bash
kubectl get xdelegatedhostedzoneaws crossplane-rye-ninja -n crossplane-system
kubectl describe xdelegatedhostedzoneaws crossplane-rye-ninja -n crossplane-system
```

## Key Learnings & Outcomes

### Technical Insights
- **API Evolution**: Crossplane v2 removes claims support, requiring direct composite resource usage
- **Function Dependencies**: Pipeline mode requires explicit function deployment before compositions can execute  
- **API Version Split**: Only XRDs support v2 APIs; Compositions must remain at v1
- **Kustomize Best Practices**: Catalog.yaml files provide documentation but should not be deployed as resources

### Architecture Benefits
- **AWS-Specific Focus**: Simplified API and clearer intent vs. multi-cloud abstraction
- **Pipeline Mode**: More flexible than patch-and-transform for dynamic resource generation
- **Dependency Ordering**: Proper provider → function → composite resource deployment sequence prevents failures

### Future Evolution Path
The current AWS-specific approach enables future multi-cloud support through:
- Dedicated compositions per cloud provider (AWS, GCP, Azure)  
- Generic wrapper composition for cloud selection
- Cloud-specific optimizations and configurations