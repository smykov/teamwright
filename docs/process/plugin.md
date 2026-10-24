# Plugin packaging and the installer

How teamwright ships as a Claude Code plugin, and what `scripts/tw-install.py` does. This page is the installer and config reference; it stays in the kit and is not copied into projects.

## Layout

The repository is both the marketplace and the plugin:

```
.claude-plugin/marketplace.json   marketplace "teamwright", one entry: plugin "teamwright", source "."
.claude-plugin/plugin.json        plugin manifest (name, version, description, author, license, keywords)
commands/ or skills/              /teamwright:adopt, :init, :requirements, :flow, :router, :analyze, :red-tests, :implement, :review, :verify, :parallel, :reconfigure, :status, :progress, :blockers, :settings, :improve, :feedback (default scan locations)
scripts/tw-install.py             deterministic installer called by those commands
scripts/tw-next.py                read-only router for /teamwright:flow, :router and the stage commands (next action, stage, candidates; JSON or summary)
scripts/tw-progress.py            read-only progress report for /teamwright:progress (JSON or summary)
scripts/tw-blockers.py            read-only: what waits for a person, by class and by what it unblocks (blockers)
scripts/tw-context.py             read-only: does the context tool index the areas' languages, is it used (status)
scripts/tw-process.py             read-only: review findings, send-backs, settings history and render drift, DRAIN exceptions, record sizes; --since / --split-date (improve)
scripts/tw-parallel.py            parallel tasks: group by disjoint seams, worktrees on tw/<ID>, status, journal merge
providers/<capability>/<provider>.md   tool adapters (read by the installer, not copied wholesale)
template/                         files installed into a project
docs/process/                     process reference, copied into projects (except this page)
```

Install for a user:

```bash
claude plugin marketplace add smykov/teamwright     # or a local path to a checkout
claude plugin install teamwright@teamwright
```

The plugin registers **no hooks of its own** (no `hooks/hooks.json`, no `hooks` key). Gates are installed per project into `.claude/settings.json` and run from the project's `scripts/hooks/`, so a project works the same with or without the plugin installed.

How the kit itself is checked and released, and the Claude Code plugin facts this layout relies on: [CONTRIBUTING.md](../../CONTRIBUTING.md).

## tw-install.py

Python 3 stdlib only. Every subcommand takes `--project PATH` (default: current directory), `--dry-run` and `--json`; `--providers DIR` and `--kit DIR` point at another adapter directory or kit checkout (tests use both).

| Subcommand | Does | Writes |
|---|---|---|
| `inventory` | JSON: CLAUDE.md / AGENTS.md / PRINCIPLES.md (size, markers), `.claude/agents`, `commands`, `skills`, settings hook events, `.mcp.json` servers, spec tool dirs (`.specify`, `openspec/`), CI and build files, test dirs, lock files, secret-looking files (tracked, untracked or ignored), git state (`core.hooksPath`, dirty, legacy `.git/hooks`), teamwright config and mode, providers detected by their adapters' `detect`; `versions` — per manifest or lock file within 3 levels (`package.json` engines/dependencies/devDependencies/packageManager, `package-lock.json` resolved versions of direct dependencies, `pubspec.yaml` environment and dependencies, `pubspec.lock` direct packages and `sdks`, `go.mod`, `.nvmrc`, `.node-version`, `.python-version`, `.tool-versions`, `.fvmrc`): only what is written there, never guessed; `unfilled_docs` — `docs/*.md` still identical to the template (installed and never edited) | nothing |
| `plan [--config FILE]` | the actions `apply` would take, conflicts, unresolved placeholders, notes; with a `--config` other than the project's, the unified diff against `.teamwright/config.yml` first (`--json` → `config_diff`) | nothing |
| `apply [--config FILE]` | see below; `--config .teamwright/config.next.yml` prints the diff, applies and then removes the proposal file (`--json` → `removed_proposal`) | the project |
| `apply --accept PATH` (repeatable) | records the current content of a file the owner merged by hand (a `conflict` in `plan`): its hash and the hash of the template it was merged against go to `installed.json` under `@accepted`. `plan` then shows it as `accepted`, not `conflict`, until the file or the template changes. Only the accept is done, nothing else is applied; a path that is not a template conflict exits 1 | installed.json |
| `enforce` | sets `mode: enforce` in `.teamwright/config.yml`: YAML — the top-level `mode:` line is replaced (a trailing comment is kept) or inserted after `version:`; JSON — the key is rewritten and the file re-serialised | config.yml |
| `scan` | secret scan of every tracked and untracked, not ignored, file (whole tree outside git), with the pre-commit hook's built-in rules and its `teamwright:allow-secret` marker. Findings are classified — `secret-like` (high), `config-placeholder`, `test-fixture`, `docs-example` (rules in `gates.md` › Secret scan) — with a summary per class (`--json` → `summary`, `blocking`, `findings[].class`); exit 1 only on secret-like findings. Each line is fed to the scanner as its own one-line hunk, so findings carry the exact path and line whatever the content (a line starting with `++ ` is content, not a header) | nothing |
| `check-commands [--config FILE] [--area NAME] [--timeout S]` | runs every configured area command once through `scripts/tw-run` (the project's copy, or the kit's before `apply`): first each `generate_command`, then `test`, `lint`, `api_test`, `e2e_ui`. Each gets `pass`, `fail` (non-zero exit, or timeout — default 900 s, the whole process group is killed) or `not-runnable` (exit 125–127: tool, docker or image missing; a tw-run config error; or an environment error, below). `git status` (with content hashes) is taken after code generation and after every check: a check that changes tracked files **inside its area's `workdir`** (the whole repository when the area has none) is a `fail` with `gate modifies tracked files: <paths>`; tracked files changed **outside** the workdir during the run are a note (`changed_outside_workdir` in JSON) — most likely someone edited them meanwhile, so run it in the foreground and edit nothing until it finishes; new untracked files are a note. Full output per command: `.teamwright/logs/check-commands/<area>.<key>.log`. Exit 1 unless all pass. `--dry-run` lists the commands | logs only |
| `next` | the router decision of `scripts/tw-next.py` for `/teamwright:flow` | nothing |

