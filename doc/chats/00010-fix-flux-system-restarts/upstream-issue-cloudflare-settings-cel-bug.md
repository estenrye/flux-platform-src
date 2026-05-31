# Upstream PR Plan — Cloudflare `settings` CRD CEL Validation Bug

**Repository:** https://github.com/wildbitca/provider-upjet-cloudflare
**PRs disabled:** No — PRs are open; Issues are disabled. Submit via Pull Request.

---

# Upstream PR Plan — Cloudflare `settings` CRD CEL Validation Bug

**Repository:** https://github.com/wildbitca/provider-upjet-cloudflare
**PRs disabled:** No — PRs are open; Issues are disabled. Submit via Pull Request.

**Root fix location:** `github.com/wildbitca/upjet` (the forked upjet library), not the provider itself.
**Two PRs required** — fix in upjet fork first, then bump the provider's dependency.

---

## Why Making `value` Optional Is Wrong

Making the field `Optional` in the Terraform schema is semantically incorrect: `value` IS genuinely required for `cloudflare_zone_setting`. Changing it to Optional would mean upjet treats the field as not required, which is wrong — the issue is that CEL cannot reference the field due to its type, not that the field is optional.

---

## Root Cause (detailed)

The call chain in `wildbitca/upjet/pkg/types/builder.go`:

1. `buildSchema` handles `SchemaTypeDynamic` fields by returning `*apiextensionsv1.JSON` — this maps to `x-kubernetes-preserve-unknown-fields: true` (no `type`) in the generated CRD OpenAPI schema. This part is correct.

2. `addParameterField` tracks required top-level fields for CEL rule generation:
   ```go
   if requiredBySchema && !f.Identifier && len(f.CanonicalPaths) == 1 {
       r.topLevelRequiredParams = append(r.topLevelRequiredParams,
           newTopLevelRequiredParam(f.TransformedName, !f.TFTag.AlwaysOmitted()))
   }
   ```
   It correctly identifies `value` as required, but adds it to `topLevelRequiredParams` **without checking whether the field's schema type is `SchemaTypeDynamic`**. This part is the bug.

3. `AddToBuilder` then emits the `// +kubebuilder:validation:XValidation:rule="... has(self.forProvider.value) ..."` marker for every entry in `topLevelRequiredParams`, including the dynamic `value` field.

4. At `make generate` time, controller-gen converts the marker to a `x-kubernetes-validations` rule in the CRD YAML.

5. When Crossplane tries to apply the CRD, the Kubernetes API server rejects it because `value` is typeless — CEL's static type environment [excludes `x-kubernetes-preserve-unknown-fields` fields](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules).

The v2.2.2 upjet fork fixed the **runtime** DynamicPseudoType unwrapping (envelope `{type,value}` → bare value in `FromTerraform`), but did not fix the **schema generation** path that produces the CEL rule.

---

## The Correct Fix

**One-line change in `wildbitca/upjet`**, `pkg/types/builder.go`, `addParameterField`:

**Before:**
```go
if requiredBySchema && !f.Identifier && len(f.CanonicalPaths) == 1 {
    requiredBySchema = false
    r.topLevelRequiredParams = append(r.topLevelRequiredParams,
        newTopLevelRequiredParam(f.TransformedName, !f.TFTag.AlwaysOmitted()))
}
```

**After:**
```go
if requiredBySchema && !f.Identifier && len(f.CanonicalPaths) == 1 {
    requiredBySchema = false
    // Skip CEL required-field rule generation for SchemaTypeDynamic fields.
    // These fields map to x-kubernetes-preserve-unknown-fields: true (no type)
    // in the CRD OpenAPI schema. The Kubernetes CEL static type environment
    // excludes typeless fields, so emitting has(self.forProvider.FIELD) for them
    // causes the API server to reject the CRD at install time.
    // See: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
    if f.Schema.Type != conversiontfjson.SchemaTypeDynamic {
        r.topLevelRequiredParams = append(r.topLevelRequiredParams,
            newTopLevelRequiredParam(f.TransformedName, !f.TFTag.AlwaysOmitted()))
    }
}
```

