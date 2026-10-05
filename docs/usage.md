# Using teamwright

Details behind the [README](../README.md) quickstart: what onboarding does, how gates switch from warning to blocking, how `/teamwright:flow` picks work, toolchain runners, configuration changes, updating and installing without the plugin.

## Onboarding: `/teamwright:adopt` and `/teamwright:init`

`/teamwright:adopt` (existing project) works through these steps and asks before every install, image pull, MCP server, rewrite or commit:

1. Inventories the repository: context files, agents, CI, build files, test directories, spec tool, secrets-looking files.
2. Asks what the next release should achieve.
3. Asks one short question per tool capability, offering tools already present first ([tools.md](process/tools.md)).
4. Proposes code areas with their test, lint, API and end-to-end commands, and a runner that can actually execute them: the host, or the container image your CI already uses.
5. Writes `.teamwright/config.yml` and shows every conflict. Your `CLAUDE.md` becomes a short map with its facts preserved; your agents are mapped to teamwright roles, and project-specific ones are kept.
6. Installs the hooks and scans the whole tree for secrets.
7. Runs every configured command once and reports each result.
8. Proposes a first sprint: hygiene tasks plus first steps toward the release goal.
9. Ends with next steps and offers to start `/teamwright:flow`.

`/teamwright:init` (new project) works through these steps. It asks once whether to commit each step as it lands, batches the consents it can, and asks before every install, download, image pull or MCP server:

1. Checks the repository: `inventory` reports its kind — `empty` or `docs-only` continue, `code` is sent to `/teamwright:adopt` (an interrupted init resumes instead). Documents already in the repository are the base of the requirements and are never overwritten.
2. Runs `/teamwright:requirements`:
   - your brief, PRD or terms of reference (any language; the document is written in English, the original stays where it is) is mapped into the ten sections of `docs/requirements.md`, and only the gaps are asked;
   - without one, an interview in rounds of up to five questions: Jobs To Be Done, the release-1 flow and how success is measured, a story map with MoSCoW and no-gos, EARS requirements with a failing example each, measurable non-functional requirements (ISO/IEC 25010 as a checklist), constraints and what may be installed on the dev machine, in CI and on the server, glossary, integrations, a pre-mortem;
   - a fresh `requirements-reviewer` roasts the draft (`docs/requirements.reviews/<n>.md`): High findings come as questions, Medium and Low as one batch you can accept at once; it proposes the technical decisions — stack and areas, what "deployed" means, where verification runs, UI verification — from your requirements and install policy; another round runs only when an accepted change alters what gets built, at most two without a Blocker;
   - you approve the document; specs and tasks are derived from that version.
3. Proposes the tools as one block (per capability: the proposal, what is already on the host, the alternatives), within the install policy. A tool's MCP server is a separate yes or no (`no_mcp`).
4. Sets up each area's toolchain on the host or in a container, scaffolds the stack with its official generator, and builds a walking skeleton: the app starts, one real test per area, the running system reports its commit, a `make check` gate, a CI workflow running the same gate. A check the policy does not allow is recorded as a decision.
5. Writes `.teamwright/config.yml`, installs the hooks, scans for secrets, runs every command once (runner and duration per command) and switches to `enforce`. A UI runner that cannot run yet keeps `gate-first`, unless you decide to go without UI verification for now (`ui_verify_deferred`).
6. Fills `CLAUDE.md`, `docs/plan.md`, `docs/architecture.md` and `docs/decisions.md` from what was decided.
7. The spec tool turns the approved requirements into specs, feature by feature along the release-1 slice; you review them at once; tasks get `design_ref`, the requirement ids and a failure branch. Every Must requirement of release 1 is covered by a task.
8. Plans sprint 1 — T-001 is the first end-to-end slice of the release-1 flow.
9. Ends with next steps and offers to start `/teamwright:flow`.

`/teamwright:requirements` can also be run on its own: on an adopted project whose `docs/requirements.md` is still the template (`adopt` offers it), or to rework the requirements; a later change is a new version with a line in `docs/decisions.md`.

Hooks written to `.claude/settings.json` take effect in the same Claude Code session (Claude Code watches its settings files). New MCP servers, and role agents in a `.claude/agents/` directory created during the session, load after a restart. The plugin registers no global hooks: everything is installed into the project, so the project works the same with or without the plugin.

## Gate modes: gate-first, then enforce

Gates start in **gate-first** mode: the analysis, review and verify gates warn (a message to you and to the model) instead of blocking. Once the project's own gate command is green, switch them to blocking — run it yourself, or approve Claude Code running it when `/teamwright:status` or `/teamwright:flow` offers to:

```bash
python3 <kit>/scripts/tw-install.py enforce
```

`<kit>` is the plugin's directory (or a checkout of this repository); `/teamwright:status` prints the command with the full path.

Lowering the mode back to gate-first is yours alone, outside Claude Code: the installer refuses it inside any Claude Code tool call, and the state guard denies writes to `.teamwright/config.yml` from agents. Git hooks behave the same in both modes. `/teamwright:status` shows the mode, the tasks and the next action.

## `/teamwright:flow`

`/teamwright:flow` is how work starts and resumes. A deterministic router (`scripts/tw-next.py`) picks the next action, in this order:

1. Finish an interrupted task.
2. Continue a task in `ANALYSIS` or `IN_PROGRESS`.
3. Review a task in `NEEDS_REVIEW`.
4. Verify a task in `CODE_COMPLETE` or `DEPLOYED`; re-analyse after a failed verification.
5. Ask the owner about a blocked task.
6. Start the next ready task by priority and dependencies. A prerequisite inherits the priority of the task waiting on it; a task with `blocked_on: OQ-NN` waits for that open question.

The skill then drives the lifecycle with fresh role agents run in the foreground, commits each role's result before the next step, and asks only at decision points: escalation, architecture review, push. It stops on a `TEAMWRIGHT_PAUSE` file or its budget, and always ends with a summary whose `Outcome:` line routes the next session. Router rules in full: [plugin.md](process/plugin.md#tw-nextpy-the-flow-router).

## Settings, improve and feedback

The pipeline is the same in every project; a few of its steps take parameters — the review blocking threshold, how many tasks a flow pass takes (capped per priority), and whether the flow starts and continues without asking. adopt and init ask once; `/teamwright:settings` shows and changes them through the installer, and records the decision. Without settings the kit behaves as before them.

`/teamwright:improve` reads what the process costs in this project — review send-backs and findings by severity and category, DRAIN exceptions, bookkeeping commits, record sizes, whether the context tool is used — and proposes changes, each routed: a setting, a project rule (`PRINCIPLES.md`), a task, or feedback to teamwright. It writes `docs/process-reviews/<date>.md`, and the next run compares against it.

`/teamwright:feedback` sends what belongs to the kit back here: an issue through the forms, or a pull request from a fork for a tested change — anonymised, and only after you read it.

## `/teamwright:progress`

A report for you rather than for the agents: tasks done by sprint, plan stage, milestone and area, in percent, what is in flight, what the router picks next and what waits for your decision. The counts come from the task records, `docs/plan.md`, `docs/sprints/` and git (`scripts/tw-progress.py`). `--gate` also runs every configured command.

Repositories differ in how they track work: an earlier progress command, a spec tool's task lists not yet split into records, a release called MVP. `/teamwright:progress --adapt` (also a step of adopt and init) reads what the repository has and proposes `.teamwright/progress.json` and `.teamwright/progress.md` for your approval — areas, the milestone, an extra reader for work kept elsewhere. Rules: [plugin.md](process/plugin.md#tw-progresspy-the-progress-report).

## Toolchain runners: host or Docker

Every area's commands run through `scripts/tw-run <area> -- <cmd>`. With `runner: host` that is the command itself. With `runner: docker` it runs in `docker run --rm` with your uid, the repository mounted and package caches as volumes, by default in the image your CI already uses, so a local result matches CI. A missing SDK on the machine is not a reason to skip a gate:

```yaml
areas:
  - name: app
    runner: docker
    image: "<image from your CI job>"
    cache: [".pub-cache"]
    workdir: app
    test_command: "flutter test"            # no wrapper; the runner applies it
    generate_command: "flutter gen-l10n"    # codegen, run before the gate
```

