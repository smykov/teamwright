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

`/teamwright:init` does the same for a new project, starting from a spec when the work is large.

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

The plugin update does not touch your project. `/teamwright:status` reports kit updates for the installed files; `tw-install.py apply` (or `/teamwright:adopt` again) updates the files the installer wrote and you did not edit, and keeps and reports the ones you changed.

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