This is semantically correct because:
- The field remains Required in the Terraform schema — nothing about the field definition changes
- Only the CEL rule emission is skipped — the field is still usable and required by Crossplane's management-policy validation
- The fix generalises to any `SchemaTypeDynamic` field across all providers, not just `cloudflare_zone_setting`

---

## Two PRs Required

### PR 1 — `wildbitca/upjet`: Fix CEL rule generation for `SchemaTypeDynamic` fields

**PR title:** `fix: skip CEL required-field rule for SchemaTypeDynamic (x-kubernetes-preserve-unknown-fields) fields`

**Steps:**

```bash
gh repo fork wildbitca/upjet --clone --remote
cd upjet
git checkout -b fix/cel-skip-dynamic-pseudo-type
```

Edit `pkg/types/builder.go` as shown above, then:

```bash
go build ./...
go test ./...
git add pkg/types/builder.go
git commit -m "fix: skip CEL required-field rule for SchemaTypeDynamic fields

SchemaTypeDynamic fields map to x-kubernetes-preserve-unknown-fields: true
(no explicit type) in the generated CRD OpenAPI schema. The Kubernetes CEL
static type environment excludes typeless fields, so emitting a
has(self.forProvider.FIELD) required-field validation rule for them causes
the API server to reject the entire CRD at install time.

v2.2.2 fixed the runtime DynamicPseudoType unwrapping in FromTerraform
conversion, but did not address the schema-generation path that emits the
CEL marker in addParameterField.

Fix: guard the topLevelRequiredParams append with a SchemaTypeDynamic
check. The field stays Required in the Terraform schema; only the
uncompilable CEL rule is suppressed."

git push origin fix/cel-skip-dynamic-pseudo-type
gh pr create --repo wildbitca/upjet --base main --title "fix: skip CEL required-field rule for SchemaTypeDynamic (x-kubernetes-preserve-unknown-fields) fields"
```

Tag the merged commit as `v2.2.3`.

---

### PR 2 — `wildbitca/provider-upjet-cloudflare`: Bump upjet to v2.2.3, regenerate

**PR title:** `fix(zone): bump upjet to v2.2.3 — fixes settings CRD CEL install failure`

**Steps:**

```bash
gh repo fork wildbitca/provider-upjet-cloudflare --clone --remote
cd provider-upjet-cloudflare
git checkout -b fix/settings-crd-cel-upjet-bump

# Update the replace directive in go.mod
sed -i '' 's|github.com/wildbitca/upjet/v2 v2.2.2|github.com/wildbitca/upjet/v2 v2.2.3|' go.mod
go mod tidy

# Regenerate CRDs
make submodules
make generate

# Verify the CEL rule is gone from the settings types file
grep -c "has(self.forProvider.value)" apis/zone/v1alpha1/zz_setting_types.go
# Expected: 0

# Verify the field still exists and is still typed as apiextensionsv1.JSON
grep -A3 "Value " apis/zone/v1alpha1/zz_setting_types.go

# Dry-run apply the CRD against the API server to confirm it passes validation
kubectl apply -f package/crds/zone.upjet-cloudflare.upbound.io_settings.yaml --dry-run=server
# Expected: no error

git add go.mod go.sum
git add apis/zone/
git add package/crds/
git commit -m "fix(zone): bump upjet to v2.2.3 — fixes settings CRD CEL install failure

provider-cloudflare-zone v0.2.6 and earlier ship settings CRDs
(settings.zone.upjet-cloudflare.upbound.io and
settings.zone.upjet-cloudflare.m.upbound.io) that fail to install on
Kubernetes ≥ v1.25. The API server rejects them with:

  x-kubernetes-validations[1].rule: Invalid value: \"expression\":
  undefined field 'value'

Root cause: upjet emits a has(self.forProvider.value) CEL rule for the
required 'value' field, but that field uses SchemaTypeDynamic (maps to
x-kubernetes-preserve-unknown-fields: true — no type). CEL cannot
reference typeless fields, so the CRD is rejected before it is created.

Fixed in wildbitca/upjet v2.2.3: addParameterField now skips CEL rule
generation for SchemaTypeDynamic fields. Bumping the replace directive
and regenerating removes the broken rule from the settings CRD."

git push origin fix/settings-crd-cel-upjet-bump
gh pr create \
  --repo wildbitca/provider-upjet-cloudflare \
  --base main \
  --title "fix(zone): bump upjet to v2.2.3 — fixes settings CRD CEL install failure"
```