`apply`, in order — each step is skipped when there is nothing to change, so a second run reports `0 changed`:

1. **Config.** When `--config` points outside the project, its text is written to `.teamwright/config.yml`. A config without `mode` gets an explicit `mode: enforce` line, so the file always states the mode the gates apply. Lowering the mode (`enforce` in the project, `gate-first` in the new config) is refused with exit 1 unless the owner runs the installer outside Claude Code with `TEAMWRIGHT_OWNER=1` (ignored when `CLAUDECODE` is set, i.e. inside any Claude Code tool call), or edits the file by hand. `plan` and `apply` end with the effective mode (`mode: enforce (gates block)`; `--json` → `mode`).
2. **Template files** (`template/**` and `docs/process/*.md`, without `__pycache__` and `config.example.yml`). Placeholders `{{NAME}}` are rendered from the config; `developer.md` and `test-writer.md` are rendered per area; the block between `<!-- teamwright:tools:begin -->` and `<!-- teamwright:tools:end -->` is filled from the chosen adapters. For an existing file:
   - identical → nothing;
   - written by the installer and unchanged since (hash in `.teamwright/installed.json`) → **update**;
   - contains both markers → only the block between them is re-rendered (**tools**), the rest of the file is left as it is; markers out of order (end before begin) → **conflict**, the file is not touched;
   - written by the installer, then edited → **kept-local**;
   - a project document that existed before install (`docs/requirements.md`, `open-questions.md`, `plan.md`, `architecture.md`, `decisions.md` — e.g. written by `/teamwright:requirements` during init) → **kept-project**: the template only seeds these, the project's own content is never a conflict;
   - anything else → **conflict**: not touched, listed for the `adopt` command to merge with the owner. After the merge, `apply --accept <path>` records it (**accepted**) so later runs stop reporting it; editing the file or a template change makes it a conflict again.

   Files the installer wrote earlier (listed in `.teamwright/installed.json`) that the config no longer produces — e.g. `developer-backend.md` after going from two areas to one — are **stale**: removed by `apply` when unchanged since install (hash matches), otherwise a **conflict** (kept, for the owner to delete or keep).
