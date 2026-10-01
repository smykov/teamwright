---
capability: spec
provider: spec-kit
mcp: none
detect:
  files: [.specify, .specify/memory/constitution.md]
  commands: [specify]
requires: [uv, specify]
---

# Spec Kit — specifications for large work

[GitHub Spec Kit](https://github.com/github/spec-kit) owns the start of large work: specify → clarify → plan → tasks. teamwright replaces its `implement` step with the task lifecycle.

## Install

Sources (checked 2026-09-30): [README](https://github.com/github/spec-kit#get-started), [existing-project guide](https://github.github.io/spec-kit/guides/existing-projects.html), [integration keys](https://github.github.io/spec-kit/reference/integrations.html).

Prerequisites: Python 3.11+ and [uv](https://docs.astral.sh/uv/getting-started/installation/).

```bash
uv tool install specify-cli
# in the repository root, on a clean working tree or a baseline branch:
specify init --here --force --integration claude
specify check
```

`--force` allows a non-empty directory and **may replace files at Spec Kit's managed paths** — the onboarding command asks before running it and shows `git status` afterwards. Init adds `.specify/` and the agent skill files; it does not touch application code or infer specs for existing behaviour.

After init, the constitution (`.specify/memory/constitution.md`) references `PRINCIPLES.md` instead of restating it (`docs/process/principles.md`).

## Rules for agents

- **When:** a task is large (more than one seam or service, or product behaviour not settled) → it starts in Spec Kit, not in a task record. Small work skips Spec Kit.
- **Commands** (agent skills, run in the chat one at a time, review each result): `/speckit-specify <what and why>` → `/speckit-clarify` → `/speckit-plan <stack and constraints>` → `/speckit-tasks`. Some integrations name them `/speckit.specify` etc.; use whichever the project's `.claude/` provides. `/speckit-analyze` is optional before `tasks`.
- **Never run `/speckit-implement` or `/speckit-converge`.** Implementation goes through the teamwright lifecycle.
- **Where the output lives:** one directory per feature under the Spec Kit specs directory (usually `specs/<NNN-feature>/` with `spec.md`, `plan.md`, `tasks.md`). Each item of `tasks.md` becomes a `docs/tasks/T-NNN.md` record with `design_ref: specs/<NNN-feature>/plan.md#<section>` (relative path + anchor).
- **Constitution:** `.specify/memory/constitution.md` points to `PRINCIPLES.md`; if it has to change, it changes in the same commit and with the same version as `PRINCIPLES.md`. Agents do not edit either.
- **No `specify` CLI or no `.specify/` directory:** do not improvise a spec format; write the spec as `docs/specs/<name>.md` (problem, behaviour, decisions, open questions) and link it with `design_ref`, and tell the orchestrator Spec Kit is missing.
