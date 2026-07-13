---
name: sops-creation-rule-input-path
description: sops -e matches creation_rules against the plaintext INPUT path, so temp-file encryption silently picks the wrong rule
metadata:
  type: feedback
---

`sops -e tempfile > target.sops.yaml` matches `.sops.yaml` creation rules
against the plaintext INPUT path (and discovers `.sops.yaml` upward from the
cwd), not the output filename.

**Why:** In this repo the fallback rule `path_regex: .*\.yaml` with
`encrypted_regex: ^(data|stringData)$` matches any temp file, so encrypting
Talos machine secrets (which have no data/stringData keys) via a temp file
produces a file that LOOKS sops-managed but is ~entirely plaintext. Caught
during M1 ([[m1-implementation-status]]).

**How to apply:** When encrypting whole files scripted from temp paths, bypass
rule discovery: `sops --config /dev/null -e --age <recipients>`, and assert
`grep -q 'ENC\['` on the output before writing it into the repo. File
extension also matters: sops infers the store type from it (`.test` suffix
breaks YAML detection).
