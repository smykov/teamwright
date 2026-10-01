# Changelog

All notable changes to teamwright. Versions follow [semantic versioning](https://semver.org/); while in 0.x, a minor version may change behaviour. `/plugin update` compares the `version` in `.claude-plugin/plugin.json`, so every change to what the plugin ships comes with a bump here (`make release-check`).

## [0.3.1] - 2026-10-01

### Fixed
- Hooks and `tw-run` work under bash 3.2 (the macOS default): embedded Python is read into a variable instead of a heredoc inside `$(...)`, which bash 3.2 misparsed. `make lint` rejects the old pattern.

### Changed
- CI: every job has a time limit; a Linux job runs the tests under bash 3.2 in a container.
- Author named in `LICENSE` and the plugin manifests; manifests link the repository.
- CI: the kit's own secret scan uses a root `.gitleaks.toml` that extends the shipped config and allowlists the synthetic secrets in `tests/`; `actions/checkout@v5`.
- Docs: install commands point to `smykov/teamwright`; maintainer guide (`CLAUDE.md`) in English; design rationale in `docs/design-decisions.md`; internal build plan removed.

## [0.3.0] - 2026-10-01

Fixes from re-adopting an existing project and running the first `/teamwright:flow` on it.

### Changed
- `/teamwright:flow`: role agents run in the foreground and the orchestrator never ends its turn while one is running; after every role result the record and status change are committed and the router is re-run; every turn ends with the end-of-session block, its `Outcome: barrier|idle|escalate|interrupted` line last, in plain text.
- `/teamwright:flow` checks at start that the configured context/docs MCP tools are connected and falls back to built-in search with a note when they are not.
- `/teamwright:adopt`: `check-commands` runs in the foreground with no edits meanwhile; the "Next steps" order and the offered task come from `tw-next.py`, never a separate ranking; Next steps names MCP servers that need a restart; blocking open questions go into `blocked_on`.
- `tw-next.py`: a ready task inherits the highest priority of the open tasks that depend on it (transitively), and the reason says so; ties are broken by how many open tasks it unblocks, then id (as `lifecycle.md` already specified).
- `tw-next.py`: a `TODO` with a non-empty `blocked_on` is not ready; `blocked_on: OQ-NN` holds until the question is `answered` or `dropped` in `docs/open-questions.md`. New `warnings`: a task that mentions an unresolved `OQ-NN` with an empty `blocked_on`, and a `blocked_on` naming only answered questions.
- `check-commands`: only tracked changes inside the area's `workdir` fail a command; changes elsewhere during the run are a note. Environment errors (service not reachable, Docker unavailable, missing binary, no device) are `not-runnable` with the reason instead of `fail` (heuristics in `docs/process/plugin.md`).

### Fixed
- `journal.sh`: when the runtime does not pass `last_assistant_message`, the outcome is read from the last assistant text in the transcript (`outcome_source` records where it came from); a `SubagentStop` without `agent_type` takes it from that agent's own tool-call lines.
- Plugin version: `plugin.json` said 0.1.0 while 0.2 was shipped, so `/plugin update` from a git marketplace reported "already at latest version".

### Added
- `CHANGELOG.md`, `make release-check` (bump rule vs the last `v*` tag), and a lint check that `plugin.json`, `marketplace.json` and the changelog agree on the version.

## [0.2.0] - 2026-10-01

Shipped with `plugin.json` still at 0.1.0.

### Added
- `scripts/tw-run` toolchain runner (host or Docker, by default the CI's image) and `tw-install.py check-commands`.
- `/teamwright:flow` with the deterministic router `scripts/tw-next.py`.
- `/teamwright:adopt`: product goal, toolchain step, commands checked after apply, `ui_verify` rule, Next steps.
- Config changes at any time through `.teamwright/config.next.yml` and `apply --config`; `apply --accept` for hand-merged files.
- Secret scan finding classes; inventory reads versions from manifests and reports unfilled docs.

### Changed
- State guard blocks only real writes to teamwright's own state.

## [0.1.0] - 2026-10-01

### Added
- First plugin release: `/teamwright:adopt`, `/teamwright:init`, `/teamwright:reconfigure`, `/teamwright:status`; installer `tw-install.py`; provider adapters; gates as Claude Code hooks and git hooks; role agents; metrics CLI.