---

## Bug Description (for PR bodies)

### Summary

The `settings.zone.upjet-cloudflare.upbound.io` and `settings.zone.upjet-cloudflare.m.upbound.io` CRDs fail to install on Kubernetes clusters that enforce CEL validation (≥ v1.25). The Kubernetes API server rejects both CRDs with:

```
x-kubernetes-validations[1].rule: Invalid value: "expression": undefined field 'value'
```

This affects provider-cloudflare-zone at least through v0.2.6 (the latest available as of May 2026).

### Root Cause

The upjet code generator emits a spec-level `x-kubernetes-validations` rule to enforce that `value` is required when the management policy allows Create or Update:

```yaml
x-kubernetes-validations:
  - rule: >-
      !('*' in self.managementPolicies || 'Create' in self.managementPolicies ||
      'Update' in self.managementPolicies) || has(self.forProvider.value) ||
      (has(self.initProvider) && has(self.initProvider.value))
    message: spec.forProvider.value is a required parameter
```

However, the `value` field in `forProvider` has no `type` — only `x-kubernetes-preserve-unknown-fields: true` — because the Cloudflare Terraform `cloudflare_zone_setting` resource uses a dynamic value type (it can be a string, integer, or object depending on which zone setting is being managed):

```yaml
forProvider:
  properties:
    value:
      description: >-
        (Dynamic) Current value of the zone setting.
        Current value of the zone setting.
      x-kubernetes-preserve-unknown-fields: true
```

The Kubernetes CEL static type environment [excludes fields without an explicit `type`](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules) from the type-checking scope. When the API server compiles the CEL expression `has(self.forProvider.value)`, it cannot resolve `value` in the type environment, which causes the compilation error `undefined field 'value'`.

The CRD is rejected before it is ever created, so `settings` resources cannot be managed regardless of the provider revision status.

### Steps to Reproduce

1. Install `provider-cloudflare-zone` (any version through v0.2.6) on a Kubernetes cluster ≥ v1.25.
2. Wait for the provider to attempt CRD installation.
3. Observe `ManagedResourceDefinition` objects `settings.zone.upjet-cloudflare.upbound.io` and `settings.zone.upjet-cloudflare.m.upbound.io` stuck at `Established: False`.
4. Inspect provider revision events for:
   ```
   cannot apply CustomResourceDefinition: CustomResourceDefinition.apiextensions.k8s.io "settings.zone.upjet-cloudflare.upbound.io" is invalid:
   spec.versions[0].schema.openAPIV3Schema.properties[spec].x-kubernetes-validations[1].rule:
   Invalid value: "expression": undefined field 'value'
   ```

### Expected Behaviour

Both `settings` CRDs install successfully and `Established: True`.

### Actual Behaviour

Both `settings` CRDs fail to install. `Established: False` indefinitely.

### Environment

| Component | Version |
|---|---|
| provider-cloudflare-zone | v0.2.6 (also v0.2.1) |
| provider-family-cloudflare | v0.2.6 |
| Crossplane | (any version that installs MRDs) |
| Kubernetes | ≥ v1.25 (any version with CEL CRD validation) |

### Workaround

None available within the provider configuration. The `Settings` resource type cannot be used until the CRD installs successfully. If your use case does not require managing Cloudflare zone settings via this provider, the broken MRD is harmless — all other CRDs from `provider-cloudflare-zone` install and operate correctly.


## PR Description

> (paste as the PR body when opening the pull request)

The `settings` CRDs (`settings.zone.upjet-cloudflare.upbound.io` and `settings.zone.upjet-cloudflare.m.upbound.io`) fail to install on any Kubernetes cluster ≥ v1.25 because of a CEL validation rule that references a typeless field.

**Root cause:** upjet generates a spec-level `x-kubernetes-validations` rule — `has(self.forProvider.value)` — to enforce that `value` is required. However, `cloudflare_zone_setting.value` uses `DynamicPseudoType` in the Cloudflare Terraform provider (since zone settings can be a string, integer, or object depending on the setting ID). Upjet maps this to `x-kubernetes-preserve-unknown-fields: true` with no explicit `type`. The Kubernetes CEL static type environment excludes typeless fields, so the API server rejects the CRD with:

