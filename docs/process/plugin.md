# Plugin packaging and the installer

How teamwright ships as a Claude Code plugin, and what `scripts/tw-install.py` does. This page is the installer and config reference; it stays in the kit and is not copied into projects.

## Layout

The repository is both the marketplace and the plugin:

```
.claude-plugin/marketplace.json   marketplace "teamwright", one entry: plugin "teamwright", source "."
.claude-plugin/plugin.json        plugin manifest (name, version, description, author, license, keywords)
commands/ or skills/              /teamwright:adopt, :init, :reconfigure, :status, ... (default scan locations)
scripts/tw-install.py             deterministic installer called by those commands
scripts/tw-next.py                read-only router for /teamwright:flow (next action, JSON or summary)
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
   - anything else → **conflict**: not touched, listed for the `adopt` command to merge with the owner. After the merge, `apply --accept <path>` records it (**accepted**) so later runs stop reporting it; editing the file or a template change makes it a conflict again.

   Files the installer wrote earlier (listed in `.teamwright/installed.json`) that the config no longer produces — e.g. `developer-backend.md` after going from two areas to one — are **stale**: removed by `apply` when unchanged since install (hash matches), otherwise a **conflict** (kept, for the owner to delete or keep).
3. **`.claude/settings.json`** is merged: missing `env` keys and deny rules are added (existing values win), each teamwright hook command is added once per event (into the group with the same matcher, or a new group). Nothing is removed or reordered. Invalid JSON → conflict.
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

## tw-next.py: the flow router

`python3 scripts/tw-next.py [--project PATH] [--json]` (also `tw-install.py next`) is read-only
and deterministic. It reads `docs/tasks/*.md` (status, priority, `depends_on`, `deploys`,
`surface`, `blocked_on`), the latest round in `<ID>.reviews/` (verdict) and `<ID>.verify/`
(result), `.teamwright/current-task`, the last `Stop` in `.teamwright/logs/outcomes.jsonl`
(outcome `interrupted`), the mode, `TEAMWRIGHT_PAUSE`, and git (tracked changes, unpushed
commits). First match wins:

| # | Situation | `action` |
|---|---|---|
| 0 | `TEAMWRIGHT_PAUSE` exists | `paused` (reason names what would be next) |
| 1 | current or interrupted task not closed; or tracked changes with one active task | `resume` that task; changes and no single active task → `decide` |
| 2 | `ANALYSIS` / `IN_PROGRESS` | `continue` (role problem-investigator / developer) |
| 3 | `NEEDS_REVIEW` | `review` (code-reviewer); latest verdict APPROVE → `continue` (to CODE_COMPLETE), ESCALATE → `decide`, REJECT_RECURRENCE → `continue` (defer) |
| 4 | `CODE_COMPLETE` / `DEPLOYED` without a PASS verify | `verify` (task-validator); PASS → `continue`; `deploys: false` and surface `none` → `continue` (close); `VERIFY_FAIL` → `reanalyze` |
| 5 | `BLOCKED` with `blocked_on` naming the owner, a decision or an open question (or empty) | `decide` |
| 6 | ready `TODO`: `depends_on` all DONE or VERIFIED, and `blocked_on` empty or naming only open questions marked `answered` / `dropped` in `docs/open-questions.md`; ordered by effective priority, then the number of open tasks it unblocks, then id | `start` (owner picks; others in `alternatives`) |
| 7 | unpushed commits | `decide` (push); otherwise `idle` |

Within a step, tasks are ordered by priority (P0 first), then id. **Priority inheritance** (step 6): a task inherits the highest priority among the open tasks that depend on it, directly or transitively, and the reason says so (`inherits P1 from T-010, which depends on it`) — otherwise a P1 task waits behind unrelated P2 work while its own P2 prerequisite is never picked. **Warnings** (`warnings` in JSON, `warning:` lines in the summary): a task whose body mentions an unresolved `OQ-NN` while `blocked_on` is empty (set `blocked_on: OQ-NN` if the question must be answered first), and a `blocked_on` that names only questions already answered (clear it). Untracked files alone do not
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
| `areas[].source_dirs` | list | no | `{{SOURCE_DIRS}}` |
| `areas[].test_command`, `lint_command`, `api_test_command`, `e2e_ui_command` | string | no | `{{TEST_COMMAND}}` etc., written bare and rendered as `scripts/tw-run <area> -- <cmd>`; `""` renders as `n/a` |
| `areas[].generate_command` | string | no | codegen run before the checks (by `check-commands`, and by the developer before the gate) |
| `areas[].runner` | `host` \| `docker` | no (default `host`) | where `scripts/tw-run` runs the area's commands |
| `areas[].image` | string | yes with `docker` | container image, preferably the one CI uses |
| `areas[].cache` | list | no | cache directories persisted between docker runs (relative = in `$HOME`) |
| `areas[].workdir` | string | no | repo-relative directory the commands run in (no `..`) |
| `areas[].stack`, `conventions`, `test_framework`, `test_dirs`, `test_helpers`, `gate_command` | string / list | no | optional per-area placeholders |
| `gate_command` | string | yes in practice | aggregate gate, `{{GATE_COMMAND}}` |
| `version_check`, `verify_environments` | string | no | task-validator placeholders |
| `tools.<capability>` | provider name \| `none` | no | capabilities: `spec`, `context`, `docs`, `ui_verify`, `api_verify`; adapter `providers/<capability>/<provider>.md` |
| `language` | string | no | language of generated project docs |

Placeholder rule: `{{NAME}}` → key `name` in the area being rendered, then at the top level; lists are joined with `, `. A per-area file (`developer-<area>.md`, `test-writer-<area>.md`) uses only its own area and the top level: when its area lacks the key, the placeholder stays as written and is reported as `unresolved` — it never takes another area's value. An area key used in a shared file (`AGENTS.md`, `CLAUDE.md`, `task-validator.md`, ...) renders as the single area's value, or `area: value; area: value`. An unknown key stays as written and is reported as `unresolved`.

**Format.** A JSON file with the same keys is accepted. The YAML reader is a small subset, enough for this file and adapter front matter: `key: value`, nesting by indentation, `- ` lists of scalars or maps, flow lists `[a, b]`, single or double quoted strings, `#` comments, and one-line JSON values (a value starting with `{` or `[`). Not supported: block scalars (`|`, `>`), anchors and aliases, multi-line flow values, multiple documents.

## Adapter front matter read by the installer

`mcp: none`, or `mcp:` with `name:` and `config:` (one-line JSON: the value under `mcpServers.<name>`), optionally `add:` (a `claude mcp add ...` line shown to the user). Without `config`, a ```json block containing `mcpServers.<name>` in `## Install` is used. `detect:` with `files:` and `commands:` lists feeds `inventory`. `## Rules for agents` (up to the next `## `) is injected verbatim as `### <capability>: <provider>`, in the order spec, context, docs, ui_verify, api_verify.
