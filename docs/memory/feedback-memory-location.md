---
name: memory-location-preference
description: Memory files for this project should be saved to docs/memory in the repo, not the default ~/.claude path
metadata:
  type: feedback
---

All memory for this project lives at `/Users/esten/src/estenrye/flux-platform-src/docs/memory/`, not the default `/Users/esten/.claude/projects/-Users-esten-src-estenrye-flux-platform-src/memory/`.

**Why:** User explicitly requested repo-local memory so it can be tracked with the project.

**How to apply:** When writing any memory file (user, feedback, project, reference), write to `docs/memory/` in the repo root. Update `docs/memory/MEMORY.md` as the index, not a `MEMORY.md` at the default path.