```
x-kubernetes-validations[1].rule: Invalid value: "expression": undefined field 'value'
```

**Fix:** Override the `value` field in the `cloudflare_zone_setting` resource configurator to `Required = false, Optional = true`. Upjet skips CEL required-field rule generation for Optional fields, allowing the CRD to install. The field is still a meaningful attribute — users must supply it — but the enforcement moves from CEL to Crossplane's management-policy admission layer rather than CRD-level compilation.

---

## Files to Change

Two files — cluster and namespaced variants share the same structure:

| File | Change |
|---|---|
| `config/cluster/zone/config.go` | Add schema override to `cloudflare_zone_setting` configurator |
| `config/namespaced/zone/config.go` | Same change (mirror of cluster variant) |

---

## Exact Code Changes

### `config/cluster/zone/config.go`

**Current** (lines ~26–30):
```go
	p.AddResourceConfigurator("cloudflare_zone_setting", func(r *config.Resource) {
		r.LateInitializer = config.LateInitializer{
			IgnoredFields: []string{"modified_on"},
		}
	})
```

**After:**
```go
	p.AddResourceConfigurator("cloudflare_zone_setting", func(r *config.Resource) {
		r.LateInitializer = config.LateInitializer{
			IgnoredFields: []string{"modified_on"},
		}
		// cloudflare_zone_setting.value is DynamicPseudoType — its zone-setting
		// value can be a string, integer, or object depending on setting_id.
		// Upjet maps DynamicPseudoType to x-kubernetes-preserve-unknown-fields:true
		// (no explicit type). Kubernetes CEL cannot reference typeless fields, so
		// the upjet-generated has(self.forProvider.value) required-field rule
		// causes both settings CRDs to be rejected by the API server on install.
		// Marking Optional=true/Required=false suppresses CEL rule generation for
		// this field while keeping the field usable in managed resources.
		r.TerraformResource.Schema["value"].Required = false
		r.TerraformResource.Schema["value"].Optional = true
	})
```

Apply the **identical change** to `config/namespaced/zone/config.go`.

---

## Steps to Fork, Fix, Build, and Submit

### 1. Fork and clone

```bash
gh repo fork wildbitca/provider-upjet-cloudflare --clone --remote
cd provider-upjet-cloudflare
git checkout -b fix/zone-setting-cel-value-field
```

### 2. Set up the build environment

```bash
# Install Go submodules (upjet fork and provider submodules)
make submodules

# Install goimports (required by generate)
go install golang.org/x/tools/cmd/goimports@latest
export PATH="$(go env GOPATH)/bin:$PATH"
```

### 3. Apply the fix

Edit `config/cluster/zone/config.go` and `config/namespaced/zone/config.go` as shown above.

### 4. Regenerate CRD schemas

```bash
make generate
```

This rewrites the generated files under `apis/` and `package/`. Verify that `apis/zone/v1alpha1/zz_setting_types.go` no longer contains the `has(self.forProvider.value)` CEL rule in its `x-kubernetes-validations` block.

```bash
grep -n "has(self.forProvider.value)" apis/zone/v1alpha1/zz_setting_types.go
# Expected: no output
grep -n "x-kubernetes-preserve-unknown-fields" apis/zone/v1alpha1/zz_setting_types.go
# Expected: still present (the field schema itself is unchanged)
```

### 5. Build the provider packages

```bash
make build.family FAMILY_SUBPACKAGES="config zone"
```

### 6. Test locally (optional but recommended)

Apply the generated CRD directly to a test cluster and confirm it installs:

```bash
kubectl apply -f package/crds/zone.upjet-cloudflare.upbound.io_settings.yaml --dry-run=server
# Expected: no error
```

### 7. Commit and push