3. **`.claude/settings.json`** is merged: missing `env` keys and deny rules are added (existing values win), each teamwright hook command is added once per event (into the group with the same matcher, or a new group). The plugin is enabled (`enabledPlugins`) and its marketplace named (`extraKnownMarketplaces`), so Claude Code offers both on a fresh clone; the source is the one Claude Code already knows for the marketplace when it is GitHub, git or a URL, otherwise the `origin` of a local checkout (GitHub, or a `.git` URL without credentials) with its branch when that is not the default. No shareable source → a note. An existing entry, including a disabled plugin, is kept. Nothing is removed or reordered. Invalid JSON → conflict.
   **`.teamwright/installed.json`** records the plugin and version that installed the project under `@kit` (**kit-version** when it changes); `scripts/hooks/session-check.sh` compares it with the plugin installed on the machine.
4. **`.mcp.json`**: servers of the chosen adapters are added under `mcpServers`; an existing server with the same name is kept as it is (reported when it differs). Invalid JSON → conflict.
5. **Git hooks**: `core.hooksPath = scripts/hooks` and the local-state lines of `.gitignore` (the list from `template/scripts/install-hooks.sh`). A `core.hooksPath` already set to something else (another hook manager) → conflict. Existing `.git/hooks/*` are reported: `core.hooksPath` disables them.

**Environment errors (heuristics).** A command that exits non-zero is `not-runnable` instead of `fail` when its output matches one of these patterns, because it could not exercise the code at all; the reason is `environment (<kind>): <matching line>` and JSON carries `environment: <kind>`:

| Kind | Matches (case-insensitive unless noted) |
|---|---|
| service not reachable | `ECONNREFUSED`, `connection refused`, `could not connect to server`, `Can't reach database server`, Prisma `P1001`, `getaddrinfo ENOTFOUND` / `EAI_AGAIN`, `Name or service not known`, `Temporary failure in name resolution` |
| docker unavailable | `Cannot connect to the Docker daemon`, `docker: not found`, `permission denied while trying to connect to the Docker daemon` |
| missing binary | a shell's `<name>: command not found` / `<name>: not found` (case-sensitive), `executable file not found in $PATH`, `spawn <x> ENOENT` |
| no device | `No devices found` / `No connected devices`, `no devices/emulators found`, `error: device not found`, `No supported devices`, `No booted simulator` |

First match wins. The patterns are specific on purpose (a test that fails with "404: not found" stays `fail`), but they are heuristics: a test suite whose own assertions print "connection refused" would be misread — read the log when the reason looks wrong.

Exit codes: 0 on success, conflicts included (they are in the output, `--json` → `conflicts`); 1 for an invalid or missing config; `scan` 1 on secret-like findings; `check-commands` 1 unless every command passes; `apply --accept` 1 for a path that is not a template conflict.

## tw-run: one command, the area's toolchain

`template/scripts/tw-run` is installed into every project as `scripts/tw-run`:

```bash
scripts/tw-run <area> -- <cmd> [args...]          # e.g. scripts/tw-run app -- flutter test
scripts/tw-run <area> -- '<shell string>' [args]  # chains are passed as one string
```

It reads the area from `.teamwright/config.yml` and runs the command with `sh -c` (extra
arguments are appended, so `{{TEST_COMMAND}} test/a_test.dart` works):

- `runner: host` (default): in `<root>/<workdir>`.
- `runner: docker`: `docker run --rm -u $(id -u):$(id -g) -v <root>:/work -w /work/<workdir>
  -e HOME=/tw-home -v <root>/.teamwright/cache/<area>/home:/tw-home <image> sh -c ...`.
  Files the command writes belong to the caller (no `chown`). `cache:` entries that are
  relative live in that persisted `$HOME` (e.g. `.pub-cache`); absolute ones get their own
  directory under `.teamwright/cache/<area>/`. `.teamwright/cache/` is gitignored. Use the
  image CI already uses, so a local run and CI agree.

Exit code is the command's; 127 when docker is missing, 2 on a usage or config error.
`TW_DOCKER` selects a docker-compatible binary (e.g. podman), `TW_DOCKER_ARGS` adds `docker
run` arguments, `TW_RUN_PRINT=1` prints the command instead of running it,
`TEAMWRIGHT_ROOT` / `TEAMWRIGHT_CONFIG` point at another root or config (used by
`check-commands`). Killing `tw-run` on a timeout stops the docker client; a container that
ignores it keeps running until it ends (`--rm` removes it).

