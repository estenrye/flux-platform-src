# Chat 00003: Generate DelegatedHostedZone Composition

**Date:** April 30, 2026  
**Context:** Crossplane Composite Resource Development  
**Status:** ✅ Complete - AWS-specific implementation deployed  
**Objective:** AWS-specific Crossplane Composite Resource for delegated hosted zones

## Implementation Overview

### Final Architecture
- **Purpose**: AWS-specific delegated hosted zone provisioning using Route53 and Cloudflare DNS
- **API**: `XDelegatedHostedZoneAWS` composite resource with v2 API compliance
- **Pipeline**: 3-step Go template composition (create-zone → create-ns-records → status-update)
- **Dependencies**: Requires function-go-templating for Pipeline mode execution

### API Specification
```yaml
spec:
  zoneId: string          # Cloudflare Zone ID
  zoneName: string        # DNS zone name in Cloudflare  
  subdomain: string       # Subdomain to delegate
  ttl: integer           # Optional, defaults to 1
  awsProviderConfigRef: object      # AWS provider reference
  cloudflareProviderConfigRef: object # Cloudflare provider reference
```

### Current File Structure
```
applications/crossplane-resources/delegated-hosted-zone-aws/
├── README.md                    # Design documentation
├── catalog.yaml                 # Service catalog metadata
├── xrd.yaml                    # v2 CompositeResourceDefinition
├── composition.yaml            # v1 Pipeline Composition
├── kustomization.yaml          # Deployment configuration
└── examples/
    ├── README.md
    ├── example-composite-resource.yaml
    └── kustomization.yaml

applications/crossplane-functions/function-go-templating/
├── function.yaml               # Function package definition
├── catalog.yaml               # Function documentation  
└── kustomization.yaml         # Function deployment
```

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

### Current Deployment Structure
```yaml
# clusters/crossplane/kustomization.yaml
resources:
  - ../../applications/crossplane-providers/family-aws
  - ../../applications/crossplane-providers/family-cloudflare  
  - ../../applications/crossplane-functions/function-go-templating
  - ../../applications/crossplane-resources/delegated-hosted-zone-aws
```

## Technical Details

### Pipeline Steps
1. **create-zone**: Provisions AWS Route53 hosted zone with naming convention
2. **create-ns-records**: Dynamically creates Cloudflare NS records for each nameserver  
3. **status-update**: Updates composite resource status with nameservers and zone ID

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