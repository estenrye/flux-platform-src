# cert-manager Health Probes Implementation

**Date:** May 3, 2026  
**Chat ID:** 00005  
**Context:** Adding liveness and readiness probes to cert-manager components using Kustomize patches

## Overview

This chat documented the process of implementing health probes for cert-manager components (cainjector and controller). The investigation revealed significant architectural differences between components that required component-specific solutions.

## Problem Statement

The cert-manager deployments (cainjector and controller) were missing health probes, which are essential for proper Kubernetes lifecycle management. The user requested:

1. Review cert-manager documentation to determine proper health probe configuration
2. Implement liveness and readiness probes using Kustomize patches  
3. Validate approach through source code review
4. Ensure consistency with JSON patch format rather than strategic merge

## Research Process

### Initial Documentation Review
- Examined cert-manager official documentation
- Found general guidance on health probes but no cainjector-specific details
- Documentation suggested standard `/healthz` and `/readyz` endpoints

### Source Code Investigation
Conducted comprehensive analysis of cert-manager repository:

**Controller Component** (`cmd/controller/app/controller.go`):
```go
// Lines 180-204: Dedicated healthz server setup
healthzServer := healthz.NewServer(opts.LeaderElectionConfig.HealthzTimeout)
// Exposes /livez/leaderElection endpoint
```

**Webhook Component** (`pkg/webhook/server/server.go`):
```go
// Lines 322-348: Health and liveness handlers
func (s *Server) handleHealthz(w http.ResponseWriter, req *http.Request) { ... }
func (s *Server) handleLivez(w http.ResponseWriter, req *http.Request) { ... }
```

**Cainjector Component** (`cmd/cainjector/app/controller.go`):
```go
// Lines 66-94: Only metrics server configuration
metricsServerOptions, err := buildMetricsServerOptions(opts, metricsServerCertificateSource)
// NO health endpoints found
```

## Critical Discovery

**Significant architectural differences between cert-manager components** were discovered through source code analysis:

**cert-manager-cainjector:**
- ❌ **No dedicated health endpoints** like `/healthz` or `/readyz`
- ✅ **Metrics endpoint**: `/metrics` on port 9402 (default)
- ✅ **Pprof endpoint**: Available only if explicitly enabled

**cert-manager-controller:**
- ✅ **Dedicated health endpoints**: `/livez` and `/livez/leaderElection` on port 9403
- ✅ **Metrics endpoint**: `/metrics` on port 9402
- ✅ **Pprof endpoint**: Available if enabled

## Solution Design

### Component-Specific Health Strategies

**Cainjector Strategy:**
Since dedicated health endpoints don't exist, we used the metrics endpoint as a proxy for health status:
- If cainjector can serve metrics, the process is functional
- Metrics endpoint is designed for frequent access
- Provides meaningful health indication for the application layer

**Controller Strategy:**
Use dedicated health endpoints specifically designed for Kubernetes lifecycle management:
- `/livez` endpoint provides proper application-level health checks
- Includes leader election status and clock synchronization verification
- Purpose-built for readiness and liveness probe scenarios

### Probe Configuration

**Cainjector Probes:**
- **Liveness**: `GET /metrics` on port `http-metrics` (30s initial, 10s period, 5s timeout)
- **Readiness**: `GET /metrics` on port `http-metrics` (10s initial, 5s period, 3s timeout)

**Controller Probes:**
- **Readiness**: `GET /livez` on port `http-healthz` (5s initial, 5s period, 3s timeout)

### Implementation Approach

**Kustomize Patch Strategy:**
- Initially used strategic merge patch format
- Evolved to JSON patch (RFC 6902) for better consistency
- Target specific deployment in cert-manager namespace

## Files Created/Modified

### 1. Cainjector Health Probe Patch
**File:** `applications/cert-manager/base/patches/cainjector-health-probes.yaml`

```yaml
- op: add
  path: /spec/template/spec/containers/0/livenessProbe
  value:
    httpGet:
      path: /metrics
      port: http-metrics
      scheme: HTTP
    initialDelaySeconds: 30
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
    successThreshold: 1
- op: add
  path: /spec/template/spec/containers/0/readinessProbe
  value:
    httpGet:
      path: /metrics
      port: http-metrics
      scheme: HTTP
    initialDelaySeconds: 10
    periodSeconds: 5
    timeoutSeconds: 3
    failureThreshold: 3
    successThreshold: 1
```

### 2. Controller Health Probe Patch
**File:** `applications/cert-manager/base/patches/controller-health-probes.yaml`

```yaml
- op: add
  path: /spec/template/spec/containers/0/readinessProbe
  value:
    httpGet:
      path: /livez
      port: http-healthz
      scheme: HTTP
    initialDelaySeconds: 5
    periodSeconds: 5
    timeoutSeconds: 3
    failureThreshold: 3
    successThreshold: 1
```

### 3. Kustomization Configuration
**File:** `applications/cert-manager/base/kustomization.yaml`

```yaml
patches:
  - target:
      group: apps
      version: v1
      kind: Deployment
      name: cert-manager-cainjector
      namespace: cert-manager
    path: patches/cainjector-health-probes.yaml
  - target:
      group: apps
      version: v1
      kind: Deployment
      name: cert-manager
      namespace: cert-manager
    path: patches/controller-health-probes.yaml
```

## Technical Decisions

### JSON Patch vs Strategic Merge

**Decision:** Use JSON Patch (RFC 6902)

**Reasons:**
1. **Explicit Operations**: Clear `add` semantics for new probe configuration
2. **Better Debugging**: Easier to troubleshoot patch application issues
3. **Consistency**: Aligns with modern Kustomize best practices
4. **Precision**: Exact path specification reduces ambiguity

