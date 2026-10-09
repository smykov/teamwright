---
name: init
description: Start a NEW project on the teamwright process — requirements first (the owner's brief as the base, or an interview, then a roast by a fresh requirements-reviewer until approved), then the stack the requirements call for, a walking skeleton with a green gate and CI from day one, enforce mode, specs and tasks derived from the requirements through the chosen spec tool, sprint 1, and the offer to start /teamwright:flow. Run from the (empty or docs-only) repository root.
argument-hint: "[path to a brief | short description of the product]"
disable-model-invocation: true
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-progress.py" *) Bash(bash scripts/install-hooks.sh *) Bash(git status *) Bash(git log *) Bash(git init *) Bash(git add *) Bash(git commit *) Bash(command -v *) Bash(make *) Bash(ls *) Read Write Edit Agent AskUserQuestion Skill
---

# /teamwright:init — a new project on the teamwright process

Input from the owner: `$ARGUMENTS`.

Installer: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" <inventory|plan|apply|scan|check-commands|enforce> [--project PATH] [--config FILE] [--accept PATH] [--dry-run] [--json]`. Config schema: `${CLAUDE_PLUGIN_ROOT}/docs/process/plugin.md`; capabilities: `${CLAUDE_PLUGIN_ROOT}/docs/process/tools.md`; adapters: `${CLAUDE_PLUGIN_ROOT}/providers/`.

`/teamwright:adopt` fits the process to a project that exists; init builds the project to the process, so nothing excuses a red gate: init ends in `enforce`.

Order: **requirements → tools → stack, skeleton and gate → install → specs and tasks → sprint 1 → flow.** Nothing technical is chosen before the requirements are approved.

Ground rules as in `/teamwright:adopt`: ask once at the start whether to commit each step as it is done (the requirements step reuses the answer), and ask the setup consents of step 4 (scaffold, apply, enforce) as one block when the plan is clear; ask before installing anything, pulling an image, adding an MCP server, running a tool's `init`, scaffolding, or committing; no destructive git; no secrets in files; after the first `apply`, config changes only through `.teamwright/config.next.yml` + `apply --config`; never write a command that does not run. Everything written into the repository is in English.

## 1. Repository

`git status`. No repository → ask, then `git init`. Run `inventory --json` and read `kind`:

- `empty` or `docs-only` → continue. A docs-only repository's documents are the base of the requirements (step 2) and are never overwritten: a template file that would replace one goes through `apply --accept` only after its content was carried over.
- `code` → stop and offer `/teamwright:adopt` — unless this is an interrupted init: `docs/requirements.md` is approved and the code is the skeleton from step 4. Then resume from the first step whose result is missing.

## 2. Requirements — `/teamwright:requirements`

Invoke `/teamwright:requirements` with `$ARGUMENTS`. It takes the owner's brief as the base or interviews the owner, has a fresh `requirements-reviewer` roast the draft until it is `READY`, and gets the owner's approval. Do not continue until `docs/requirements.md` is approved.

The approved document carries section 9 — **technical decisions**: stack and areas, what "deployed" means, where verification runs. They were derived from the requirements during the roast and approved with them; steps 3–4 use them and do not re-ask.

Before the templates are installed (step 5), the requirements skill writes `docs/requirements.md` from `${CLAUDE_PLUGIN_ROOT}/template/docs/requirements.md` and spawns the reviewer from `${CLAUDE_PLUGIN_ROOT}/template/.claude/agents/requirements-reviewer.md` (pass the role file's instructions in the prompt when the agent is not installed yet). `apply` later keeps the filled file.

## 3. Tools

Propose the tools as **one block** the owner confirms or changes (one question, not one per capability): per capability the proposal, what `inventory` detected on the host, and the alternatives. The proposal respects the install policy in section 6 — a default that needs a forbidden download (Spec Kit's templates, a remote MCP server) is replaced by the best allowed option, usually `none` or `builtin`. A capability with one provider (`api_verify: project-runner`) is stated, not asked. **`ui_verify` follows section 9** when it decided UI verification ("no UI runner in release 1" → `none` with `ui_verify_deferred`; a runner with an adapter → that runner; a runner without an adapter, e.g. a headless browser on the host → `none` with `ui_verify_deferred`, and a sprint-1 task to write the UI check as a test the project runner can run); otherwise the rule — no UI → `none`; web → `playwright`; a mobile app that relies on system dialogs or permissions → `patrol` (Flutter) or `maestro` (any framework), never plain `flutter-integration-test`; otherwise Flutter → `flutter-integration-test`, native → `espresso-xcuitest`. Show each adapter's install commands and source; install on "yes". A mobile runner needs a device or emulator: check it; if missing, the UI runner becomes a sprint-1 task with that blocker. A tools choice that contradicts section 9 goes back to the owner: either a new requirements version or a row in `docs/decisions.md`.

The alternatives per capability are the files in `${CLAUDE_PLUGIN_ROOT}/providers/<capability>/` — list them with the question. A provider with an MCP server (its adapter's `mcp:` block) adds that server to `.mcp.json`, which the runtime starts at the next session (often through `npx`, a network fetch): ask about the server separately; "no" → add the capability to `no_mcp: [...]` in the config and the tool is used through its CLI only.

## 4. Stack, walking skeleton, gate, CI

**Toolchain per area** (areas from section 9): `command -v` for every binary the stack needs. Present → `runner: host`. Missing → when section 6 already forbids installs and downloads, do not ask again: use what the host has and record the missing check as a decision (`docs/decisions.md`), not as a task nobody may finish. Otherwise ask: **Docker** with the official image pinned to the chosen version (name the image and its source page; CI uses the same image) or **install on the host**. Record `runner`, `image`, `cache`, `workdir`; commands run through `scripts/tw-run <area> -- <cmd>`. The owner declines both → use what the host has and record the missing check (typecheck, a linter): a sprint-1 task when it can be done later, a decision when the policy rules it out; the report lists it.

**Scaffold** each area with its official generator, if the stack has one (show the command; run on "yes"). Then the **walking skeleton** — the thinnest end-to-end slice that runs:

- the application starts (an API answers, an app builds and opens);
- **one real test per area** that exercises it — not an empty suite: an empty suite either passes without checking anything or fails (`jest` with no tests exits 1);
- the running system **reports its version and commit** (a `/version` endpoint, a build-info screen or log line), so verification can check that it tests the commit it claims;
- a **generate command** for codegen, if the stack generates code, run before the gate, so the gate never modifies tracked files.

**Gate**: per area `test_command`, `lint_command` (with typecheck where the language has one), `api_test_command`, `e2e_ui_command`, `generate_command`; `gate_command` is a `make check` (or equivalent) target over every area.

**CI** from day one: a workflow that runs the same `gate_command` in the same image on every push and pull request, without `|| true`, `continue-on-error` or `--passWithNoTests`. A gate that is green only locally is not green. For a `runner: host` area, CI uses the hosted runner with the language's official setup action pinned to the version the deploy target runs (the lowest one the project supports), plus whatever the gate needs (`make`). Task bookkeeping does not trigger it: the `push` trigger carries `paths-ignore: ["docs/tasks/**"]` (most commits of a teamwright project are `chore(task)` records; the workflow is skipped only when every changed file matches, so code still always runs). On pull requests the path filter sees the whole PR diff, so it never skips: the gate job runs behind a `changes` job with `scripts/tw-ci-changes`, which skips it when the push since the previous run carried only records ([usage](../../docs/usage.md#ci-record-only-pushes)). Never `[skip ci]` on status commits: the `→CODE_COMPLETE` commit is the tip of every delivery. An area whose tests the host cannot run (another platform) gets `ci_workflow: <file>` in the config, and that workflow also triggers on `push` to `wip/**`: the flow confirms red and green there before review.

**Deploy target** — what section 9 says "deployed" means, set up far enough to verify against: a local run command at minimum (`verify_environments: local`); a staging deploy, or a CI build artifact installed on an emulator, when the requirements ask for it. What cannot be set up now becomes a sprint-1 task.

## 5. Config, apply, hooks, enforce

**Process settings** — one question block before the config is written (AskUserQuestion, recommended first; table and consequences in `${CLAUDE_PLUGIN_ROOT}/skills/settings/SKILL.md`): review blocking threshold (`medium` recommended — Low findings become follow-ups instead of send-backs; Critical and dangerous categories always block), tasks per flow pass (3, P1 capped at 2, P0 alone), autonomy (`start: auto`, `continue: true` — the flow takes the next ready task after a barrier; push stays the owner's call). Write the answers as `process:` in the config and one row in `docs/decisions.md`. An answer "keep it as it is" leaves the keys out (defaults: every finding blocks, one task per pass, ask before starting). Later changes: `/teamwright:settings`.

Show and write `.teamwright/config.yml` with every placeholder `plan` would report as unresolved (`conventions`, `test_helpers`, ...) already filled from the scaffold. `plan`, then `apply --dry-run`, then `apply`. `bash scripts/install-hooks.sh --check`; `scan`. Commit the skeleton and the install before `check-commands`: on an uncommitted tree its "modifies tracked files" check sees nothing.

Run `check-commands` **in the foreground and change nothing while it runs** (a parallel edit is reported as "the gate modifies tracked files"). Report every command (area · command · runner · pass / fail / not runnable · duration) and whether `git status` stayed unchanged. `check-commands` runs the area commands, not `gate_command`: run the gate once yourself for the report.

All pass → `enforce` (run it on "yes"). Anything fails → fix it now (through `config.next.yml` + `apply --config` when the config is wrong). Stay in `gate-first` only for a command that cannot run without the owner (a device, an account): it becomes a sprint-1 task, and the report says what switches the project to `enforce`. A UI runner whose command cannot run yet is reported as not runnable: the project stays `gate-first` until it runs, or the owner decides to go without UI verification for now — record it in `docs/decisions.md` and set `ui_verify_deferred: "decisions.md #N"` in the config, so `check-commands` notes it instead of failing. After `enforce`, every `config.next.yml` keeps `mode: enforce` (apply refuses to lower it).

When the gates take effect, as in `/teamwright:adopt` step 11: hooks in `.claude/settings.json` apply in this session; a `.claude/agents/` directory created in this session and new `.mcp.json` servers need a restart.

Fill `CLAUDE.md` (map format, short; stack, commands and gate taken from the config), `docs/plan.md` (goal and release 1 from the requirements), `docs/architecture.md` (areas and how they talk, from section 9) and `docs/decisions.md` (the owner's decisions so far). Commit on "yes".

## 6. First specs — from the approved requirements

The spec tool builds the full flow of work from `docs/requirements.md`, feature by feature along the release-1 slice of the story map (section 3):

- `spec-kit` → `specify init --here --integration claude` (on "yes"); `/speckit-constitution` from `PRINCIPLES.md` and the non-functional requirements; then per release-1 feature: `/speckit-specify` (input: the feature's section and its `FR-NN` / `NFR-NN`) → `/speckit-clarify` → `/speckit-checklist` (requirement quality for this feature) → `/speckit-plan` → `/speckit-tasks` → `/speckit-analyze` (spec, plan and tasks agree). `/speckit-implement` is never used: implementation goes through `/teamwright:flow`.
- `openspec` → `openspec init` (on "yes"), then `/opsx:propose` per release-1 feature.
- `none` → `docs/specs/<feature>.md` per feature: problem, behaviour with the failure branch, decisions, open questions, task breakdown. The owner reviews the specs before tasks are created from them — all of them as one review ("accept all", or which to change) (the `none` adapter's rule; Spec Kit and OpenSpec have their own review points).

A spec that contradicts the approved requirements is a finding for the owner, not a silent change: either the spec follows the requirements, or the requirements get a new version.

Turn the spec tool's tasks into `docs/tasks/T-NNN.md` from the template: `design_ref` to the spec section, the requirement ids in Context, an honest `surface` and `deploys`, and `## Acceptance` with a success criterion **and a failure branch** taken from the requirement's failing example (a chore that traces to no requirement states its own: what must still work, or fail cleanly, after it).

**Traceability**: every Must requirement of release 1 — functional and non-functional is covered by at least one task. List any that is not, and do not continue until each is covered or the owner moves it out of release 1.

## 7. Sprint 1

`docs/sprints/1.md` from the template: the sprint goal (the release-1 flow, or its first part) and the tasks in the router's order (`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --json`). **T-001 is the first end-to-end slice of the release-1 flow** on the walking skeleton (`deploys: true`, a real `surface`), not "set up the project". While the UI runner cannot run yet, T-001 takes the part of the slice that can be verified (`surface: api`), and a task that makes the UI runner work comes before the first `surface: ui` task (`depends_on`) — unless UI verification is deferred (`ui_verify_deferred`): then UI tasks carry a reviewed `verify_exception` and depend on nothing that cannot happen. Sprint 1 also covers what steps 4–5 could not finish (deploy target, UI runner, a command not yet runnable). Commit on "yes".

**Progress report.** With more than one area, a release-1 milestone in `docs/plan.md`, or task lists kept outside `docs/tasks/`, adapt `/teamwright:progress` (section 3 of `${CLAUDE_PLUGIN_ROOT}/skills/progress/SKILL.md`) and add its files to the same commit; otherwise the generic report needs nothing.

## Report

```
Initialized: <project> · areas <names> · mode <enforce|gate-first>
Requirements: docs/requirements.md v<N> approved · roast rounds <n> · open questions <ids|none>
Stack: <section 9 in one line> · deployed means: <...> · verify in: <...>
Tools: spec=<…> context=<…> docs=<…> ui_verify=<…> api_verify=<…>
Runners: <area>=host | <area>=docker <image>
Gate: <command> — <green|red> · CI: <workflow> · Commands: <n pass, n fail, n not runnable>
Specs: <paths> · Must requirements covered: <n>/<n>
Sprint 1: <goal> — T-001 … T-00N
Settings: review.blocking <…> · pass <n> (P1 <n>) · autonomy <start>/<continue> | defaults
Progress: /teamwright:progress <adapted: milestone … | generic>
```

### Next steps (mandatory — never end without it)

1. **Status**: mode and, if `gate-first`, what switches it to `enforce`; gates live now; restart needed or not (and why).
   Add one line: **another machine** — a clone is offered the plugin from the project settings (`extraKnownMarketplaces`: name the source; the install note when there is none), then needs `bash scripts/install-hooks.sh` once; the session-start check names what is missing.
2. **Unresolved**: open questions, commands not run and why, UI runner without a device, requirements not yet covered.
3. **Order of work**: sprint 1 in the router's order.
4. **Offer**: "Start `/teamwright:flow` on T-001 — <title>?" — on "yes", invoke `/teamwright:flow`.