```bash
git add config/cluster/zone/config.go config/namespaced/zone/config.go
git add apis/zone/     # regenerated types
git add package/crds/  # regenerated CRD YAML
git commit -m "fix(zone): mark cloudflare_zone_setting value as Optional to fix CEL CRD install failure

cloudflare_zone_setting.value uses DynamicPseudoType (the setting value
can be a string, integer, or object depending on setting_id). Upjet maps
DynamicPseudoType to x-kubernetes-preserve-unknown-fields: true with no
explicit type. Kubernetes CEL excludes typeless fields from its static
type environment, so the upjet-generated has(self.forProvider.value)
required-field rule causes both settings CRDs to be rejected by the API
server on installation (Established: False indefinitely).

Marking value as Optional=true/Required=false in the resource configurator
suppresses CEL required-field rule generation for this field, allowing
both settings CRDs to install successfully."

git push origin fix/zone-setting-cel-value-field
```

### 8. Open the PR

```bash
gh pr create \
  --repo wildbitca/provider-upjet-cloudflare \
  --title "fix(zone): mark cloudflare_zone_setting value as Optional to fix CEL CRD install failure" \
  --body-file /path/to/pr-description.md \
  --base main
```

---

## Bug Description (for PR body)

### Summary

The `settings.zone.upjet-cloudflare.upbound.io` and `settings.zone.upjet-cloudflare.m.upbound.io` CRDs fail to install on Kubernetes clusters that enforce CEL validation (≥ v1.25). The Kubernetes API server rejects both CRDs with:

```
x-kubernetes-validations[1].rule: Invalid value: "expression": undefined field 'value'
```

This affects provider-cloudflare-zone at least through v0.2.6 (the latest available as of May 2026).

### Root Cause

The upjet code generator emits a spec-level `x-kubernetes-validations` rule to enforce that `value` is required when the management policy allows Create or Update:

```yaml
x-kubernetes-validations:
  - rule: >-
      !('*' in self.managementPolicies || 'Create' in self.managementPolicies ||
      'Update' in self.managementPolicies) || has(self.forProvider.value) ||
      (has(self.initProvider) && has(self.initProvider.value))
    message: spec.forProvider.value is a required parameter
```

However, the `value` field in `forProvider` has no `type` — only `x-kubernetes-preserve-unknown-fields: true` — because the Cloudflare Terraform `cloudflare_zone_setting` resource uses a dynamic value type (it can be a string, integer, or object depending on which zone setting is being managed):

```yaml
forProvider:
  properties:
    value:
      description: >-
        (Dynamic) Current value of the zone setting.
        Current value of the zone setting.
      x-kubernetes-preserve-unknown-fields: true
```

The Kubernetes CEL static type environment [excludes fields without an explicit `type`](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules) from the type-checking scope. When the API server compiles the CEL expression `has(self.forProvider.value)`, it cannot resolve `value` in the type environment, which causes the compilation error `undefined field 'value'`.

The CRD is rejected before it is ever created, so `settings` resources cannot be managed regardless of the provider revision status.

### Steps to Reproduce

1. Install `provider-cloudflare-zone` (any version through v0.2.6) on a Kubernetes cluster ≥ v1.25.
2. Wait for the provider to attempt CRD installation.
3. Observe `ManagedResourceDefinition` objects `settings.zone.upjet-cloudflare.upbound.io` and `settings.zone.upjet-cloudflare.m.upbound.io` stuck at `Established: False`.
4. Inspect provider revision events for:
   ```
   cannot apply CustomResourceDefinition: CustomResourceDefinition.apiextensions.k8s.io "settings.zone.upjet-cloudflare.upbound.io" is invalid:
   spec.versions[0].schema.openAPIV3Schema.properties[spec].x-kubernetes-validations[1].rule:
   Invalid value: "expression": undefined field 'value'
   ```

### Expected Behaviour

Both `settings` CRDs install successfully and `Established: True`.

### Actual Behaviour

Both `settings` CRDs fail to install. `Established: False` indefinitely.

### Environment

| Component | Version |
|---|---|
| provider-cloudflare-zone | v0.2.6 (also v0.2.1) |
| provider-family-cloudflare | v0.2.6 |
| Crossplane | (any version that installs MRDs) |
| Kubernetes | ≥ v1.25 (any version with CEL CRD validation) |

### Workaround

None available within the provider configuration. The `Settings` resource type cannot be used until the CRD installs successfully. If your use case does not require managing Cloudflare zone settings via this provider, the broken MRD is harmless — all other CRDs from `provider-cloudflare-zone` install and operate correctly.