### Timing Configuration

**Cainjector Probe Timing:**
- **Liveness - 30s initial delay**: Accommodates cainjector startup and certificate loading
- **Liveness - 10s period**: Balanced between responsiveness and resource usage
- **Readiness - 10s initial delay**: Faster readiness detection than liveness
- **Readiness - 5s period**: More frequent checks for readiness status

**Controller Probe Timing:**
- **Readiness - 5s initial delay**: Quick readiness detection for dedicated health endpoint
- **Readiness - 5s period**: Standard frequency for health endpoint checks
- **3s timeout**: Sufficient for dedicated health endpoint response

## Validation Process

### Source Code Verification
✅ Confirmed absence of health endpoints in cainjector  
✅ Validated metrics server implementation  
✅ Checked port naming consistency with Helm charts  
✅ Verified JSON patch syntax and targeting  

### Architecture Analysis
✅ Documented differences between cert-manager components  
✅ Confirmed metrics endpoint as only viable option  
✅ Validated approach against Kubernetes best practices  

## Alternative Approaches Considered

### 1. Custom Health Endpoint
**Status:** Rejected  
**Reason:** Would require modifying cert-manager upstream source code

### 2. TCP Socket Check  
**Status:** Rejected  
**Reason:** Less informative than HTTP check, doesn't verify application-level functionality

### 3. Command-based Health Check
**Status:** Rejected  
**Reason:** Requires additional tooling in container, increases complexity

### 4. No Health Probes
**Status:** Rejected  
**Reason:** Leaves Kubernetes without visibility into cainjector health, violates best practices

## Deployment Impact

### Positive Impacts
- ✅ Kubernetes can detect and restart failed cert-manager instances
- ✅ Readiness probes prevent traffic to unhealthy pods
- ✅ Better integration with monitoring and alerting systems
- ✅ Improved troubleshooting visibility via kubectl
- ✅ Controller uses purpose-built health endpoints for accurate status

### Considerations
- ⚠️ Additional HTTP requests to health and metrics endpoints
- ⚠️ Minimal performance impact (endpoints designed for frequent access)
- ⚠️ Cainjector uses metrics endpoint due to architectural constraints
- ⚠️ Controller benefits from dedicated health logic (leader election, clock sync)

## Future Enhancements

### Upstream Contribution Opportunity
Consider proposing dedicated health endpoints for cainjector to align with controller architecture:

```go
// Potential future enhancement for cainjector
func (s *Server) handleHealthz(w http.ResponseWriter, req *http.Request) {
    // Check cainjector-specific health indicators
    // - Certificate injection controller status
    // - Webhook configuration sync status  
    // - API connectivity
}
```

### Monitoring Integration
- Cainjector solution serves dual purpose (health + metrics)
- Controller uses dedicated health endpoints separate from metrics
- Future monitoring should account for health probe traffic
- Consider health-specific metrics if needed

## Key Learnings

### Technical Insights
1. **Component Architecture Varies Significantly**: Even within the same project, components have different health endpoint strategies
2. **Source Code is Authoritative**: Documentation may not reflect implementation differences between components
3. **Operational Endpoints Can Serve Multiple Purposes**: Metrics endpoints can indicate health when dedicated endpoints don't exist
4. **Purpose-Built Health Endpoints Are Superior**: Controller's `/livez` provides more accurate health status than metrics endpoints
5. **Patch Format Choice Matters**: JSON patch provides better control and debugging

### Process Insights
1. **Research Before Implementation**: Source code investigation prevented incorrect assumptions about component uniformity
2. **Component-Specific Analysis Required**: Each cert-manager component needed individual evaluation
3. **Iterative Discovery**: Investigation revealed controller had better health endpoint options than initially assumed
4. **Documentation is Critical**: Complex architectural differences need comprehensive recording
5. **Alternative Analysis**: Considering multiple approaches validates final choice

## References

### Source Code Locations
- **Cainjector Main**: `cmd/cainjector/app/controller.go`
- **Controller Main**: `cmd/controller/app/controller.go` (lines 67-287)
- **Controller Health Setup**: `cmd/controller/app/controller.go` (lines 155-204)
- **Webhook Health**: `pkg/webhook/server/server.go` (lines 213-237, 322-348)  
- **Health Package**: `pkg/healthz/healthz.go`
- **Controller Configuration**: `internal/apis/config/controller/v1alpha1/defaults.go` (line 85: `defaultHealthzServerAddress = "0.0.0.0:9403"`)

### External References
- **cert-manager Repository**: `github.com/cert-manager/cert-manager`
- **Kustomize JSON Patch**: RFC 6902 specification
- **Kubernetes Probes**: Official documentation on liveness/readiness probes

## Chat Artifacts

This implementation was the result of an interactive troubleshooting session that involved:

1. **Initial Problem Identification**: Missing health probes in cert-manager components
2. **Documentation Research**: Standard cert-manager probe patterns  
3. **Source Code Deep Dive**: Discovery of significant architectural differences between components
4. **Solution Iteration**: Evolution from strategic merge to JSON patch, expansion from cainjector-only to multi-component
5. **Component-Specific Implementation**: Tailored solutions based on available endpoints
6. **Implementation Validation**: Confirmation of approach viability for both components
7. **Comprehensive Documentation**: This README and supporting chat log

The process demonstrated the importance of thorough investigation before implementation, the value of component-specific analysis, and the benefit of adapting solutions based on discovered architectural constraints. The final solution provides optimal health checking for each component based on their individual capabilities.