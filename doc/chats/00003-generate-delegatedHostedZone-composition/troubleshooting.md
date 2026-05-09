# Troubleshooting Guide: Crossplane Delegated Hosted Zone Composition

**Purpose**: Comprehensive troubleshooting procedures for XDelegatedHostedZoneAWS composite resources  
**Scope**: Pipeline execution, network policies, provider configurations, and common error patterns

---

## Quick Diagnosis Commands

```bash
# Check composite resource status
export KUBECONFIG=~/.kube/crossplane-controlplane-cluster.yaml
kubectl get xdelegatedhostedzoneaws -A

# View detailed status and events
kubectl describe xdelegatedhostedzoneaws <name> -n <namespace>

# Check managed resource creation
kubectl get zones.route53.aws.m.upbound.io -A
kubectl get records.dns.upjet-cloudflare.m.upbound.io -A

# Monitor function logs
kubectl logs -n crossplane-system function-go-templating-* --tail=50 --follow

# Check Crossplane controller logs
kubectl logs -n crossplane-system deployment/crossplane --tail=100 | grep -E "(error|Error|warning|Warning|pipeline)"
```

---

## Common Issues & Solutions

### 1. **Composite Resource Stuck in "Creating" Status**

#### Symptoms
```
NAME                   SYNCED   READY   COMPOSITION
crossplane-rye-ninja   True     False   delegated-hosted-zone-aws
```

#### **Issue A: Missing Readiness Annotations**
**Root Cause**: Managed resources not explicitly marked as ready

**Solution**: Ensure composition includes readiness annotations
```yaml
# In composition templates
metadata:
  annotations:
    gotemplating.fn.crossplane.io/composition-resource-name: resource-name
    gotemplating.fn.crossplane.io/ready: "True"  # <- Required
```

**Verification**:
```bash
kubectl get compositionrevision | grep delegated-hosted-zone-aws | tail -1
kubectl get compositionrevision <revision-name> -o yaml | grep -A5 -B5 ready
```

#### **Issue B: Network Policy Blocking Function Communication**
**Root Cause**: Function cannot receive gRPC requests from Crossplane

**Symptoms**: Function logs show no activity, Crossplane logs show connection timeouts
```
rpc error: code = DeadlineExceeded desc = latest balancer error: connection error: desc = "transport: Error while dialing: dial tcp 10.20.201.222:9443: i/o timeout"
```

**Solution**: Deploy network policies for function communication
```bash
# Apply network policies
kubectl apply -f applications/crossplane-functions/function-go-templating/network-policy.yaml
kubectl apply -f applications/crossplane-functions/function-go-templating/crossplane-function-egress-policy.yaml

# Verify policies are applied
kubectl get networkpolicy -n crossplane-system | grep function-go-templating
kubectl get networkpolicy -n crossplane-system | grep crossplane-allow-egress-to-functions
```

**Test Function Connectivity**:
```bash
# Check if function is receiving requests
kubectl logs -n crossplane-system function-go-templating-* --tail=20
# Should show: {"level":"info","ts":...,"msg":"Running Function","tag":"..."}
```

### 2. **Pipeline Execution Failures**

#### **Issue A: Template Syntax Errors**
**Symptoms**: 
```
cannot execute template: template: manifests:3:36: executing "manifests" at <replace>: wrong number of args for replace: want 3 got 4
```

**Solution**: Fix Go template function syntax
```yaml
# ❌ Incorrect (4 arguments)
{{ $name := replace $subdomain "." "-" -1 }}

# ✅ Correct (3 arguments) 
{{ $name := replace "." "-" $subdomain }}
```

#### **Issue B: Provider Config Schema Errors**
**Symptoms**:
```
.spec.providerConfigRef.apiVersion: field not declared in schema
spec.providerConfigRef.kind: Required value
```

**Solution**: Use correct provider config reference format
```yaml
# ❌ Incorrect (includes unsupported apiVersion)
providerConfigRef:
  apiVersion: aws.m.upbound.io/v1beta1  # Not supported
  kind: ClusterProviderConfig
  name: dns-admin

# ✅ Correct (only kind and name)
providerConfigRef:
  kind: {{ .observed.composite.resource.spec.delegatedZoneProviderConfigRef.kind }}
  name: {{ .observed.composite.resource.spec.delegatedZoneProviderConfigRef.name }}
```

#### **Issue C: Template Format Errors**
**Symptoms**:
```
cannot get Function input from *v1beta1.RunFunctionRequest: cannot unmarshal JSON string into Go value of type v1beta1.TemplateSourceInline
```

**Solution**: Use proper inline template structure
```yaml
# ❌ Incorrect (direct string)
input:
  source: Inline
  inline: |
    {{ template content }}

# ✅ Correct (template key)
input:
  source: Inline
  inline:
    template: |
      {{ template content }}
```

### 3. **Function Deployment Issues**

#### **Issue A: Function Not Found**
**Symptoms**:
```
cannot run Function "function-go-templating": rpc error: code = Unavailable
```

**Solution**: Deploy function-go-templating before composite resources
```bash
# 1. Deploy function first
kubectl apply -k applications/crossplane-functions/function-go-templating/

# 2. Wait for function to be ready
kubectl get functions.pkg.crossplane.io function-go-templating
kubectl get pods -n crossplane-system -l pkg.crossplane.io/function=function-go-templating

# 3. Then deploy composite resources
kubectl apply -k applications/crossplane-resources/delegated-hosted-zone-aws/
```

#### **Issue B: Function Pod Not Ready**
**Check Pod Status**:
```bash
kubectl get pods -n crossplane-system -l pkg.crossplane.io/function=function-go-templating
kubectl describe pod -n crossplane-system <function-pod-name>
```

