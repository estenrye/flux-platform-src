# Upstream PR Plan — Cloudflare `settings` CRD CEL Validation Bug

Date: May 31, 2026
Chat ID: 00010
Status: Draft

**Repository:** https://github.com/wildbitca/provider-upjet-cloudflare  
**PRs disabled:** No — PRs are open; Issues are disabled. Submit via Pull Request.  
**Root fix location:** `github.com/wildbitca/upjet` (forked upjet library), not the provider itself.  
**Two PRs required:** fix upjet first, then bump provider dependency and regenerate.

---

## Why making `value` optional is wrong

`cloudflare_zone_setting.value` is semantically required. The failure is not field optionality; the failure is CEL compilation against a typeless schema field. Marking it optional in provider config hides the symptom but changes the contract incorrectly.

---

## Root cause

In `wildbitca/upjet/pkg/types/builder.go`:

1. `SchemaTypeDynamic` fields are correctly rendered as `x-kubernetes-preserve-unknown-fields: true` (no explicit OpenAPI `type`).
2. `addParameterField` still appends dynamic fields into `topLevelRequiredParams`.
3. `AddToBuilder` emits `has(self.forProvider.value)` CEL required-field rules for those entries.
4. Kubernetes CEL static typing excludes typeless fields, so CRD compilation fails with `undefined field 'value'`.

Result: `settings.zone.upjet-cloudflare.upbound.io` and `settings.zone.upjet-cloudflare.m.upbound.io` fail with `Established: False`.

Reference: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules

---

## Correct fix

Patch `wildbitca/upjet` so dynamic fields are excluded from top-level CEL required-field rule generation.

### File

`pkg/types/builder.go` (`addParameterField`)

### Change

```go
if requiredBySchema && !f.Identifier && len(f.CanonicalPaths) == 1 {
    requiredBySchema = false
    // Dynamic fields map to x-kubernetes-preserve-unknown-fields: true (no type).
    // CEL cannot type-check references to typeless fields, so do not emit
    // has(self.forProvider.<field>) required-field rules for them.
    if f.Schema.Type != conversiontfjson.SchemaTypeDynamic {
        r.topLevelRequiredParams = append(r.topLevelRequiredParams,
            newTopLevelRequiredParam(f.TransformedName, !f.TFTag.AlwaysOmitted()))
    }
}
```

---

## PR 1 — `wildbitca/upjet`

**Title:** `fix: skip CEL required-field rule for SchemaTypeDynamic fields`

```bash
gh repo fork wildbitca/upjet --clone --remote
cd upjet
git checkout -b fix/cel-skip-dynamic-required-rule

# apply patch in pkg/types/builder.go
go build ./...
go test ./...

git add pkg/types/builder.go
git commit -m "fix: skip CEL required-field rule for SchemaTypeDynamic fields

SchemaTypeDynamic maps to x-kubernetes-preserve-unknown-fields:true with no
explicit OpenAPI type. CEL cannot statically type-check typeless fields, so
emitting has(self.forProvider.<field>) for dynamic fields causes CRD install
failure with 'undefined field'.

Guard topLevelRequiredParams generation in addParameterField to skip
SchemaTypeDynamic fields."

git push origin fix/cel-skip-dynamic-required-rule
gh pr create --repo wildbitca/upjet --base main --title "fix: skip CEL required-field rule for SchemaTypeDynamic fields"
```

After merge, tag release: `v2.2.3`.

---

## PR 2 — `wildbitca/provider-upjet-cloudflare`

**Title:** `fix(zone): bump upjet to v2.2.3 and regenerate settings CRD`

```bash
gh repo fork wildbitca/provider-upjet-cloudflare --clone --remote
cd provider-upjet-cloudflare
git checkout -b fix/settings-crd-cel-upjet-bump

# Update go.mod replace to v2.2.3
sed -i '' 's|github.com/wildbitca/upjet/v2 v2.2.2|github.com/wildbitca/upjet/v2 v2.2.3|' go.mod
go mod tidy

make submodules
make generate

# Verify broken CEL rule is removed
grep -c "has(self.forProvider.value)" apis/zone/v1alpha1/zz_setting_types.go
# expected: 0

# Validate CRD against API server
kubectl apply -f package/crds/zone.upjet-cloudflare.upbound.io_settings.yaml --dry-run=server
# expected: no error

git add go.mod go.sum
git add apis/zone/
git add package/crds/
git commit -m "fix(zone): bump upjet to v2.2.3 and regenerate settings CRD

Brings in upjet fix that skips CEL required-field rule generation for
SchemaTypeDynamic fields, removing invalid has(self.forProvider.value)
from settings CRDs and allowing CRD installation on Kubernetes >= 1.25."

git push origin fix/settings-crd-cel-upjet-bump
gh pr create --repo wildbitca/provider-upjet-cloudflare --base main --title "fix(zone): bump upjet to v2.2.3 and regenerate settings CRD"
```

---

## Bug description text (for PR body)

### Summary

`settings.zone.upjet-cloudflare.upbound.io` and `settings.zone.upjet-cloudflare.m.upbound.io` fail CRD installation on Kubernetes versions with CEL CRD validation (v1.25+), with:

```text
x-kubernetes-validations[1].rule: Invalid value: "expression": undefined field 'value'
```

### Root cause

The generated CRD emits `has(self.forProvider.value)` while `forProvider.value` is typeless (`x-kubernetes-preserve-unknown-fields: true`) due to Terraform dynamic typing. CEL static typing cannot resolve typeless fields.

### Expected

Both settings CRDs install and become `Established: True`.

### Actual

Both settings CRDs are rejected and remain `Established: False`.

### Affected versions

- `provider-cloudflare-zone`: v0.2.1 through v0.2.6
- `provider-family-cloudflare`: v0.2.6 (bundle includes affected zone package)

### Workaround

No reliable in-provider workaround. If `Setting` resources are unused, the failure is benign noise; other Cloudflare CRDs still install.