`tw-install.py check-commands` runs every configured command once and reports pass, fail or not runnable, and whether a command changed tracked files in its area. A run that could not exercise the code (database not listening, binary or Docker missing, no device for UI tests) is `not runnable` with the reason, not a failure. Details: [tools.md](process/tools.md#toolchain-runners).

## Changing the configuration

Config changes, runners included, go through a proposal file rather than an edit of `.teamwright/config.yml`:

```bash
# write the new config to .teamwright/config.next.yml, then:
python3 <kit>/scripts/tw-install.py plan --config .teamwright/config.next.yml    # diff and actions
python3 <kit>/scripts/tw-install.py apply --config .teamwright/config.next.yml   # apply, remove the proposal
```

`/teamwright:reconfigure` does this for you and swaps a tool provider, re-rendering only the tool blocks in `AGENTS.md` and the role files. Config schema: [plugin.md](process/plugin.md#config-teamwrightconfigyml).

## Updating the plugin

```text
/plugin update teamwright@teamwright
```

It compares the `version` in `.claude-plugin/plugin.json` with the installed one: from a git marketplace you get a change only when the version was bumped (see [CHANGELOG.md](../CHANGELOG.md)). A local marketplace (`/plugin marketplace add ./path/to/teamwright`) reads files directly from that checkout, so it may report "already at latest version" and still load the new skills after a reload. Run `/plugin` commands in a terminal session: they are not available over Remote Control.

The plugin update does not touch your project. `/teamwright:status` reports kit updates for the installed files; `tw-install.py apply` (or `/teamwright:adopt` again) updates the files the installer wrote and you did not edit, and keeps and reports the ones you changed. Project documents (`docs/requirements.md`, `plan.md`, `architecture.md`, `decisions.md`, `open-questions.md`) are never replaced.

## Another machine or a fresh clone

The process lives in two places. The repository carries the gates, roles, documents and configuration; the machine carries the teamwright plugin (the `/teamwright:*` commands and the router) and `core.hooksPath` (local git config, never cloned). A fresh clone has only the first half:

1. **The plugin.** Install writes into `.claude/settings.json` that the project uses `teamwright@teamwright` (`enabledPlugins`) and where its marketplace is (`extraKnownMarketplaces`: the GitHub repository, with the branch when it is not the default one). When you trust the folder, Claude Code offers to add the marketplace and install the plugin — accept and restart. If it does not, in a terminal session: `/plugin marketplace add <repository>`, `/plugin install teamwright@teamwright`, restart. A private repository needs GitHub access on that machine.
2. **The git hooks:** `bash scripts/install-hooks.sh` (check: `bash scripts/install-hooks.sh --check`).
3. **The toolchain** the areas run on: the same host tools, or Docker for `runner: docker`. MCP servers from `.mcp.json` are approved once per machine.
4. `/teamwright:status`, then `/teamwright:flow`.

You do not have to remember this: a `SessionStart` hook (`scripts/hooks/session-check.sh`) compares the machine with the project and tells you what is missing — the plugin, a plugin older than the version recorded in `.teamwright/installed.json` (`@kit`), or git hooks that are off — with the commands to fix it. It never blocks; `TEAMWRIGHT_SESSION_CHECK=0` turns it off.

Local state does not travel: journals and session ledgers (`.teamwright/logs/`, `.teamwright/sessions/`) belong to the machine. Finish a task through review on the machine where it was started — the review and verify ledgers that the gates check are there.

## Manual install, without the plugin

From your repository root:

```bash
git clone https://github.com/smykov/teamwright.git ../teamwright
mkdir -p .teamwright && cp ../teamwright/template/.teamwright/config.example.yml .teamwright/config.yml   # edit: areas, commands, tools
python3 ../teamwright/scripts/tw-install.py plan      # what would change, conflicts
python3 ../teamwright/scripts/tw-install.py scan      # secrets in the whole tree, before hooks
python3 ../teamwright/scripts/tw-install.py apply     # never overwrites files it did not write
```

Merge the reported conflicts by hand, install the chosen tools per their adapters in `providers/`, then create the first task from `docs/tasks/_task-template.md` and commit `chore(task): T-001 →TODO`. Claude Code picks up the gates from `.claude/settings.json` in the running session; restart it to load new MCP servers.

## Metrics

```bash
python3 scripts/metrics/teamwright-metrics                          # Markdown, whole history
python3 scripts/metrics/teamwright-metrics --split-date 2026-04-01  # before / after + delta
python3 scripts/metrics/teamwright-metrics --json -o metrics.json
python3 scripts/metrics/teamwright-metrics --repo ../other-repo     # any git repository
```

- **Git** (any repository, including history before adoption): agent co-authorship, fix and revert share, recurrence rate, recurring areas, tasks fixed again, hotspots.
- **Tasks**: cycle and lead time, rework rate, review rounds, approvals without a review record, escalations, from `chore(task): T-042 FROM→TO` commits and committed review records.
- **Journals**: session outcomes, declared vs actual review, permission denials, from `.teamwright/logs/`.

Every number carries its n and source; a missing source prints `no data`, never `0`. Definitions and biases: [metrics.md](process/metrics.md).