### 4. **Provider Configuration Issues**

#### **Issue A: Provider Config Not Found**
**Symptoms**:
```
cannot apply composed resource: ProviderConfig.aws.m.upbound.io "dns-admin" not found
```

**Solution**: Verify provider configs exist
```bash
# Check AWS provider configs
kubectl get clusterproviderconfig.aws.m.upbound.io -A
kubectl get providerconfig.aws.m.upbound.io -A

# Check Cloudflare provider configs  
kubectl get clusterproviderconfig.upjet-cloudflare.m.upbound.io -A
kubectl get providerconfig.upjet-cloudflare.m.upbound.io -A
```

#### **Issue B: Incorrect Provider Config Kind**
**Solution**: Match provider config kind in composite resource spec
```yaml
# For ClusterProviderConfig
spec:
  delegatedZoneProviderConfigRef:
    kind: ClusterProviderConfig  # Must match actual resource
    name: dns-admin

# For ProviderConfig  
spec:
  delegatedZoneProviderConfigRef:
    kind: ProviderConfig         # Must match actual resource
    name: my-provider-config
```

### 5. **Resource Creation Failures**

#### **Issue A: AWS Zone Creation Fails**
**Check AWS Provider Status**:
```bash
kubectl get providers.pkg.crossplane.io | grep aws
kubectl logs -n crossplane-system deployment/upbound-provider-aws-route53-*
```

**Verify AWS Credentials**:
```bash
kubectl get secret -n crossplane-system | grep aws
kubectl describe clusterproviderconfig.aws.m.upbound.io dns-admin
```

#### **Issue B: Cloudflare Record Creation Fails**
**Check Cloudflare Provider**:
```bash
kubectl get providers.pkg.crossplane.io | grep cloudflare
kubectl logs -n crossplane-system deployment/wildbitca-provider-cloudflare-dns-*
```

**Verify Cloudflare Configuration**:
```bash
kubectl describe clusterproviderconfig.upjet-cloudflare.m.upbound.io cloudflare-provider-config
```

---

## Debugging Workflow

### Step 1: Initial Assessment
```bash
# Get overall status
kubectl get xdelegatedhostedzoneaws <name> -n <namespace>

# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | grep <name>
```

### Step 2: Pipeline Analysis
```bash
# Check composition revision
kubectl get xdelegatedhostedzoneaws <name> -n <namespace> -o jsonpath='{.spec.crossplane.compositionRevisionRef.name}'

# Examine composition content
kubectl get compositionrevision <revision-name> -o yaml | head -50
```

### Step 3: Function Investigation
```bash
# Function health
kubectl get functions.pkg.crossplane.io function-go-templating
kubectl get pods -n crossplane-system -l pkg.crossplane.io/function=function-go-templating

# Function logs (during execution)
kubectl logs -n crossplane-system function-go-templating-* --follow
```

### Step 4: Resource Tracking
```bash
# Check managed resources
kubectl get xdelegatedhostedzoneaws <name> -n <namespace> -o yaml | grep -A20 resourceRefs

# Verify each managed resource
kubectl get zones.route53.aws.m.upbound.io <zone-name> -n <namespace>
kubectl get records.dns.upjet-cloudflare.m.upbound.io -n <namespace>
```

### Step 5: Force Reconciliation
```bash
# Trigger manual reconciliation
kubectl annotate xdelegatedhostedzoneaws <name> -n <namespace> crossplane.io/reconcile="$(date)" --overwrite

# Monitor the reconciliation
kubectl get xdelegatedhostedzoneaws <name> -n <namespace> --watch
```

---

## Recovery Procedures

### Complete Reset
```bash
# 1. Delete composite resource instance
kubectl delete xdelegatedhostedzoneaws <name> -n <namespace>

# 2. Wait for cleanup
kubectl get zones.route53.aws.m.upbound.io -A
kubectl get records.dns.upjet-cloudflare.m.upbound.io -A

# 3. Restart Crossplane controller (if needed)
kubectl rollout restart deployment/crossplane -n crossplane-system

# 4. Redeploy with fixed configuration
kubectl apply -f <fixed-composite-resource.yaml>
```

### Function Reset
```bash
# Restart function deployment
kubectl delete pods -n crossplane-system -l pkg.crossplane.io/function=function-go-templating

# Verify function restart
kubectl get pods -n crossplane-system -l pkg.crossplane.io/function=function-go-templating --watch
```

---

## Performance Monitoring

### Resource Creation Times
- **AWS Zone**: 30-60 seconds typical
- **Cloudflare Records**: 10-30 seconds per record
- **Status Update**: 5-10 seconds

### Expected Status Progression
1. **Initial**: Ready=False, Synced=False
2. **Zone Created**: Ready=False, Synced=True  
3. **Records Created**: Ready=False, Synced=True
4. **Complete**: Ready=True, Synced=True

### Warning Signs
- Stuck in same status > 5 minutes
- Function logs show no activity
- Missing managed resources after 2 minutes
- Repeated reconciliation without progress

---

## Prevention Checklist

### Pre-Deployment
- [ ] Function-go-templating deployed and ready
- [ ] Network policies configured (if required)
- [ ] Provider configs exist and accessible  
- [ ] Composition syntax validated
- [ ] XRD schema compliance verified

### Post-Deployment Monitoring
- [ ] Composite resource reaches Ready=True within 5 minutes
- [ ] All expected managed resources created
- [ ] Function logs show successful execution
- [ ] No error events in composite resource
- [ ] Status fields populated correctly (nameServers, zoneId)