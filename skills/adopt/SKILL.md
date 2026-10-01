---
name: adopt
description: Adopt the teamwright process in an EXISTING repository — inventory, product goal, tool choice per capability, areas with a runnable toolchain (host or the CI's container image), merge of existing CLAUDE.md and agents, hooks in gate-first mode, secret scan, every command checked once, a first sprint toward the goal, and next steps. Run from the repository root.
argument-hint: "[--dry-run]"
disable-model-invocation: true
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" inventory *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" plan *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" scan *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" check-commands *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(claude mcp list) Bash(git status *) Bash(git log *) Bash(command -v *)
---

# /teamwright:adopt — bring an existing project up to the teamwright process

The process is fixed; tools, commands and the toolchain runner are chosen per project. You (the main session) run the steps below **with the owner**. The installer does the deterministic work:

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" <inventory|plan|apply|scan|check-commands|enforce> [--project PATH] [--config FILE] [--accept PATH] [--dry-run] [--json]
```

Kit reference, read as needed: `${CLAUDE_PLUGIN_ROOT}/docs/process/tools.md` (capabilities, runners), `${CLAUDE_PLUGIN_ROOT}/docs/process/plugin.md` (installer and config schema), `${CLAUDE_PLUGIN_ROOT}/template/.teamwright/config.example.yml`, `${CLAUDE_PLUGIN_ROOT}/template/CLAUDE.md` (map format), adapters in `${CLAUDE_PLUGIN_ROOT}/providers/<capability>/<provider>.md`.

Arguments: `$ARGUMENTS` — with `--dry-run`, stop after step 8 (plan) and write nothing.

## Ground rules

- **Ask before every destructive or external step**: installing a CLI or package, pulling a container image, adding an MCP server, running a tool's own `init`, rewriting or deleting an existing file, creating a branch, committing. Show the exact command or diff. A "no" is recorded and the flow continues without that step.
- **Batch the questions you can batch**: up to four independent questions in one AskUserQuestion call (2–4 options each, the recommended one first); without that tool, a short numbered list. Commits at the end are proposed **once**, as one list, not one question per commit.
- Never run `git stash`, `checkout --`, `restore`, `clean`, `reset --hard` or force-push — not even to undo your own change. Undo by editing the file back.
- Never print secret values. Never copy `*.local.json`, `.env*` or credentials anywhere.
- **`.teamwright/config.yml` is never edited by hand — not by you, not by the owner.** Before the first `apply` you write it with the Write tool; after that, every change (a command, a runner, a tool) goes into `.teamwright/config.next.yml` and is applied with `apply --config .teamwright/config.next.yml` — at any time, not only during re-adoption. The installer validates it, shows the diff, writes `config.yml` and deletes the proposal. Staging and committing `config.yml` (`git add .teamwright/config.yml`) is allowed and is part of your work. Only lowering `enforce` to `gate-first` is the owner's own step, outside Claude Code.
- **Never write a command that does not run.** Every command that goes into the config was either run (step 10) or is explicitly marked "not run" with the reason and a first-sprint task to make it run.
- Everything you write into the project is in the language set by `language` (default `en`). Write logs and scratch output inside the repository's ignored directories or the system temp directory, never next to the repository.

## 1. Preconditions

1. `git status --porcelain`. Not a git repository → stop; adopting needs history.
2. Dirty tree → show the files. If none of them is a file adoption writes or merges (`CLAUDE.md`, `AGENTS.md`, `.claude/**`, `.mcp.json`, `.gitignore`, `docs/**`, `scripts/hooks/**`, `scripts/tw-run`, `.teamwright/**`), continue: you stage by path and never touch them — say so once. Otherwise ask the owner to commit those files themselves first (you do not stash).
3. Propose a working branch (`teamwright-adopt`); create it only on "yes".

## 2. Inventory

Run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" inventory --json` and explain the findings in a short table, plain words:

- existing `CLAUDE.md` / `AGENTS.md` (size, stale statements you can see), `.claude/agents/**`, commands, skills, settings hooks, `.claude/settings.local.json` (local; only report whether its allow rules overlap the teamwright deny list — do not print it);
- `.mcp.json` servers; spec tool directories; `providers_detected`;
- languages, test directories, CI workflows, build files, lock files; **versions** as the inventory read them from manifests and lock files — use only these; a version not found in a manifest is written as unknown, never guessed or taken from memory;
- **CI that masks failures** (`|| true`, `--passWithNoTests`, lint `--fix` in CI, `continue-on-error`) — read the workflow files for this; and the **container images** CI jobs run in (`container:`, `image:`, a `docker run` step) — step 5 uses them;
- **unfilled template docs**: `docs/plan.md`, `docs/requirements.md`, `docs/open-questions.md` still identical to the template — list them; they are filled in step 3 or reported in Next steps;
- secret-looking files (tracked / untracked / ignored) and large binaries in the tree;
- git state: `core.hooksPath` (another hook manager?), legacy `.git/hooks`.

## 3. Product goal — before tools and tasks

Ask the owner, in one question: **"What should the next release achieve?"** (a store release, a feature, a customer milestone, a deadline). Offer two or three candidates you can see in the repository (open issues, TODOs, a release checklist, a store or platform requirement) and "only hygiene for now". Then ask for hard constraints (date, platform policy, budget).

The answer is used three times: it goes into `docs/plan.md` (and the goal's acceptance into `docs/requirements.md`) in the owner's words — unknowns go to `docs/open-questions.md`; it shapes the first sprint (step 13); and it is repeated in Next steps. "Only hygiene" is a valid answer — record it as such.

## 4. Tools — one short question per capability

For each capability in order `spec`, `context`, `docs`, `ui_verify`, `api_verify`: show what is already present first (from `providers_detected`, `.mcp.json`, files), then the default, then alternatives — the list is the files in `${CLAUDE_PLUGIN_ROOT}/providers/<capability>/`. Read the chosen adapter's front matter, `## When it fits` (where present) and `## Install`.

- Defaults: `spec-kit`, `serena`, `context7`, `api_verify: project-runner`.
- **Something already in place wins over the default only if it covers the need** (an existing Spec Kit or OpenSpec directory; an existing e2e suite that can drive every flow the product has).
- **`ui_verify`**, decided in this order:
  1. No UI → `none`.
  2. Web → `playwright`.
  3. Mobile app that relies on **system dialogs or permissions** (runtime permissions, notifications, pickers, the share sheet, another app) → `patrol` (Flutter) or `maestro` (any framework). Plain `flutter-integration-test` cannot press native dialogs, so it does not cover the need even when an `integration_test/` directory exists. Patrol builds on `integration_test`, so existing tests carry over — say this when you ask.
  4. Otherwise: Flutter → `flutter-integration-test`; native Android/iOS → `espresso-xcuitest`; black-box across frameworks → `maestro`.

  Then check that the runner can run: a device, emulator or simulator is visible (`flutter devices`, `adb devices`, `xcrun simctl list devices booted`), and the runner binary exists. Either `e2e_ui_command` is run once in step 10, or — no device, binary not installed, native setup still to do — you write a first-sprint task "make `e2e_ui_command` run" with the exact blocker. A chosen UI runner with neither a successful run nor that task is not allowed.
- **Installing:** for each chosen provider that is missing, show the adapter's install commands with their source link and ask. MCP servers are added by `apply` into `.mcp.json` — ask before that too. Secrets (API keys) go into the environment, never into `.mcp.json` or config.
- Spec tool init (`specify init --here --force ...`, `openspec init`) writes files into the repository: run it only after the baseline commit and the owner's "yes", then show `git status`.

## 5. Areas, commands and the toolchain runner

1. **Areas**: one per independently built part (e.g. `backend`, `app`, `web`), from build files and directory layout. Show the proposal; the owner confirms names (lower-case).
2. **Per area propose** `source_dirs`, `test_dirs`, `stack`, `conventions`, `test_framework`, `test_helpers`, `workdir`, `test_command`, `lint_command` (no auto-fix flags), `api_test_command`, `e2e_ui_command`, `generate_command` — from package scripts, Makefile/justfile, pyproject/tox, pubspec, gradle, CI steps. **Commands are written without any wrapper** (`flutter test`, not `docker run … flutter test`); the runner applies it. Code generation that changes tracked files (l10n, build_runner, protobuf, ORM clients) goes into `generate_command`, run separately before the gate — the gate itself must not modify tracked files.
3. **Toolchain, per area**: for every binary the area's commands need, `command -v <bin>`.
   - All present → `runner: host`.
   - Missing, and CI already runs this area in a container image → propose **`runner: docker` with that exact image** as the default (same image as CI, so local results match CI), plus `cache:` for the package cache (e.g. `.pub-cache`, `.npm`, `.gradle`).
   - Missing, no CI image → ask: **Docker** with the official image pinned to the version from the manifest or lock file (name the image and its source page), or **install on the host** (show the official install command and its link). Docker first when `docker` is on PATH.
   - Docker is not available either and the owner declines a host install → the command is recorded as "not runnable" with a first-sprint task; it is never written as if it ran.
   - `e2e_ui_command` needs a device or emulator, which a container rarely has: a UI runner on the host with a device, or the task from step 4.

   Record `runner`, `image`, `cache`, `workdir` in the area. Once installed, everything runs through `scripts/tw-run <area> -- <cmd>`; placeholders render per-area commands that way automatically.
4. **Gate**: `gate_command` — the aggregate the CI should run (typecheck + lint + unit tests per area). Prefer an existing `make check`-style target; otherwise propose the `&&` chain and offer a `Makefile` target as a first-sprint task. `gate_command` is not wrapped automatically: for an area with `runner: docker`, its part of the gate is written as `scripts/tw-run <area> -- <cmd>` (or the Makefile target calls it that way).
5. `version_check` (how to read the commit the running system was built from) and `verify_environments` (`local`, `staging`, `production-like` — never hosts). Missing version endpoint → first-sprint task.

Commands are run once, all together, in step 10 — not here.

## 6. Write the config

Show the full config (schema: `docs/process/plugin.md`), then write it with the Write tool. Start from `${CLAUDE_PLUGIN_ROOT}/template/.teamwright/config.example.yml`: `version: 1`, `mode: gate-first`, `process_version` as in the example, the chosen `tools`, the areas from step 5, `language`.

- First adoption (no teamwright gates installed) → `.teamwright/config.yml`.
- Gates already installed (re-adoption, or any later change) → `.teamwright/config.next.yml`, and pass `--config .teamwright/config.next.yml` to `plan` and `apply`.

## 7. Secret scan — before any hook is enabled

`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" scan`. Report the summary by class (secret-like / config placeholder / test fixture / docs example): only **secret-like** findings block and need action; the other classes get one line each. For each secret-like finding (path and rule only, never the value):

- **tracked** → the secret is in history: tell the owner to rotate it; purging history is the owner's decision and is never done by you; add a first-sprint task;
- **untracked, not ignored** → propose the `.gitignore` line; the pre-commit hook will refuse it later anyway;
- **false positive** → the owner may mark the line with `teamwright:allow-secret`.

## 8. Plan

`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" plan --json`. Summarise: files to create, updates, tool blocks, settings and `.mcp.json` merges, git hooks, `scripts/tw-run`, **conflicts**, unresolved placeholders, notes. Unresolved placeholders → add the missing config keys (back to step 6) or accept `{{NAME}}` left for the owner. With `--dry-run` in the arguments, stop here.

## 9. Resolve conflicts with the owner — one file at a time

The installer never overwrites a file it did not write; conflicts are yours to merge, always as a diff the owner approves.

- **`CLAUDE.md`** → convert the existing file into the map format of `${CLAUDE_PLUGIN_ROOT}/template/CLAUDE.md`: Project, Where things live, Decision index, What you must know before opening any file, Commands, Rules. **Preserve every fact verbatim** — move, don't paraphrase; check mechanically that no line was lost. Long explanations move to `docs/decisions/<area>.md` or `docs/architecture.md` and are linked. Statements that look stale (contradicted by the code) are listed for the owner under "To confirm", not deleted. Keep it under ~150 lines. Commands in it use `scripts/tw-run` for docker areas.
- **`AGENTS.md`** → keep the project's own rules in a `## Project rules` section, add the teamwright sections and the tool markers from the kit's version.
- **Existing agents** (`.claude/agents/**`) → a table: existing agent → teamwright role (`problem-investigator`, `test-writer`, `developer`, `technical-writer`, `code-reviewer`, `task-validator`) → keep / replace / merge. Domain specialists, ops commands and project skills are **kept**. A duplicate of a teamwright role (e.g. a stack-specific test writer) is replaced only with consent; its useful stack conventions move into the area's role file outside the markers. Removal is `git rm` on "yes" (recoverable from history). An existing file named like a teamwright role → merge, never overwrite.
- **Existing decision records** (`docs/adr/`, `docs/decisions/`) → link them from `docs/decisions.md`, do not copy.
- **`core.hooksPath` set by another hook manager** → show both options: chain the manager's hooks from `scripts/hooks/*`, or call teamwright's hooks from the manager. Owner decides.
- **`scripts/hooks/patch-guard.conf`** → propose signatures for the project's languages (allowlists, special cases, regex branches in this codebase) as a diff.
- Invalid `.claude/settings.json` or `.mcp.json` → show the parse error; the owner fixes it.

After a file is merged by hand, record it so `plan` stops reporting it as a conflict: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" apply --accept <path>`.

## 10. Apply, then check every command

1. `apply --dry-run` first and show the summary; on "yes": `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" apply` (with `--config .teamwright/config.next.yml` when step 6 wrote a proposal). Then `bash scripts/install-hooks.sh --check`, run the secret scan again, and show `git status`. Run the chosen tools' post-install steps that the owner approved (e.g. a code index).
2. **Run every configured command once**, after saying it may take a while (a first docker run pulls the image): `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" check-commands`. **Run it in the foreground and wait for it** — never in the background — and **edit no file while it runs**: it compares `git status` before and after each command, and your own edits in the meantime would be blamed on the command. Report **every** command as a table — area · command · runner · result (`pass` / `fail` with counts and the first failures / `not runnable` with the reason) · duration. Also report whether the run left `git status` unchanged:
   - "gate modifies tracked files" (a change inside the area's `workdir`) names the files and becomes a task (move that step into `generate_command`, or fix the test) — do not revert with git;
   - a note "tracked files outside workdir … changed during the run" is not a failure: say which files and whether you or the owner changed them meanwhile; if nobody did, the command writes outside its area — a task;
   - `not runnable` with `environment (...)` (a database or service not listening, a missing binary, no Docker daemon, no device) is not a code failure: the command could not exercise the code. It becomes a task to provide that environment (e.g. a throwaway database for API tests), not a task to fix the code. The patterns are heuristics (`docs/process/plugin.md`): read the log when the reason looks wrong.
3. **A failing command is expected in many projects; it decides the mode, it does not stop adoption.** Explain gate-first right here, in plain words: "the gate is red, so the analysis, review and verify gates will **warn** instead of block until it is green; each failing command gets a first-sprint task; blocking is switched on with `enforce` when they are done." All green → offer `enforce` now (step 14).
4. A command that is `not runnable` is fixed now through `config.next.yml` + `apply --config` (another runner, another image, a missing script) and checked again, or it becomes a first-sprint task with the exact blocker.

## 11. When the gates take effect — say this exactly

- **Hooks** written to `.claude/settings.json` are picked up by Claude Code's settings file watcher **in this same session**: the analysis, review and verify gates and the state guard are live as soon as `apply` finishes (in gate-first mode they warn). The owner can check them with `/hooks`. Git hooks (`core.hooksPath`) are active immediately for every git command.
- **Subagents**: edits to `.claude/agents/*.md` are picked up within seconds — except when the `.claude/agents/` directory did not exist when the session started; then the new roles load only after a restart.
- **MCP servers** added to `.mcp.json` connect at session start, after the owner approves them in the prompt Claude Code shows: restart Claude Code to use them. **Check, do not assume**: for every chosen provider with an MCP server, see whether its tools are available in this session (or run `claude mcp list` when the CLI is available). Not connected → it goes into Next steps as "restart Claude Code and approve the MCP server(s) <names>; until then the roles fall back to built-in search". `/teamwright:flow` repeats this check at start.

So a restart is needed only when this adoption created `.claude/agents/` or added MCP servers; otherwise the owner can continue in this session.

## 12. Every task has a failure branch

**Blocking open questions go into `blocked_on`.** When a task cannot be analysed or started before an open question is answered (its Context or Acceptance says "resolve OQ-NN first", or the answer decides the approach), set `blocked_on: OQ-NN` (several: `OQ-02, OQ-05`) in the front matter — a sentence in the body is not seen by the router. `tw-next.py` keeps such a task out of the ready set until the question is `answered` or `dropped` in `docs/open-questions.md`, and warns about a task that mentions an unresolved `OQ-NN` with an empty `blocked_on`.

**Prerequisites and priority.** The router lets a prerequisite inherit the highest priority of the open tasks that wait on it (`depends_on`), so a P2 characterization-test task in front of a P1 fix is worked as P1. Give each task its own honest priority; do not inflate prerequisites by hand.

Every task record you create — here, in step 13 or later — has an `## Acceptance` section with at least one observable success criterion **and a failure branch**: the input, state or condition under which it must still behave correctly (or fail visibly), and how that is observed. A chore has one too (e.g. "CI fails the job when a test fails — checked by a deliberately failing test on a branch"). Fill `seam` when the task touches code and you can name it; otherwise write "to be found in analysis".

## 13. First sprint — toward the goal, from the findings

Create `docs/sprints/1.md` from `docs/sprints/_sprint-template.md` and one `docs/tasks/T-NNN.md` per task from `docs/tasks/_task-template.md` (`status: TODO`, honest `surface`, `priority`, `class`, `deploys`, `depends_on`). The sprint has two parts:

**A. Hygiene that blocks the process** (only what was actually found):

1. CI stops masking failures — `surface: none`;
2. failing command / red gate → one task per area to make it green (typecheck, lint, failing tests) — no behaviour change, `surface: none`;
3. not-runnable commands, "gate modifies tracked files", a UI runner that has not run (step 4) — each with its exact blocker;
4. secrets in history → rotation task (owner action noted);
5. missing verification capability: an API smoke against a running service with a base URL from the environment, a version endpoint for the deploy smoke;
6. stale docs found in step 9.

**B. First steps toward the goal from step 3** — at least one task that moves the product, not only the process (unless the owner said "only hygiene"). **When a goal task changes code that has no tests, a characterization-test task for that code comes first** (`depends_on`), capturing current behaviour before anything changes. Find untested code by comparing the goal's likely seams with the test directories — do not wait for the inventory to call something legacy.

Large items (more than one seam, unsettled behaviour) are marked to go through the spec tool first. Show the list with order and dependencies; the owner reorders or drops. Goal work that does not fit sprint 1 goes into a short "sprint 2 backlog" list in `docs/sprints/1.md`.

Commit once, on one "yes" for the whole list (task records, merged files, config), staged by path: `chore(task): T-001 →TODO` etc. for the tasks, `chore: adopt teamwright` for the rest.

## 14. Gate-first, then enforce

In `gate-first` mode the analysis, review and verify gates **warn** (to the owner and the model) instead of blocking, so the team can work while the gate is red. Git hooks (secret scan, DRAIN on push, patch-guard) are active from now on regardless of mode. When every command in `check-commands` passes and the first-sprint gate tasks are `DONE`, switch on blocking: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" enforce` — ask first; `/teamwright:status` shows when the project is ready.

## Report

```
Adopted: <project> · areas <names> · mode gate-first
Goal: <next release goal, owner's words | only hygiene>
Tools: spec=<…> context=<…> docs=<…> ui_verify=<…> api_verify=<…> (installed: <…>; declined: <…>)
Runners: <area>=host | <area>=docker <image>
Commands: <n pass, n fail, n not runnable> (table above) · gate modifies tracked files: <no | files>
Conflicts: <file — resolved how / accepted | left for owner>
Secrets: <n secret-like (tracked/untracked) — actions; n placeholders/fixtures/examples ignored>
Sprint 1: T-001 … T-00N (hygiene: …; goal: …)
```

### Next steps (mandatory — never end without it)

1. **Status**: one line each — branch (`teamwright-adopt`; how to merge it when the owner is ready), mode and what makes it `enforce`, which gates are live now and whether a restart is needed (step 11) — when MCP servers were added or are not connected, name them: "restart Claude Code to load MCP servers <names>".
2. **Unresolved**: commands not run and why (environment vs code); UI runner not yet runnable; template docs still unfilled (`docs/plan.md`, `docs/requirements.md`, `docs/open-questions.md`); versions marked unknown; conflicts left; owner decisions pending (secret rotation, history purge, hook manager).
3. **Order of work**: after the commit, run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --json` and present its decision — `task` and `reason` first, then `alternatives` in its order — plus any `warnings` (fix a missing `blocked_on` before offering). **Do not compute your own order**: the recommendation and the router must never diverge. You may add one line of context after the router's reason (e.g. "the gate is red, so every backend task is red until T-002 is done"); if you think the router is wrong, say so and why, but still offer its pick first.
4. **Offer**: "Start `/teamwright:flow` on <router's task> — <title>?" — on "yes", invoke `/teamwright:flow`.
