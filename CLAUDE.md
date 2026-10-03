# CLAUDE.md

Guidance for agents working on **teamwright itself** — the Claude Code plugin and the kit it installs. The files a user's project receives live in `template/`; this file is not one of them.

## Layout

- `skills/` — plugin commands (`/teamwright:adopt`, `init`, `requirements`, `flow`, `status`, `reconfigure`).
- `template/` — what gets installed into a project: `AGENTS.md`, role agents, hooks, docs templates, metrics CLI.
- `docs/process/` — process reference; copied into projects on install, linked from the role files.
- `providers/<capability>/<provider>.md` — tool adapters rendered into `AGENTS.md` and the role files.
- `scripts/` — installer (`tw-install.py`), router (`tw-next.py`), release check.
- `tests/` — regression tests in throwaway git repos (`tests/run.sh`).
- `examples/` — the offline demo (`make demo`, run by `tests/test-demo.sh`) and its recorder.
- `docs/design-decisions.md` — why the kit is shaped the way it is; `docs/usage.md` — user guide; `CONTRIBUTING.md` — the same rules for people.

## Checks

Run before every commit: `make test`, `make lint`, `make scan`. Before tagging: `make release-check`.

## Rules

- A change to a hook, the installer or the router comes with a test that fails without it.
- Everything here reads as published: no hosts, IPs, absolute paths, names of real projects, clients or people, no secrets. Examples are generic.
- User-facing files are in English.
- Anything that changes what the plugin ships (`skills/`, `scripts/`, `template/`, `providers/`, `docs/process/`) bumps `version` in `.claude-plugin/plugin.json` and `marketplace.json` together and gets a `CHANGELOG.md` entry.
- The process stays fixed, tools stay pluggable: no hook may depend on a specific tool.
- `template/docs/failures.md` ships empty — incidents belong to the project that has them.
- Metrics come from git and logs, never from an agent's self-report.
