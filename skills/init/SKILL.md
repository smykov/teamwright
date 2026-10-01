---
name: init
description: Start a NEW project on the teamwright process — product goal, stack and areas, tools per capability, a runnable toolchain (host or container), docs scaffolding, hooks, a gate that is green from day one, every command checked once, the first spec through the chosen spec tool, and next steps. Run from the (empty or nearly empty) repository root.
argument-hint: "[short description of the product]"
disable-model-invocation: true
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" inventory *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" plan *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" check-commands *) Bash(git status *) Bash(command -v *)
---

# /teamwright:init — a new project on the teamwright process

Product idea from the owner: `$ARGUMENTS`.

Installer: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" <inventory|plan|apply|scan|check-commands|enforce> [--project PATH] [--config FILE] [--dry-run] [--json]`. Config schema: `${CLAUDE_PLUGIN_ROOT}/docs/process/plugin.md`; capabilities: `${CLAUDE_PLUGIN_ROOT}/docs/process/tools.md`; adapters: `${CLAUDE_PLUGIN_ROOT}/providers/`.

Same ground rules as `/teamwright:adopt`: ask before installing anything, pulling an image, adding an MCP server, running a tool's `init`, or committing; no destructive git; no secrets in files; after the first `apply`, config changes only through `.teamwright/config.next.yml` + `apply --config` (never a hand edit of `config.yml`, by you or the owner); never write a command that does not run. The repository has code already → stop and suggest `/teamwright:adopt`.

## 1. Repository

`git status`. No repository → ask, then `git init`. Run `inventory --json` to confirm it is empty enough.

## 2. Product goal, stack and areas

First ask **"What should the first release achieve?"** — who uses it, the one flow that must work, any hard constraint (date, platform, store policy). It goes into `docs/plan.md` / `docs/requirements.md` in the owner's words and drives the first spec (step 6).

Then ask briefly: what is built (web app, API, mobile app, library, CLI), languages and frameworks, one area or several (e.g. `api` + `app`). If the owner is unsure, recommend one stack and say why in one line. Scaffolding the application itself (framework generators) is the owner's choice: show the official generator command and run it only on "yes".

## 3. Tools

One question per capability with the default first (as in `/teamwright:adopt` step 4): `spec-kit`, `serena`, `context7`, `api_verify: project-runner`, and `ui_verify` by the same rule as adopt — no UI → `none`; web → `playwright`; a mobile app that will rely on system dialogs or permissions → `patrol` (Flutter) or `maestro` (any framework), never plain `flutter-integration-test`; otherwise Flutter → `flutter-integration-test`, native → `espresso-xcuitest`. Show each adapter's install commands and source link; install on "yes". Check that a device or emulator is available for a mobile runner; if not, `e2e_ui_command` becomes a first-sprint task with that blocker.

## 4. Toolchain, commands and a green gate from day one

**Toolchain per area**: `command -v` for every binary the stack needs. Present → `runner: host`. Missing → ask: **Docker** with the official image pinned to the chosen version (name the image and its source page; the CI uses the same image) or **install on the host** (official install command and link). Record `runner`, `image`, `cache`, `workdir` in the area; commands are written without a wrapper and run through `scripts/tw-run <area> -- <cmd>`.

Per area: `test_command`, `lint_command`, `api_test_command`, `e2e_ui_command`, `generate_command` (codegen, run before the gate — the gate must not modify tracked files) for the chosen stack, verified to exist once the stack is scaffolded. `gate_command`: a `make check` (or equivalent) target that runs lint + typecheck + tests for every area — create it now (docker areas call `scripts/tw-run <area> -- <cmd>` in it). With no code yet, the gate runs an empty or smoke test suite and must be green.

## 5. Config, apply, hooks

Show and write `.teamwright/config.yml`. `plan`, then `apply --dry-run`, then `apply` on "yes". `bash scripts/install-hooks.sh --check`; `scan`.

Then `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" check-commands` and report **every** command (area · command · runner · pass / fail / not runnable · duration) and whether `git status` stayed unchanged. All pass → `mode: enforce` right away (run `enforce` on "yes"). Anything fails → stay `gate-first` and explain it: the analysis, review and verify gates warn instead of blocking until the gate is green; the failing command is fixed now (through `config.next.yml` + `apply --config` when the config is wrong) or becomes the first task.

When the gates take effect — say it as in `/teamwright:adopt` step 11: hooks in `.claude/settings.json` apply in this same session (settings file watcher; check with `/hooks`); a `.claude/agents/` directory created in this session and new `.mcp.json` servers need a restart.

Fill `CLAUDE.md` (map format, kept short), `docs/requirements.md` and `docs/plan.md` from the conversation — only what the owner said; unknowns go to `docs/open-questions.md`. Any of the three still identical to its template is listed in Next steps.

## 6. First spec through the chosen spec tool

The first feature is large by definition (behaviour not settled):

- `spec-kit` → `specify init --here --integration claude` (on "yes"), `/speckit-constitution` pointing to `PRINCIPLES.md`, then `/speckit-specify <idea>` → `/speckit-clarify` → `/speckit-plan` → `/speckit-tasks`;
- `openspec` → `openspec init` (on "yes"), then `/opsx:propose <idea>`;
- `none` → `docs/specs/<name>.md` (problem, behaviour with a failure branch, decisions, open questions, task breakdown).

The owner reviews the spec. Then create `docs/sprints/1.md` and `docs/tasks/T-NNN.md` from the templates, each with `design_ref` to its section, an honest `surface`, and an `## Acceptance` section with a success criterion **and a failure branch** (the input or condition under which it must still behave correctly, and how that is observed). The spec tool's implement/apply step is never used.

## Report

```
Initialized: <project> · areas <names> · mode <enforce|gate-first>
Tools: spec=<…> context=<…> docs=<…> ui_verify=<…> api_verify=<…>
Goal: <first release goal, owner's words>
Runners: <area>=host | <area>=docker <image>
Gate: <command> — <green|red> · Commands: <n pass, n fail, n not runnable>
Spec: <path> · Sprint 1: T-001 … T-00N
```

### Next steps (mandatory — never end without it)

1. **Status**: mode and what makes it `enforce`; gates live now; restart needed or not (and why).
2. **Unresolved**: commands not run and why; UI runner without a device; template docs still unfilled; open questions for the owner.
3. **Order of work**: sprint 1 in the order the router will take it.
4. **Offer**: "Start `/teamwright:flow` on <first ready task id> — <title>?" — on "yes", invoke `/teamwright:flow`.
