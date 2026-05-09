# Chat 00004: Fix Deployment Restart Policy in Patches

**Date:** April 30, 2026  
**Task:** Update deployment patch files to change `restartPolicy` from `OnFailure` to `Always`

## Original Prompt

> For all patch files for deployment objects, look for an operation against `path: /spec/template/spec/restartPolicy`.
> 
> If its `value` is `OnFailure`, replace with `Always`.

## Context

The flux-platform-src repository contains multiple Kubernetes applications managed through Flux GitOps. Each application can have patch files that modify deployment objects to customize their behavior for the specific environment.

The task focused on finding deployment patch files that set the `restartPolicy` to `OnFailure` and updating them to use `Always` instead.

## Investigation Process

1. **File Discovery**: Used file search to locate all deployment patch files matching the pattern `**/patches/*deployment*.yaml`
2. **Content Analysis**: Searched for files containing `restartPolicy` operations
3. **Value Inspection**: Read each file to determine which ones had `value: OnFailure`

## Findings

### Files Found with restartPolicy Operations
- `applications/reloader/base/patches/deployment.yaml`
- `applications/opentelemetry-operator/base/patches/deployment.yaml` 
- `applications/flux-monitoring/base/patches/deployment.yaml`
- `applications/flux/base/patches/deployment.yaml`

### Files Requiring Updates
**Before Changes:**
1. **applications/reloader/base/patches/deployment.yaml**
   ```yaml
   - op: add
     path: /spec/template/spec/restartPolicy
     value: OnFailure
   ```

2. **applications/opentelemetry-operator/base/patches/deployment.yaml**
   ```yaml
   - op: add
     path: /spec/template/spec/restartPolicy
     value: OnFailure
   ```

### Files Already Correct
- `applications/flux-monitoring/base/patches/deployment.yaml` - Already had `value: Always`
- `applications/flux/base/patches/deployment.yaml` - Already had `value: Always`

## Decisions Made

### Why Change from OnFailure to Always?

1. **Service Reliability**: `Always` ensures pods restart regardless of exit code, providing better resilience for long-running services
2. **Kubernetes Best Practices**: For deployment objects (typically long-running services), `Always` is the standard restart policy
3. **Consistency**: Aligning all deployment patches to use the same restart policy reduces configuration drift

### Technical Approach

- Used `multi_replace_string_in_file` tool for efficiency to update both files simultaneously
- Maintained exact YAML formatting and structure
- Only changed the `value` field from `OnFailure` to `Always`

## Changes Applied

**After Changes:**
1. **applications/reloader/base/patches/deployment.yaml**
   ```yaml
   - op: add
     path: /spec/template/spec/restartPolicy
     value: Always
   ```

2. **applications/opentelemetry-operator/base/patches/deployment.yaml**
   ```yaml
   - op: add
     path: /spec/template/spec/restartPolicy
     value: Always
   ```

## Impact

- **Reloader Application**: Now uses `Always` restart policy for improved service availability
- **OpenTelemetry Operator**: Now uses `Always` restart policy for consistent operation
- **Consistency**: All deployment patches now use the same restart policy approach
- **No Breaking Changes**: This change enhances reliability without breaking existing functionality

## Files Modified

1. `applications/reloader/base/patches/deployment.yaml`
2. `applications/opentelemetry-operator/base/patches/deployment.yaml`

## Validation

The changes ensure that:
- All deployment objects will restart containers regardless of exit status
- Services maintain high availability through automatic recovery
- Configuration is consistent across all applications in the platform