# Documentation

Start with the [README](../README.md): what the kit does, the quickstart and the first day.

## Using the kit

- [usage.md](usage.md) — onboarding with `/teamwright:adopt` and `/teamwright:init` (requirements first, with `/teamwright:requirements`), gate modes, `/teamwright:flow`, Docker runners, configuration changes, updating, manual install, metrics.
- [design-decisions.md](design-decisions.md) — why the kit is shaped the way it is.
- [Commands](../README.md#commands) — the six skills, each linked to its `SKILL.md`.
- [providers/](../providers/) — one adapter per tool: what the agents are told about Spec Kit, Serena, Context7, Playwright and the alternatives ([tools.md](process/tools.md) explains the capabilities).
- [examples/](../examples/README.md) — the offline demo.

## The process reference

`docs/process/` is copied into every project that installs the kit, except `plugin.md`, which describes the kit itself. Reading order:

1. [lifecycle.md](process/lifecycle.md) — the task record, statuses and transitions, readiness, recurrence exits, verification, sprints.
2. [gates.md](process/gates.md) — what each hook checks, its deliberate exits, environment variables, known limitations.
3. [roles.md](process/roles.md) — who does what, and why each boundary exists.
4. [sessions.md](process/sessions.md) — session types, the outcome contract, batching, when to stop and ask.
5. [principles.md](process/principles.md) — enforcement tiers and how principles are amended.
6. [metrics.md](process/metrics.md) — what is measured, from which source, and the known biases.
7. [tools.md](process/tools.md) — tool capabilities, providers and toolchain runners.

Kit only: [plugin.md](process/plugin.md) — installer commands, the config schema, the flow router's rules.

The files installed into a project start from [`template/`](../template/): `AGENTS.md`, `CLAUDE.md`, `PRINCIPLES.md`, role files in `.claude/agents/`, hooks in `scripts/hooks/`, and templates in `docs/`.

## Contributing

[CONTRIBUTING.md](../CONTRIBUTING.md) — how the kit is checked and released · [SECURITY.md](../SECURITY.md) · [CHANGELOG.md](../CHANGELOG.md)
