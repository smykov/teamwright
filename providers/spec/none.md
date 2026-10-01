---
capability: spec
provider: none
mcp: none
requires: []
---

# No spec tool — plain spec files

For projects that do not want a spec tool. Large work still gets a written spec before tasks; it is a plain Markdown file. With `tools.spec: none` the installer injects no tools block for this capability (the rule below is also in `docs/process/lifecycle.md`); this file documents the convention.

## Install

Nothing to install. `docs/specs/` is created with the first spec.

## Rules for agents

- **When:** a task is large (more than one seam or service, or product behaviour not settled) → write `docs/specs/<name>.md` first: problem, desired behaviour with a failure branch, decisions taken, open questions (linked to `docs/open-questions.md`), and a task breakdown.
- The owner reads and agrees the spec before task records are created. Each task links it: `design_ref: docs/specs/<name>.md#<section>`.
