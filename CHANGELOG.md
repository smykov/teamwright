# Changelog

All notable changes to teamwright. Versions follow [semantic versioning](https://semver.org/); while in 0.x, a minor version may change behaviour. `/plugin update` compares the `version` in `.claude-plugin/plugin.json`, so every change to what the plugin ships comes with a bump here (`make release-check`).

## [0.6.0] - 2026-10-05

The pipeline stays fixed; its steps get parameters the owner sets per project, and the process gets a way to measure and improve itself. From the first long pilot: 46 % of review rounds were send-backs, 127 of 192 findings were Low; the context tool was configured but did not index the main language, and nothing said so.

### Added
- **Process settings** — `process:` in `.teamwright/config.yml`, a closed list: `review.blocking` (`low` | `medium` | `high`), `batch.max_tasks` and `batch.by_priority` (tasks per flow pass, capped per priority), `autonomy.start` (`ask` | `auto`) and `autonomy.continue`. Missing keys keep the earlier behaviour. The installer validates them and renders them into `AGENTS.md` and `code-reviewer.md` (`{{REVIEW_BLOCKING}}` …).
- Review gate: with `review.blocking` set, `APPROVE` with a blocking finding and `REQUEST_CHANGES` without one are refused; the record's findings table gains a Category column. Critical and `secret-leak`, `security`, `weakened-test`, `done-not-working`, `recurrence` block at any threshold. Findings below it are collected by the flow into one `review-follow-up` task per sprint.
- Router: `tw-next.py --pass <ids>` applies the pass cap (`budget`, new action `stop`); `autonomy.start: auto` clears `ask_owner` on `start`; output carries `settings`.
- `/teamwright:flow`: with `autonomy.continue: true` the pass goes on after a barrier and asks push once, at the end of the pass.
- `/teamwright:settings` — show and change the settings through `config.next.yml` + `apply`, with the data behind each choice; adopt and init ask once.
- `/teamwright:status` shows the settings and checks the context tool: languages indexed against each area's languages (`.serena/project.yml`), and the share of code reading through the tool per role from the journal (`scripts/tw-context.py`).
- `/teamwright:improve` — process review from git, records and journals (`scripts/tw-process.py`: findings by severity and category under the threshold in force, verdicts, settings history, `tail_code: ratified`, bookkeeping share, record sizes, open follow-ups; `teamwright-metrics --split-date` at the last settings change); proposals routed to a setting, a project rule, a task, or feedback; report in `docs/process-reviews/<date>.md`.
- `/teamwright:feedback` — an issue through the repository's forms (`gh`, or a pre-filled link) or a pull request from a fork, anonymised, after the owner reads it; duplicates checked first.
- `/teamwright:progress` reports open follow-ups.

### Changed
- `docs/process/sessions.md` §3 "Batching" is now "Passes": the cap comes from the settings and is checked by the router; P1 tasks may share a pass when the owner allows it. Tasks of a pass still run one after another in one working tree.

## [0.5.1] - 2026-10-05

From the first long pilot (4 days, 585 commits, 70 reviews, 33 tasks closed): fixes for false positives and one disk-filling instruction.

### Fixed
- pre-push (DRAIN): a commit that touches only `docs/**`, `specs/**` or `openspec/**` ships no code and belongs to no task (before, only `docs/tasks/**` did): recording a decision or a spec that names a TODO task no longer needs `tail_code: ratified`. `TEAMWRIGHT_DOC_PATHS_RE` overrides the pattern.
- Analysis gate: appending to a task file through the shell (`>>`, `tee -a`) is allowed — an appended note lands after the front matter and cannot change the status. Overwriting (`>`, `tee`, `sed -i`) is still denied.
- patch-guard: a file the commit creates is not inspected; a list in a new file is its content, not "one more case".
- task-validator: mutations run in a `git worktree` of the committed revision, inside one script whose `trap` removes it (`git worktree remove --force`, then `rmdir`), never in a `cp -a` copy that dragged build output and caches along (one filled a disk at 2.4 GB) and that the agent could not delete (`rm -rf` is denied). Uncommitted task changes → the validator stops and reports.
- `/teamwright:flow`: a role the runtime started in the background is waited for with one blocking wait; with none available the turn ends with a "waiting for" line (journaled `waiting`) and the completion notification resumes it — no polling loops or `sleep`.

### Changed
- init and adopt propose `paths-ignore: ["docs/tasks/**"]` on the CI `push` trigger: task bookkeeping no longer runs the full CI.

## [0.5.0] - 2026-10-05

A progress report for the owner. Projects already kept their own progress commands, each tied to how that repository stores tasks; the generic report counts teamwright's records, and an adaptation step fits it to the rest.

### Added
- `/teamwright:progress` and `scripts/tw-progress.py` (read-only): tasks done by status, sprint (goal, pending forks), plan stage (by FR-NN; FRs without tasks listed) and area (by the directory `analysis.seam` names, longest first; unmatched tasks listed, never guessed), in percent; in-flight work, the router's next action and ready queue, owner decisions, open questions, risks (VERIFY_FAIL, open rca, recurrences, two or more review rounds), git state. `--gate` runs every configured command.
- Per-project adaptation: `.teamwright/progress.json` (per-task `areas`, `area_rules`, a `milestone` of plan stages, an `extra_command` for work kept outside task records) and `.teamwright/progress.md` (what the project adds to the report). `/teamwright:progress --adapt` writes them from what the repository has — an earlier progress command, a spec tool's task lists; adopt (inventory and step 15) and init (sprint 1) run the same step.

## [0.4.5] - 2026-10-03

From the first live init: the project was cloned on a second machine and `/teamwright:flow` did not exist there — the plugin and `core.hooksPath` live on the machine, not in the repository, and nothing said so.

### Added
- Install enables the plugin in `.claude/settings.json` (`enabledPlugins`) and names its marketplace (`extraKnownMarketplaces`), so Claude Code offers both when a fresh clone is trusted. The source is the GitHub/git/URL source Claude Code already knows, or the `origin` of a local checkout with its non-default branch; a remote with credentials is never written; existing entries are kept.
- `.teamwright/installed.json` records the installing plugin and version under `@kit` (plan action `kit-version`).
- `scripts/hooks/session-check.sh` (SessionStart, never blocks): reports a missing plugin, a plugin older or newer than `@kit`, and git hooks that are off, with the commands that fix each. `TEAMWRIGHT_SESSION_CHECK=0` turns it off.
- `docs/usage.md`: "Another machine or a fresh clone"; init and adopt reports say how a clone gets the plugin.

### Changed
- Tests run with their own `CLAUDE_CONFIG_DIR`, never the developer's plugin registry.

## [0.4.4] - 2026-10-02

Documentation: `/teamwright:init` is described as fully as `/teamwright:adopt` — the README quickstart and first day for both paths, the nine init steps in `docs/usage.md`, the glossary (requirements document, walking skeleton, validation record), two design decisions (requirements before the stack; acceptance as a record), the `kept-project` install action in `plugin.md`.

From a third pair of dry runs on 0.4.3: the roast economy worked — 47 owner questions in 18 exchanges without a brief (was 77 in 27) and 29 in 15 with one (was 61 in 21), two roast rounds each. The remaining friction:

### Fixed
- Round rules: the two-round cap overrides "another round after an accepted `Changes build: yes`"; after round 2 the owner's answer closes each remaining High, with a header that says so. A round is skipped when every `NOT_READY` cause was accepted verbatim with tag `no`. The reviewer knows the cap. An orphan record from an interrupted reviewer is removed and the round rerun.
- Section 9 has a **UI verification** row (template and reviewer table): a runner teamwright has an adapter for, or `none` with the reason. A runner without an adapter (a headless browser on the host) becomes `none` + `ui_verify_deferred` and a test task. `check-commands` notes a deferral whatever `ui_verify` is, and the `none` adapter no longer demands a runner task when the owner deferred UI verification.
- A check the install policy forbids is a decision, not a sprint-1 task nobody may finish; init does not re-ask what section 6 answered.
- `open-questions.md`: the status comment moved above the table, so new rows append cleanly.

### Changed
- Fewer exchanges: one commit consent per run; the section 9 block, the Highs and the Medium/Low batch of a round in one exchange; an interview proposal table confirmed as one question; tools proposed as one block that respects the install policy, single-provider capabilities stated; setup consents (scaffold, apply, enforce) as one block; all specs reviewed at once. No "copy to docs/sources?" for a text source already in the repository.
- init fills placeholders before the first `apply`, and commits the skeleton before `check-commands` so its "modifies tracked files" check sees something. The reviewer proposes one area per process or toolchain.

## [0.4.3] - 2026-10-02

From a second pair of dry runs on 0.4.2: nine of ten earlier init problems were gone, but the owner was asked more, not less (61 and 77 questions) — every Medium and Low finding was a separate decision, and accepted changes after `READY` triggered extra rounds.

### Changed
- Roast economy: Medium and Low findings go to the owner as one question ("accept all", "all except …", "go through them"). The reviewer tags each finding `Changes build: yes | no`; another round runs only after `NOT_READY` or an accepted `yes` finding, and checks the changed rows. At most two rounds without a Blocker. The header's `Roast:` names the version it was run on.
- The interview asks what may be installed on the dev machine, in CI and on the server; the reviewer gets that policy and the host's toolchain and proposes only a stack that can run here. It no longer decides task classification (`surface`).
- init: `ui_verify` follows section 9 when it decided UI verification; a tools choice that contradicts section 9 goes back to the owner. CI pins the deploy target's version. The gate is run once for the report. Chores state their own failure branch. `config.next.yml` keeps `mode: enforce` after enforce.

### Added
- `ui_verify_deferred: "<decision>"`: the owner's recorded decision to go without UI verification for now. `check-commands` notes the missing `e2e_ui_command` instead of failing, and UI tasks carry a `verify_exception` instead of depending on a runner task that cannot happen.

### Fixed
- `npx` refusing to download a missing package (`npx canceled due to missing packages`) is not runnable (environment), not a test failure. The Playwright adapter runs `npx --no playwright test` and asks before installing browsers.
- Patch guard no longer warns about files the installer wrote (`.teamwright/installed.json`) on the install commit.
- The requirements skill skips the "which document is the base" question when nothing was found, removes the templates' example rows, and accepts any source locator.

## [0.4.2] - 2026-10-02

Fixes from two dry runs: `/teamwright:init` on an empty repository and `/teamwright:requirements` on a short brief in another language. Both reached the end; these are the places where the agent had to guess.

### Fixed
- Requirements before install: the skill creates `docs/requirements.md`, `docs/open-questions.md` and `docs/decisions.md` from the kit, spawns the reviewer as a general-purpose agent with the role file when the type is not installed, and points it to the kit's process docs; missing inputs are skipped, not findings.
- The first roast could never be `READY`: section 9 is empty by design until the roast, yet the reviewer counted it as High. The reviewer now always proposes section 9 in its own table from round 1; a proposal is a question, not a finding. The record has slots for proposed technical decisions and scope against time.
- After `READY`: Medium and Low are accepted, declined or left open; only changes that do not alter what gets built go in without another round. The header records the roast and the source; source pointers stay as the trace.
- Reviewer weighting: a contradiction one clause fixes is High, not Blocker; `no failure branch: <reason>` is accepted for requirements that cannot visibly fail; findings are weighed against the stated constraints, and a Low open for two rounds becomes an open question.
- "Spawn in the foreground" replaced by "spawn and wait for its record" (the runtime may run agents in the background). Interview rounds group gaps by topic; fewer than three questions is fine; technical decisions are confirmed as one block.
- `apply` no longer reports a conflict for project documents written before install (`docs/requirements.md`, `open-questions.md`, `plan.md`, `architecture.md`, `decisions.md`): they are `kept-project`.
- `check-commands` reports each command's runner and duration, and a configured `ui_verify` with no `e2e_ui_command` as not runnable — it no longer lets a project into `enforce` with a UI runner that cannot run.
- `verify-gate.sh` is executable in the kit, like the other gates.

### Added
- `no_mcp: [capability, ...]` in the config: the tool is used without its MCP server, which is not added to `.mcp.json`. init asks about each MCP server separately.
- A task line `non-blocking: OQ-NN — <why>` stops the router's "mentions unresolved OQ" warning.
- Requirements template: a `Source:` header line; priority and release columns for non-functional requirements, so traceability covers them.
- init: lists the providers per capability; a path for a tool the owner declines to install (a sprint-1 task); generator and codegen only if the stack has them; CI for host runners; the owner reviews `none` specs; `architecture.md` and `decisions.md` filled; unresolved placeholders proposed through `config.next.yml`; T-001 while the UI runner is blocked; wider `allowed-tools` for both skills.

## [0.4.1] - 2026-10-02

Fixes from a code review of 0.3.4 and 0.4.0.

### Fixed
- Acceptance verdicts are records now, not lines in `## Validation`: `docs/tasks/<ID>.validation/<n>.md` with `verdict`, `commit` and `validator`, written only by task-validator through the verify gate (append-only, next round only, no shell writes, ledgered), template `docs/tasks/_validation-template.md`. A verdict counts only for the task's current code — the freshness rule of verify records. Before, an old `PASS` closed a task whose code had changed since; deleting a later `FAIL` brought an earlier `PASS` back; and formatting variants of the verdict line were silently missed.
- Router loop after an acceptance `FAIL`: the old `FAIL` stayed the latest verdict, so after the fix the router kept sending the task back to `IN_PROGRESS`. A verdict older than the task's last code commit is now stale, and the router asks task-validator for a new round.
- Freshness without a code commit naming the task: a record whose commit is not `HEAD` still counts when everything changed since is under `docs/tasks/` (the records themselves were committed after the check).
- `/teamwright:init` could not run `/teamwright:requirements`: the skill disabled model invocation. It is now invocable by the model.
- Journal: a `Stop` is `waiting` only while an agent type the session launched has more spawns than finished subagents of that type — a nested or helper agent of another type no longer ends the wait. Task ids come from the spawn description, else from the prompt (0.3.4 kept only the first prompt id, which could drop the reviewed task and make the review gate refuse a real reviewer); the flow names only the task in the description. The `Stop` handler reads `tools.jsonl` once.
- `inventory` kind: a failing `git ls-files` falls back to walking the tree instead of reporting `empty`; files teamwright installed do not count, so an interrupted init is still a new project. Requirement documents are matched on whole words of the file name (`отзывы` is not `тз`, `inspection` is not `spec`), only top-level and `docs/` READMEs count, and named documents come first.

## [0.4.0] - 2026-10-02

`/teamwright:init` starts from the requirements, not from the stack.

### Added
- `/teamwright:requirements`: builds `docs/requirements.md` before any spec or task. The owner's brief, PRD or terms of reference is the base; without one, an interview section by section (Jobs To Be Done, story map with MoSCoW and no-gos, EARS requirements with a failing example each, ISO/IEC 25010 as a checklist with numbers, constraints, glossary, integrations, pre-mortem). Answers in the owner's language, the document in English.
- `requirements-reviewer` role: a fresh agent roasts each draft — every requirement against ISO/IEC/IEEE 29148 (necessary, unambiguous, verifiable, singular, feasible), failure branches for every Must, the views of user, developer, tester, store or legal reviewer and operator, a pre-mortem, scope against time — and proposes the technical decisions (stack, what "deployed" means, where verification runs) from the requirements. Record `docs/requirements.reviews/<n>.md`, verdict `READY` / `NOT_READY`; the loop repeats until ready, then the owner approves.
- `inventory` reports `kind` (`empty` / `docs-only` / `code`) and `requirement_docs`: init vs adopt is decided by the installer, not by the model's impression, and a docs-only repository's brief becomes the base of the requirements.

### Changed
- `docs/requirements.md` template: ten sections with the practice for each, technical decisions and assumptions with a status.
- `/teamwright:init`: requirements → tools → stack, walking skeleton (the app starts, one real test per area, the running system reports its commit), gate and CI running the same gate → install and `enforce` → specs and tasks derived from the approved requirements feature by feature (Spec Kit: specify, clarify, checklist, plan, tasks, analyze) with every release-1 Must covered by a task → sprint 1 with T-001 as the first end-to-end slice → offer `/teamwright:flow`. `check-commands` runs in the foreground with no parallel edits.
- `/teamwright:adopt` offers `/teamwright:requirements` when the requirements are still the template.

## [0.3.4] - 2026-10-01

Fixes from the first full task cycle on a pilot project (analysis → implementation → review with a send-back → approval → `DONE` in 22 minutes). The cycle worked; the finish and the journal did not.

### Fixed
- `DONE` without an acceptance check. A task with `deploys: false` and `surface: none` was closed straight from `CODE_COMPLETE`: the flow skill and the router said "nothing to verify, close", while `lifecycle.md` requires the task-validator's acceptance verdict `PASS`. The task reached `DONE` with an empty `## Validation` and unchecked Acceptance items. Now the router sends such a task to the task-validator for acceptance only, and the verify gate refuses `DONE` unless the latest verdict in `## Validation` is `PASS` — for every surface. Verdicts are written only by `task-validator` and are append-only (ledger `.teamwright/sessions/<ID>.validation.jsonl`); the template placeholder is not a verdict. `VERIFIED` tasks without a verdict also route to the validator.
- Review evidence counted for the wrong tasks. The journal took every task id in a spawn prompt, so a reviewer started for one task whose prompt named the owners of a red gate was recorded as a reviewer spawn for those tasks too (review gate, `approvals_with_reviewer_spawn`). `task_ids` now come from the spawn description, else the first id in the prompt.
- A successful session looked like a series of crashes. When the runtime runs a role in the background, every turn ends while the role works and was journaled as `outcome: none`. Such a `Stop` is now `outcome: waiting` (`outcome_source: open-agent`), and `sessions_without_outcome` counts each session's last `Stop`, not every `Stop` record.
- Runtime helper agents in the metrics. `SubagentStop` records with no agent type and no tool calls (the runtime's own helpers, every ~30 s during a role) are left out of subagent outcomes and counted separately.

### Added
- `gates.jsonl`: every gate warning and denial is journaled (gate, decision, session, agent, tool, first line of the reason). The metrics report gate warnings and denials, per gate in the breakdown — the data for deciding when to switch from `gate-first` to `enforce`, which the pilot did not have.

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
