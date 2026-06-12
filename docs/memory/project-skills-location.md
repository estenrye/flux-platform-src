---
name: project-skills-location
description: Claude Code skills for this project live in .claude/skills/ in the repo, not ~/.claude/skills/
metadata:
  type: project
---

Project skills live at `.claude/skills/` in this repo, not the default `~/.claude/skills/`. This keeps skills version-controlled with the project.

**Why:** User wants skills tracked in git alongside the code they support.

**How to apply:** When writing or referencing a skill for this project, use `.claude/skills/<skill-name>/SKILL.md` (or `.claude/skills/<skill-name>.md` for flat files). Do not place project skills in `~/.claude/skills/`.

See also: [[feedback-memory-location]] for the same pattern applied to memory.
