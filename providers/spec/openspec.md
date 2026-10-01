---
capability: spec
provider: openspec
mcp: none
detect:
  files: [openspec, openspec/specs, openspec/changes]
  commands: [openspec]
requires: [node, openspec]
---

# OpenSpec — change proposals for large work

[OpenSpec](https://github.com/Fission-AI/OpenSpec) keeps current specs in `openspec/specs/` and each change as a proposal in `openspec/changes/<change>/`. teamwright uses it for the start of large work and replaces its `apply` step with the task lifecycle.

## Install

Source (checked 2026-09-30): [README](https://github.com/Fission-AI/OpenSpec#readme). Requires Node.js 20.19.0 or newer.

```bash
npm install -g @fission-ai/openspec@latest   # or: brew install openspec
openspec init                                 # in the repository root; choose Claude Code when asked
openspec list
```

`openspec init` creates `openspec/` and the agent's slash commands; the onboarding command asks before running it.

## Rules for agents

- **When:** a task is large (more than one seam or service, or product behaviour not settled) → it starts as an OpenSpec change. Small work skips OpenSpec.
- **Commands:** `/opsx:explore` to think it through, `/opsx:propose <idea>` to create `openspec/changes/<change>/` (`proposal.md`, `design.md`, `tasks.md`, spec deltas). CLI checks: `openspec list`, `openspec show <change>`, `openspec validate`.
- **Never run `/opsx:apply`.** Implementation goes through the teamwright lifecycle. Each item of the change's `tasks.md` becomes a `docs/tasks/T-NNN.md` record with `design_ref: openspec/changes/<change>/design.md#<section>` (or `proposal.md`).
- **Archive** (`/opsx:archive` or `openspec archive <change>`) only after every task created from the change is `DONE`; the orchestrator does it, not a role agent.
- **`openspec validate` fails:** fix the proposal before creating task records; a task must not point to an invalid change.
- **No `openspec` CLI or no `openspec/` directory:** write the spec as `docs/specs/<name>.md` and link it with `design_ref`; tell the orchestrator OpenSpec is missing.
