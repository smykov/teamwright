# Changelog

All notable changes to teamwright. Versions follow [semantic versioning](https://semver.org/); while in 0.x, a minor version may change behaviour. `/plugin update` compares the `version` in `.claude-plugin/plugin.json`, so every change to what the plugin ships comes with a bump here (`make release-check`).

## [0.3.3] - 2026-10-01

Fixes from a documentation coverage audit and a practices review: the docs now say what the code does.

### Fixed
- Review gate: after two `REQUEST_CHANGES` rounds in a row, the third review record may only be `ESCALATE` or `REJECT_RECURRENCE`. It used to refuse only a third `REQUEST_CHANGES` and allowed `APPROVE`, contrary to `lifecycle.md`, the reviewer role and the README. Send-backs are counted per run: an `APPROVE` or `ESCALATE` ends it, so a task back from `VERIFY_FAIL` or an owner decision starts a new count.
- rca analysis contract: the gate requires `root_cause`, `evidence`, `decision` for a `type: rca` task, but `lifecycle.md`, the problem-investigator's output block and the task template described the five feature fields, so an rca task filled per instructions could not enter `IN_PROGRESS`. The template carries a commented rca block, the investigator shows both blocks, and a test fills every documented block as written and passes the gate. `developer.md` no longer says three fields suffice for a feature.
- Analysis gate exit text and `gates.md`: a root cause that cannot be proven yet goes to `BLOCKED` with `blocked_on`, as the lifecycle diagram says (was: stay `TODO`).

### Changed
- Tiers match the code: P-001 T1+T3 (analysis gate), P-003 T1+T3, P-004 T1 (no hook runs the gate), P-008 T0 (the journal records facts, nothing warns), P-009 T1+T3 with CI only if the project adds it, patch guard T2 everywhere. `gates.md` and the README state that Claude Code gate tiers apply in `enforce` mode.
- The undefined "validator module" is gone: the task-validator writes the verify record the verify gate checks, and the orchestrator acts on its acceptance verdict (`FAIL` → `IN_PROGRESS`, `NEEDS_OWNER` → owner).
- Lifecycle: sprints defined (active sprint, who opens and closes it; the sprint template no longer copies statuses); `class`, `implemented_by` (set by the orchestrator at `→ NEEDS_REVIEW`) and `review` in the field table; missing transitions on the diagram; how rca exits (b) and (c) reach `DONE`; `depends_on` is ready when `VERIFIED` or `DONE`, as the router computes.
- Installed projects stand alone: the `CLAUDE.md` template points to `AGENTS.md` and `docs/process/`; `AGENTS.md` and every role file point to `gates.md` for refusals and mention `TEAMWRIGHT_PAUSE`; installed docs use project paths and name `tw-install.py` / `tw-next.py` as plugin scripts.
- Consistency: test-writer runs after `ANALYSIS → IN_PROGRESS` and asks for characterization tests; `enforce` is run or approved by the owner, lowering is owner-only outside Claude Code; the `CLAUDE.md` budget is the hook's 40 KB; `gates.md` lists every environment variable the hooks read and explains patch-guard vs metrics areas; `decisions.md` has Task and Decided by columns; open-question status words match the router.
- README: a Practices section, links from "What gets installed" to the template files, adapter links in Tools, a Commands table, more Known limitations; `docs/README.md` indexes the documentation.
- `make lint` checks that relative links and anchors in all Markdown resolve (`scripts/check-links.py`).

## [0.3.2] - 2026-10-01

### Fixed
- `commit-msg`: no "preferred subject" note for a new task committed as `chore(task): T-001 →TODO` (no FROM status, as documented), or for templates in `docs/tasks/_*.md`.

### Added
- `examples/demo.sh` (`make demo`): an offline walkthrough that installs the kit into a throwaway repository and moves one task through the analysis, review and verify gates, printing each gate decision, then runs the metrics. `tests/test-demo.sh` runs it in `make test`.
- `docs/assets/demo.gif`, recorded from the demo with `examples/make-cast.py` and agg.
- `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue and pull request templates.

### Changed
- README rewritten for a first read: what it is, quickstart, a short lifecycle diagram, real demo output instead of a sample from an empty repository, a first-day walkthrough and a glossary. Onboarding, gate modes, the flow router, runners, configuration, updating and manual install moved to `docs/usage.md`.
- `docs/process/plugin.md` is the installer and config reference only; how the kit is checked, released and extended, and the plugin facts it relies on, moved to `CONTRIBUTING.md`.

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