**Rendering.** Per-area commands (`test_command`, `lint_command`, `api_test_command`,
`e2e_ui_command`, `generate_command`, area `gate_command`) are written bare in the config
and rendered into the roles as `scripts/tw-run <area> -- <cmd>`; a command with shell syntax
(`&&`, `|`, quotes, `$`) is quoted as one string. A command already starting with
`scripts/tw-run` is a config error. The top-level `gate_command` is rendered as written:
make it a chain of `scripts/tw-run <area> -- ...` calls or a Makefile target that uses them.
`generate_command` (codegen, e.g. localisation or ORM clients) runs separately before the
checks; a check must not modify tracked files.

## tw-gate: the full gate, once per state of the code

`template/scripts/tw-gate` is installed into every project as `scripts/tw-gate`:

```bash
scripts/tw-gate <area>|--top [--fresh]       # run (or reuse) a gate
scripts/tw-gate --for-task <ID>              # which gates the task's changes need
scripts/tw-gate --for-diff <base>            # the same since a commit
scripts/tw-gate --stop <area>|--top          # stop a running gate
```

It reads the area from `.teamwright/config.yml` with the same parser and the same keys the
role files are rendered from: `generate_command` (if any), then the area's `gate_command`,
both through `scripts/tw-run`; without an area `gate_command`, the top-level one as written
from the root. Full output goes to `.teamwright/logs/gate/` (or `$TEAMWRIGHT_LOG_DIR/gate/`)
with a JSON record of the run; a PASS is reused when the content of the area's files (a git
tree id of HEAD plus uncommitted and untracked changes, restricted to the area's
`source_dirs`, `test_dirs`, `workdir`, dependency manifests, the config, the gate scripts
and files the commands name; the whole tree for an area without dirs) and the command are
the same and did not change during the run. The run is detached (own process group) and
waited for up to `TW_WAIT_SECONDS` (540): past that it prints `RUNNING: …` and exits **75**,
and the same command again attaches to it. Exit code is the gate's; 75 still running; 2 on a
usage or config error.
What it records and when it reruns: [gates.md](gates.md#gate-runs-tw-gate).

## tw-mutants: a task's mutant catalog, in one runner start

`template/scripts/tw-mutants` is installed into every project as `scripts/tw-mutants`:

```bash
scripts/tw-mutants <area> <ID> --tree <throwaway copy> [--check] [--only <name>]
scripts/tw-mutants <area> --tree <throwaway copy> --prepare   # generated code only
```

It reads `docs/tasks/<ID>.mutants/` from the working tree (one `.mutant` file per exact
replacement, with the guarantee it breaks, and `test-command`), checks every entry against
the copy, and runs the baseline and every mutant in one `scripts/tw-run <area>` start with
the copy as the project root. Exit 0 when no survivor breaks a guarantee, 1 when one does,
2 on a usage error or a stale entry, 3 on a red baseline, 4 when `generate_command` failed in
the copy, 75 while it still runs detached (the same command again attaches). The copy gets
the area's `generated` outputs (or runs `generate_command` when its inputs changed) and its
`copy_env`. Format, rules and stop rules:
[gates.md](gates.md#mutation-checks-tw-mutants).

## tw-progress.py: the progress report

`python3 scripts/tw-progress.py [--project PATH] [--json]` is read-only. It counts task records
by status, by `sprint:` (with the goal and pending forks of `docs/sprints/<N>.md`), by plan stage
(a task belongs to a stage of the `docs/plan.md` Stages table when it names one of the stage's
FR-NN; FRs no task names are listed) and by area (the configured area whose `source_dirs`,
`test_dirs` or `workdir` the task's `analysis.seam` names, longest directory first; unmatched
tasks are listed, not guessed). Done means `DONE`; `DEFERRED` is left out of percentages. The
next action, the ready queue and the owner decisions are the router's (`tw-next.py`).

The optional, committed `.teamwright/progress.json` adapts it to a project: per-task `areas`,
`area_rules` (regex over the seam, then the task text), a `milestone` (named list of plan
stages) and an `extra_command` whose JSON is reported next to the counts — for work kept
outside task records. `.teamwright/progress.md` holds what the project adds to the report in
words. Both are written by `/teamwright:progress --adapt` or the progress step of adopt and init,
from what the repository already has (an earlier progress command, the spec tool's task lists).

## tw-blockers.py: what waits for a person

`python3 scripts/tw-blockers.py [--project PATH] [--json]` is read-only. It lists every item the
team cannot move by itself: unresolved rows of `docs/open-questions.md` (and ids named in
`blocked_on` but missing from the table) with the tasks whose `blocked_on` names them and those
that only mention them; tasks whose latest review verdict is `ESCALATE`; tasks whose latest
acceptance verdict is `NEEDS_OWNER`; `BLOCKED` tasks with a reason other than open questions;
`TODO` tasks with a free-text `blocked_on`; stale `blocked_on` (questions already answered);
uncommitted changes and unpushed commits. Each item gets a class from its text (credentials,
infrastructure, external, device, decision, other) and `unblocks`: its open tasks plus every
open task depending on them, directly or not. Items are ordered by the highest priority they
unblock, then how many. Task state and question status come from the router's readers
(`tw-next.py`), so both agree. `/teamwright:blockers` renders it and records the owner's answers.

## tw-next.py: the flow router

`python3 scripts/tw-next.py [--project PATH] [--json] [--pass IDS] [--stage STAGE [--task IDS]]` (also `tw-install.py next`) is read-only
and deterministic. It reads `docs/tasks/*.md` (status, priority, `depends_on`, `deploys`,
`surface`, `blocked_on`), the latest round in `<ID>.reviews/` (verdict) and `<ID>.verify/`
(result), `.teamwright/current-task`, the last `Stop` in `.teamwright/logs/outcomes.jsonl`
(outcome `interrupted`), the mode, `TEAMWRIGHT_PAUSE`, and git (tracked changes, unpushed
commits). First match wins:

| # | Situation | `action` |
|---|---|---|
| 0 | `TEAMWRIGHT_PAUSE` exists | `paused` (reason names what would be next) |
| 1 | tracked changes in the tree (the current task, else the single active one), or the last `Stop` was `interrupted` | `resume` that task; changes and no single active task → `decide`. A current task on a clean tree is not a resume |
| 2 | `ANALYSIS` / `IN_PROGRESS` | `continue` (role problem-investigator; in `IN_PROGRESS` by stage: test-writer for `red-tests`, developer for `implement`) |
| 3 | `NEEDS_REVIEW` | `review` (code-reviewer); latest verdict APPROVE → `continue` (to CODE_COMPLETE), ESCALATE → `decide`, REJECT_RECURRENCE → `continue` (defer) |
| 4 | `CODE_COMPLETE` / `DEPLOYED` without a PASS verify | `verify` (task-validator); PASS → `continue`; `deploys: false` and surface `none` → `continue` (close); `VERIFY_FAIL` → `reanalyze` |
| 5 | `BLOCKED` with `blocked_on` naming the owner, a decision or an open question (or empty) | `decide` |
| 5a | (main tree) a task in another worktree on a branch that names it — `tw/<ID>` (`/teamwright:parallel`) or `task/<ID>[-…]`, pattern `$TEAMWRIGHT_TASK_BRANCH_RE` — whose record in that worktree is `CODE_COMPLETE` or later | `merge` (`/teamwright:parallel` for `tw/`, else the branch and the worktree path); tasks in worktrees are otherwise skipped, and their state in `tasks` comes from the worktree's record (`in_worktree`, `branch`) |
| 6 | ready `TODO`: `depends_on` all DONE or VERIFIED (or also CODE_COMPLETE / DEPLOYED with `process.ready.after: code_complete`), and `blocked_on` empty or naming only open questions marked `answered` / `dropped` (or `closed` / `resolved` / `done`) in `docs/open-questions.md`; ordered by effective priority, then the number of open tasks it unblocks, then id | `start` (owner picks; others in `alternatives`; `process.autonomy.start: auto` → `ask_owner: false`) |
| 6a | with `--pass IDS`: no ready task fits the pass cap (`process.batch.max_tasks`, lowered by the `by_priority` cap of every task in the pass) | `stop` (end the pass); `budget` reports taken / limit / left |
| 7 | unpushed commits | `decide` (push); otherwise `idle` |

In a worktree on such a branch the router answers only for that task and ends `idle` once it is `CODE_COMPLETE`: no push and no verification there. `tw-progress.py` reads those tasks from their worktrees the same way, so their area comes from the analysis written there. The output also carries `settings` (effective `process:` values, `explicit` keys) and `parallel` (`own`, `elsewhere`, `worktrees`: path, branch and status per task).

**Stages.** Every task-bound decision carries `stage`: `analyze` (ready `TODO`, `ANALYSIS`, `VERIFY_FAIL`), `red-tests` / `implement` (inside `IN_PROGRESS`: the task's `stage:` field checked against the evidence — `## Tests` filled = red tests written; on disagreement the evidence wins and `warnings` says so; no field = the evidence), `review` (`NEEDS_REVIEW`), `verify` (`CODE_COMPLETE`, `DEPLOYED`, `VERIFIED`). `process.stages.<stage>` holds a stage back while other work is due: it is due when `min` tasks wait there, a task of effective priority P0/P1 waits, or the oldest waiting task's record changed more than `max_wait_hours` ago; a held candidate moves behind the last due piece of work (owner decisions keep their place) and its reason ends `(held: …)`; with no due work, nothing is held. `work_available` (any `resume`, `continue`, `review`, `verify`, `reanalyze`, `start`, `merge`) is that single predicate, and also what makes `idle` idle. For the chosen stage the output adds `batch` (the router's default: the first candidates up to `process.stages.<stage>.batch`, `start`s kept within the `--pass` budget), `batch_cap`, `candidates` (every task waiting there, in router order: `priority`, `effective_priority`, `unblocks`, `depends_on`, `seam_paths`, `areas` from the config's `source_dirs`/`test_dirs`/`workdir`, `size` — seam paths, Acceptance items, review rounds — `overlaps`, by tw-parallel.py's seam rule, and `depends_on_candidates`), `model` (`process.models.<stage>`, `null` = the role files), `command` (`/teamwright:<stage> <batch>`, `/teamwright:parallel merge <ID>`, or `null`), `stages` (per stage: `waiting`, `due`, `why`, `batch`, `min`, `max_wait_hours`, `model`), `select` (`process.router.select`), `decisions` (every owner decision in router order: `task`, `reason`) and `headless` (`run`, `prompt`, `model`, `stage`, `task`, `reason`, `note`, `decisions`: what a CI job runs for one stage). `headless` differs from the interactive answer on purpose: an owner decision does not stop the chain while other work is available — the job takes the first piece of work in router order (a `start` only with `process.autonomy.start: auto`: nobody answers the start question in CI), its `prompt` is the bare stage command (`/teamwright:<stage>`, no ids: the stage session asks the router and picks its batch from the candidates), and the decisions are reported. `run` is false only when no such work is left, the team is paused, the tree holds uncommitted changes of no task, or a pass ended (`stop`). `--stage S [--task IDS]` adds `request` for a stage command: `ok`, `batch`, `batch_cap`, `candidates`, `model`, and when refused a `hint` naming the command to run instead (another stage, the unfinished work in the tree, the pause); an explicit stage ignores `min`.

Within a step, tasks are ordered by priority (P0 first), then id. **Priority inheritance** (step 6): a task inherits the highest priority among the open tasks that depend on it, directly or transitively, and the reason says so (`inherits P1 from T-010, which depends on it`) — otherwise a P1 task waits behind unrelated P2 work while its own P2 prerequisite is never picked. **Warnings** (`warnings` in JSON, `warning:` lines in the summary): a task whose body mentions an unresolved `OQ-NN` while `blocked_on` is empty (set `blocked_on: OQ-NN` if the question must be answered first), a `blocked_on` that names only questions already answered (clear it), and **render drift** — a rendered file (AGENTS.md, a role file) edited locally whose settings line still carries a value other than `process:` in the config (`tw-process.py`, `render_drift`). After two acceptance `FAIL` rounds in a row the `verify` reason says the next round is `method: sweep` or `NEEDS_OWNER`. Untracked files alone do not
trigger `resume`. JSON: `action`, `task` (id or null), `reason`, `role`, `ask_owner`,
`alternatives` (up to 5 other applicable decisions in the same order), `state` (mode, pause,
branch, dirty files, current task, unpushed count), `tasks` (with `ready`, `blockers`,
`effective_priority`) and `warnings`. Without
`--json` it prints a one-screen summary.

## Config: `.teamwright/config.yml`

Example with every field: `template/.teamwright/config.example.yml`.

| Key | Type | Required | Meaning |
|---|---|---|---|
| `version` | int | yes | config schema version, `1` |
| `process_version` | string | no | teamwright process/principles version the project follows |
| `mode` | `gate-first` \| `enforce` | no (default `enforce`) | `gate-first`: analysis, review and verify gates warn (message to the user and the model) instead of blocking; `enforce`: they block. Git hooks are the same in both modes. Only an explicit `gate-first` warns: a missing, unknown or unreadable mode is `enforce`, in the installer and in the gates alike (both read the file with `scripts/hooks/_config.py`, YAML subset or JSON). Agents cannot change this file (see the state guard in `gates.md`) |
| `areas` | list of maps | yes, ≥1 | code areas; each needs `name` (lower-case, digits, `-`, `_`) |
| `areas[].source_dirs` | list | no | `{{SOURCE_DIRS}}`; with `test_dirs` and `workdir`, also the area's scope for `scripts/tw-gate`: its cache key and which tasks need its gate (`--for-task`) |
| `areas[].test_command`, `lint_command`, `api_test_command`, `e2e_ui_command` | string | no | `{{TEST_COMMAND}}` etc., written bare and rendered as `scripts/tw-run <area> -- <cmd>`; `""` renders as `n/a` |
| `areas[].test_select_command` | string with `{tests}` | no | the area's test command for chosen tests, run by `scripts/tw-test <area> <tests>`: `{tests}` becomes the selectors, shell-quoted; workers stay in the string, e.g. `"pytest -q -n ${PYTEST_WORKERS:-4} {tests}"`. Without it tw-test appends the selectors to `test_command`. Written bare (no `scripts/tw-run`) |
| `areas[].generate_command` | string | no | codegen run before the checks (by `check-commands`, and by the developer before the gate) |
| `areas[].generated` | list | no | the outputs of `generate_command`, relative to the project root: `scripts/tw-mutants` copies them from the working tree into a throwaway copy when the copy's inputs are unchanged, instead of generating there |
| `areas[].generate_inputs` | list | no | the paths `generate_command` reads (default: the whole tree); compared between the copy and the working tree |
| `areas[].copy_env` | map | no | environment for runs in a throwaway copy (`TW_RUN_COPY=1`, set by `scripts/tw-mutants`), e.g. `CARGO_TARGET_DIR: "{cache}/target"`; `{cache}` = `.teamwright/cache/<area>/copy` of the main checkout (`/tw-copy-cache` inside docker) |
| `areas[].ci_workflow` | string | no | the CI workflow that runs tests of this area the host cannot (another platform): the flow confirms red and green with a run on a `wip/<ID>` branch, which pre-push does not treat as a delivery; CI must trigger on `wip/**` |
| `areas[].runner` | `host` \| `docker` | no (default `host`) | where `scripts/tw-run` runs the area's commands |
| `areas[].image` | string | yes with `docker` | container image, preferably the one CI uses |
| `areas[].cache` | list | no | cache directories persisted between docker runs (relative = in `$HOME`) |
| `areas[].workdir` | string | no | repo-relative directory the commands run in (no `..`) |
| `areas[].stack`, `conventions`, `test_framework`, `test_dirs`, `test_helpers`, `gate_command` | string / list | no | optional per-area placeholders |
| `gate_command` | string | yes in practice | aggregate gate, `{{GATE_COMMAND}}` |
| `version_check`, `verify_environments` | string | no | task-validator placeholders |
| `tools.<capability>` | provider name \| `none` | no | capabilities: `spec`, `context`, `docs`, `ui_verify`, `api_verify`; adapter `providers/<capability>/<provider>.md` |
| `ui_verify_deferred` | string | no | the owner's recorded decision to run without UI verification for now (e.g. `"decisions.md #6"`): `check-commands` notes the missing `e2e_ui_command` instead of reporting it as not runnable |
| `no_mcp` | list | no | capabilities whose provider's MCP server is not added to `.mcp.json` (the tool is used through its CLI only) |
| `test_runner_patterns` | list of regular expressions | no | more commands the test guard treats as test runs (matched against each simple command), e.g. `["^bin/run-specs( \|$)"]` |
| `language` | string | no | language of generated project docs |
| `process.review.blocking` | `low` \| `medium` \| `high` | no (default `low`) | from which severity a review finding returns the task; Critical and the categories `secret-leak`, `security`, `weakened-test`, `done-not-working`, `recurrence` always block. Set → the review gate checks the verdict against the record's findings table. `{{REVIEW_BLOCKING}}` |
| `process.batch.max_tasks` | 1–5 | no (default 1) | tasks per `/teamwright:flow` pass, one after another. `{{BATCH_MAX_TASKS}}` |
| `process.batch.by_priority.P0`…`P3` | 1–5 | no (default P0 1, P1 1, P2 3, P3 3) | cap for a pass holding a task of that priority; the lowest wins; `tw-next.py --pass` applies it. `{{BATCH_BY_PRIORITY}}` |
| `process.batch.parallel` | 1–10 | no (default 1 = off) | tasks worked at the same time, each in its own worktree on `tw/<ID>` and its own session, when their seams do not overlap (`/teamwright:parallel`, `tw-parallel.py`). `{{BATCH_PARALLEL}}` |
| `process.autonomy.start` | `ask` \| `auto` | no (default `ask`) | `auto`: the router's `start` needs no owner answer. `{{AUTONOMY_START}}` |
| `process.autonomy.continue` | bool | no (default `false`) | the flow takes the next task after a barrier; push is asked once at the end of the pass. `{{AUTONOMY_CONTINUE}}` |
| `process.ready.after` | `verified` \| `code_complete` | no (default `verified`) | when a `depends_on` counts as finished for readiness: `VERIFIED`/`DONE`, or already `CODE_COMPLETE`/`DEPLOYED` (`tw-next.py`) |
| `process.stages.<stage>.batch` | 1–10 | no (default 1) | `<stage>`: `analyze`, `red-tests`, `implement`, `review`, `verify`. Tasks one stage session takes, one after another (`tw-next.py` `batch_cap`) |
| `process.stages.<stage>.min` | 1–10 | no (default 1) | tasks waiting at the stage before the router runs it while other work is due; P0/P1 tasks and "nothing else to do" run it at once |
| `process.stages.<stage>.max_wait_hours` | 0–168 | no (default 0 = off) | the stage runs anyway once its oldest waiting task's record is this old |
| `process.models.<stage>` | `opus` \| `sonnet` \| `haiku` \| `fable` \| `claude-…` | no (default: unset) | model of the stage's role spawns (the agent tool's `model` parameter; the technical-writer keeps its file's model) and of a headless job; unset = each role file's `model:` |
| `process.router.select` | `script` \| `agent` | no (default `script`) | `script`: `tw-next.py` selects by status and counts, and lists the stage's candidates; the session only picks the batch from them. `agent`: the session reads the task records itself — more tokens, for task records the script cannot read |
| `process.test_guard` | `block` \| `warn` \| `off` | no (default `block`) | the test guard (`scripts/hooks/test-guard.sh`): refuses tests and gates run directly instead of through `scripts/tw-test`/`tw-gate`/`tw-mutants`, and test output piped into `tail`/`grep`. Its own switch, independent of `mode` — it blocks in `gate-first` too; `TW_TEST_GUARD` in the environment Claude Code starts with wins ([gates.md](gates.md#test-guard)) |

`process:` is a closed list: any other key fails validation. Missing keys are the behaviour before settings existed, except `test_guard` (new in 0.11.0, blocks by default). Changed through `/teamwright:settings` (config.next.yml + `apply`), like every config change.

Placeholder rule: `{{NAME}}` → key `name` in the area being rendered, then at the top level; lists are joined with `, `. A per-area file (`developer-<area>.md`, `test-writer-<area>.md`) uses only its own area and the top level: when its area lacks the key, the placeholder stays as written and is reported as `unresolved` — it never takes another area's value. An area key used in a shared file (`AGENTS.md`, `CLAUDE.md`, `task-validator.md`, ...) renders as the single area's value, or `area: value; area: value`. An unknown key stays as written and is reported as `unresolved`.

**Format.** A JSON file with the same keys is accepted. The YAML reader is a small subset, enough for this file and adapter front matter: `key: value`, nesting by indentation, `- ` lists of scalars or maps, flow lists `[a, b]`, single or double quoted strings, `#` comments, and one-line JSON values (a value starting with `{` or `[`). Not supported: block scalars (`|`, `>`), anchors and aliases, multi-line flow values, multiple documents.

## Adapter front matter read by the installer

`mcp: none`, or `mcp:` with `name:` and `config:` (one-line JSON: the value under `mcpServers.<name>`), optionally `add:` (a `claude mcp add ...` line shown to the user). Without `config`, a ```json block containing `mcpServers.<name>` in `## Install` is used. `detect:` with `files:` and `commands:` lists feeds `inventory`. `## Rules for agents` (up to the next `## `) is injected verbatim as `### <capability>: <provider>`, in the order spec, context, docs, ui_verify, api_verify.
