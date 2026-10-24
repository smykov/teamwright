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

1. Finish unfinished work in the tree (uncommitted changes, or a session that ended `interrupted`).
2. Continue a task in `ANALYSIS` or `IN_PROGRESS`.
3. Review a task in `NEEDS_REVIEW`.
4. Verify a task in `CODE_COMPLETE` or `DEPLOYED`; re-analyse after a failed verification.
5. Ask the owner about a blocked task.
6. Start the next ready task by priority and dependencies. A prerequisite inherits the priority of the task waiting on it; a task with `blocked_on: OQ-NN` waits for that open question.

The skill then drives the lifecycle with fresh role agents run in the foreground, commits each role's result before the next step, and asks only at decision points: escalation, architecture review, push. It stops on a `TEAMWRIGHT_PAUSE` file or its budget, and always ends with a summary whose `Outcome:` line routes the next session. Router rules in full: [plugin.md](process/plugin.md#tw-nextpy-the-flow-router).

## One stage per session: `/teamwright:router` and the stage commands

Every decision of the router names a **stage** — analyze, red-tests, implement, review, verify. `/teamwright:router` asks the router and runs exactly that one stage on the batch it allows, then stops with `Stage:`, `Batch:` and `Outcome:` lines; the next stage is a new session with a fresh context. `/teamwright:analyze`, `/teamwright:red-tests`, `/teamwright:implement`, `/teamwright:review` and `/teamwright:verify` run a stage you name, and refuse, naming the right command, when the router says the task is elsewhere (`/teamwright:implement T-12` on a task without red tests → `/teamwright:red-tests T-12`). The script selects and counts; the session picks the batch from the candidates it lists. Per-stage batches, thresholds and models are settings (`/teamwright:settings`): for example `stages.review: {batch: 3, min: 2, max_wait_hours: 4}` and `models.red-tests: sonnet`. Details: [sessions.md §8](process/sessions.md#8-stages-one-stage-per-session).

### Autonomous runs: one stage per job

A CI job runs one stage and ends; the next job asks the router again. The router's JSON has what a job needs under `headless`: `run`, `prompt` (`/teamwright:<stage>`, no ids — the stage session picks its batch from the router's candidates), `model`, and `decisions`. An owner decision on one task (an escalation, a blocked question) does not stop the chain while other work is available; it is listed in `decisions` for a person. Between jobs the work travels on a `wip/` branch (pre-push does not treat it as a delivery); pushing to the main branch (DRAIN) stays a decision for a person — when nothing else is left, `run` is false and the chain stops. On the `wip/` branch the router counts unpushed commits against the delivery branch (`<remote>/HEAD`, `/main` or `/master` of the remote the branch is pushed to — the only remote, else `origin`), so the push decision comes up, and a task that deploys is verified only after that push. A merge, a rebase, a cherry-pick or a squash merge of the `wip/` branch all count as delivered: a commit whose changes are on the delivery branch (same patch, or every file it touches has there its content in the commit or at `HEAD`) is not unpushed. After a delivery, merge the delivery branch back into `wip/teamwright` or reset `wip/teamwright` to it (`git checkout -B wip/teamwright origin/main && git push --force-with-lease origin wip/teamwright`, by a person): a squashed `wip/` keeps its old commits, and the next squash would show them again in the pull request. Starting a new task needs `process.autonomy.start: auto`: with `ask` nobody answers the start question, and no job runs for it. No job runs on an install older than the kit either (`install drift`: hooks without the plugin's helpers, or an older `@kit` in `installed.json`): a person runs `tw-install.py apply` and commits the result first. A sketch for GitHub Actions on a self-hosted runner, with the kit checked out on the runner and its path in `TEAMWRIGHT_KIT` (the job loads the plugin from it: `--plugin-dir`, and `TEAMWRIGHT_PLUGIN_DIR` for the session check), saved as `.github/workflows/teamwright-stage.yml` (adapt the names; the real workflow lives in your repository; pin actions by commit SHA, as here; task records, issues and requirements are model input, so a prompt injection in them runs with the job's rights - keep the runner isolated, give the job no secrets but the model key, and leave the push to the main branch to a person; `tests/test-usage-example.sh` checks that it parses and that the router fields and step outputs it reads exist):

```yaml
name: teamwright stage
on:
  workflow_dispatch:
concurrency: teamwright          # one stage at a time per repository
permissions: { contents: write, actions: write }   # push to wip/, dispatch the next stage
jobs:
  stage:
    runs-on: self-hosted
    timeout-minutes: 60
    env:                             # the kit checked out on the runner (the plugin is loaded from it)
      TEAMWRIGHT_KIT: /opt/teamwright
      TEAMWRIGHT_PLUGIN_DIR: /opt/teamwright
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with: { fetch-depth: 0, clean: false }
      - name: Work branch
        run: |
          if git fetch -q origin wip/teamwright; then git checkout -B wip/teamwright FETCH_HEAD
          else git checkout -B wip/teamwright; git push -q origin HEAD:refs/heads/wip/teamwright; fi
      - name: Journal from the previous job
        uses: actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830 # v4
        with:
          path: .teamwright/logs
          key: teamwright-state-${{ github.run_id }}
          restore-keys: teamwright-state-
      - name: Ask the router
        id: route
        run: |
          python3 "$TEAMWRIGHT_KIT/scripts/tw-next.py" --json > route.json
          python3 - <<'PY' >> "$GITHUB_OUTPUT"
          import json, subprocess; r = json.load(open("route.json")); h = r["headless"]
          print("run=%s" % ("true" if h["run"] else "false"))
          print("prompt=%s" % (h["prompt"] or ""))
          print("model=%s" % (h["model"] or "opus"))
          print("reason=%s" % (h.get("reason") or r["reason"]).replace("\n", " "))
          print("head=%s" % subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip())
          PY
      - name: One stage
        if: steps.route.outputs.run == 'true'
        uses: anthropics/claude-code-action@925afb53776cf1a2b738c6bdbed37b4d4000ef13 # v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: ${{ steps.route.outputs.prompt }}
          claude_args: --model ${{ steps.route.outputs.model }} --plugin-dir ${{ env.TEAMWRIGHT_KIT }}
      - name: Keep the work, start the next stage
        if: steps.route.outputs.run == 'true'
        env: { GH_TOKEN: "${{ github.token }}", BEFORE: "${{ steps.route.outputs.head }}" }
        run: |
          if [ "$(git rev-parse HEAD)" = "$BEFORE" ]; then
            echo "the stage made no commit: stopping the chain - a person looks at the run"; exit 1
          fi
          git push origin HEAD:wip/teamwright
          gh workflow run teamwright-stage.yml
      - name: Nothing to run
        if: steps.route.outputs.run != 'true'
        env: { REASON: "${{ steps.route.outputs.reason }}" }
        run: |
          echo "router: $REASON"
```

`concurrency` keeps one stage running per repository (reviewers one at a time); when only owner decisions are left (push, an escalation, `NEEDS_OWNER`), `run` is false and the chain stops until a person acts.

What survives between jobs, and why:

- **The gates' evidence is committed.** When the review gate lets a review record through, and the verify gate a verify or acceptance record, each writes a stamp next to it (`docs/tasks/<ID>.reviews/<n>.gate.json`, `.verify/<n>.gate.json`, `.validation/<n>.gate.json`: who wrote it, the verdict, the record's hash). The stage commits it with the record, so a job cut after the reviewer's APPROVE was committed but before the status move does not loop: the next job's gate checks the stamp instead of the local ledger it does not have (`docs/process/gates.md`, *Gate stamps*).
- **The journal is not.** `.teamwright/logs` (tool calls, outcomes, tokens per stage) is local and gitignored; `actions/checkout` cleans it. The cache step carries it from job to job (`clean: false` alone is enough on a self-hosted runner that keeps its workspace); without it the per-stage metrics of CI runs are lost and an `interrupted` outcome is not seen by the next job.
- **The ledgers are not cached.** Where a task's ledger (`.teamwright/sessions/<ID>.reviews.jsonl`, `.verify.jsonl`, `.validation.jsonl`) exists, it alone decides and the stamps are not consulted — a stamp is never a way around a local ledger. A cache restored from an older job (the job that wrote the round was cut before its cache was saved) would hold the task's ledger without that round and refuse it; without the cache every job is a fresh checkout and the stamps decide. On a machine where a round was written elsewhere (a review in CI, the status move on your laptop with an older ledger for that task), move the status where the round was written, or remove that task's ledger file yourself.
- **No new commit, no next job.** A stage that ends without a commit (refused, nothing to do, a failure before its first commit) would be asked the same question again by the next job; the last step compares `HEAD` with the commit the job started from and stops the chain instead.

## `/teamwright:blockers`

What the team is waiting on you for, in one list: open questions (`docs/open-questions.md`) with the tasks each one holds, reviews escalated to you, acceptance checks that need you (`NEEDS_OWNER`), `BLOCKED` and held tasks, `blocked_on` fields that name questions already answered, and uncommitted or unpushed work. Each item has a class — credentials, infrastructure, external service, device or manual check, decision — and the open tasks it unblocks (with everything that depends on them); the list is ordered by that. Items outside the repository (a key, a DNS record, a check on a phone) are yours to do by hand; the next `/teamwright:flow` continues the task.

Then, if you want, it goes through the questions and decisions one at a time: context from the records, the options with a recommendation, your answer. Each answer becomes a row in `docs/decisions.md`, the question's status in `docs/open-questions.md`, cleared `blocked_on` fields and `BLOCKED → TODO` for the tasks it settles — one commit at the end, after you say yes. `--answer` skips the list. The data comes from `scripts/tw-blockers.py` (read-only).

## Settings, improve and feedback

The pipeline is the same in every project; a few of its steps take parameters — the review blocking threshold, how many tasks a flow pass takes (capped per priority), batches, thresholds (`min`, `max_wait_hours`) and models per stage (`stages.<stage>`, `models.<stage>`), whether the script or the agent selects the tasks (`router.select`), the test guard, parallel worktrees (`batch.parallel`), and whether the flow starts and continues without asking ([all keys](process/plugin.md#config-teamwrightconfigyml)). adopt and init ask once; `/teamwright:settings` shows and changes them through the installer, and records the decision. Without settings the kit behaves as before them.

`/teamwright:parallel` runs independent tasks at the same time (`batch.parallel` above 1): it analyses ready tasks, groups those whose seams do not overlap, and creates a worktree per task on `tw/<ID>`. `/teamwright:parallel auto` — what a night run wants — goes on by itself: it prepares each worktree's context index (`tw-parallel.py prepare`), runs each worktree's stages headless, one `claude -p` session per stage (`tw-parallel.py launch`), watches them (`status`), merges the approved ones and starts the next; owner decisions are collected for the morning. Or open one session per worktree yourself (`cd <path> && claude "/teamwright:flow <ID>"`). The machine is the real limit: each worktree runs its own gates and its own context-tool server. When a task is approved there, the main session rebases its branch, runs the gate in the worktree, fast-forwards it in, and removes the worktree; one push follows.

Tests that only CI can run (another platform): give the area `ci_workflow` and let that workflow run on `wip/**`. The flow pushes the task's commits to `wip/<ID>` to see red and green before review; pre-push does not count it as a delivery.

Requirements by id: `scripts/tw-req FR-03` prints the requirement, the spec sections that cite it and the tasks — what roles use instead of reading whole documents.

`/teamwright:improve` reads what the process costs in this project — review send-backs and findings by severity and category, DRAIN exceptions, bookkeeping commits, record sizes, whether the context tool is used — and proposes changes, each routed: a setting, a project rule (`PRINCIPLES.md`), a task, or feedback to teamwright. It writes `docs/process-reviews/<date>.md`, and the next run compares against it.

`/teamwright:feedback` sends what belongs to the kit back here: an issue through the forms, or a pull request from a fork for a tested change — anonymised, and only after you read it.

## `/teamwright:progress`

A report for you rather than for the agents: tasks done by sprint, plan stage, milestone and area, in percent, what is in flight, what the router picks next and what waits for your decision. The counts come from the task records, `docs/plan.md`, `docs/sprints/` and git (`scripts/tw-progress.py`). `--gate` also runs every configured command.

Repositories differ in how they track work: an earlier progress command, a spec tool's task lists not yet split into records, a release called MVP. `/teamwright:progress --adapt` (also a step of adopt and init) reads what the repository has and proposes `.teamwright/progress.json` and `.teamwright/progress.md` for your approval — areas, the milestone, an extra reader for work kept elsewhere. Rules: [plugin.md](process/plugin.md#tw-progresspy-the-progress-report).

## CI: record-only pushes

Most commits of a teamwright project are task records (`chore(task): T-042 FROM→TO`), and each push re-runs CI on code that did not change. Two parts stop that without ever skipping code:

- `push` trigger: `paths-ignore: ["docs/tasks/**"]` — a push is skipped only when every file it changes matches.
- Pull requests: the path filter sees the whole PR diff, so it never skips. Put a `changes` job in front of the gate job:

```yaml
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      code: ${{ steps.c.outputs.code }}
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with: { fetch-depth: 0 }
      - id: c
        run: python3 scripts/tw-ci-changes --before "${{ github.event.before }}" --after "${{ github.event.pull_request.head.sha || github.sha }}"
  gate:
    needs: changes
    if: needs.changes.outputs.code == 'true'
    concurrency: { group: "gate-${{ github.ref }}", cancel-in-progress: true }
    # ... the gate steps
```

`scripts/tw-ci-changes` answers `code=false` only when every file changed since the previous tip of the ref is a record (task, review and verify records, sprints, decisions, open questions); a new branch, a first PR event or a force-push is always `code=true`. A skipped job counts as passed for required checks. Keep `concurrency` on the gate **job**, not the workflow: a record-only push must not cancel the run that is checking the code under it.

Do not put `[skip ci]` on any commit — least of all the last one before a push. DRAIN pushes code together with its `→CODE_COMPLETE` commit on top, so the tip of every delivery (and the head a pull request is opened from) is a status commit, and `[skip ci]` there skips CI on the code being delivered. `pre-push` warns when the pushed tip carries a CI-skip marker.

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

Roles run the full gate as `scripts/tw-gate <area>`: `generate_command`, then the gate, the whole output in `.teamwright/logs/gate/<area>-<time>-<commit>.log`, and on screen only PASS/FAIL, the tail of a failure and the log path. A PASS is recorded for the content of the area's files (its `source_dirs`, `test_dirs`, `workdir`, manifests, config and the gate scripts), so the flow, the reviewer and the validator get `PASS (cached: …)` instead of another run of several minutes — also after a docs-only commit; a FAIL is never reused and `--fresh` forces a run. `scripts/tw-gate --for-task <ID>` lists which gates a task's changes need (none for records, docs or CI configuration). A gate longer than ~9 minutes keeps running detached: the call prints `RUNNING: …` and exits 75, and the same command again attaches to it — this keeps it under Claude Code's 10-minute Bash limit. For mutant runs in throwaway copies, declare an area's codegen outputs (`generated: [...]`) and per-copy build cache variables (`copy_env: {CARGO_TARGET_DIR: "{cache}/target"}`) so a copy does not rebuild from cold. Details: [gates.md](process/gates.md#gate-runs-tw-gate).

While working, roles run tests only as `scripts/tw-test <area> [<tests>]`: the area's `test_select_command` (with `{tests}`) or `test_command`, the whole output in `.teamwright/logs/test/`, on screen the counts, the failed tests with their first error line and the log path; a repeat on the same files answers from the cache, a failure included. The `test-guard` hook refuses test runners and gate scripts called directly and test output piped into `tail` or `grep`; it blocks even in `gate-first` unless `process.test_guard` says `warn` or `off`, and a person can start Claude Code with `TW_TEST_GUARD=off`. Details: [gates.md](process/gates.md#test-guard).

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

`/teamwright:update` does it in one step: the plugin (marketplace, then plugin, for the project's channel) and the project's kit files from the updated copy — a plan first, apply and a commit on your yes, then restart Claude Code (`tw-install.py update [--apply] [--no-fetch]` underneath). By hand:

```text
/plugin update teamwright@teamwright
```

It compares the `version` in `.claude-plugin/plugin.json` with the installed one: from a git marketplace you get a change only when the version was bumped (see [CHANGELOG.md](../CHANGELOG.md)). The experimental channel (`teamwright@teamwright-next`, branch `next`) has no version: each commit is one, after `/plugin marketplace update teamwright-next` ([README, Channels](../README.md#channels)). A local marketplace (`/plugin marketplace add ./path/to/teamwright`) reads files directly from that checkout, so it may report "already at latest version" and still load the new skills after a reload. Run `/plugin` commands in a terminal session: they are not available over Remote Control.

The plugin update alone does not touch your project; `/teamwright:update` does both — the plugin, then the project's files from the new copy (plan first, apply on your yes). `/teamwright:status` reports kit updates for the installed files; `tw-install.py apply` (or `/teamwright:adopt` again) updates the files the installer wrote and you did not edit, and keeps and reports the ones you changed. Project documents (`docs/requirements.md`, `plan.md`, `architecture.md`, `decisions.md`, `open-questions.md`) are never replaced.

## Another machine or a fresh clone

The process lives in two places. The repository carries the gates, roles, documents and configuration; the machine carries the teamwright plugin (the `/teamwright:*` commands and the router) and `core.hooksPath` (local git config, never cloned). A fresh clone has only the first half:

1. **The plugin.** Install writes into `.claude/settings.json` that the project uses `teamwright@teamwright` (`enabledPlugins`) and where its marketplace is (`extraKnownMarketplaces`: the GitHub repository, with the branch when it is not the default one). When you trust the folder, Claude Code offers to add the marketplace and install the plugin — accept and restart. If it does not, in a terminal session: `/plugin marketplace add <repository>`, `/plugin install teamwright@teamwright`, restart. A private repository needs GitHub access on that machine.
2. **The git hooks:** `bash scripts/install-hooks.sh` (check: `bash scripts/install-hooks.sh --check`).
3. **The toolchain** the areas run on: the same host tools, or Docker for `runner: docker`. MCP servers from `.mcp.json` are approved once per machine.
4. `/teamwright:status`, then `/teamwright:flow`.

You do not have to remember this: a `SessionStart` hook (`scripts/hooks/session-check.sh`) compares the machine with the project and tells you what is missing — the plugin, a plugin older than the version recorded in `.teamwright/installed.json` (`@kit`), or git hooks that are off — with the commands to fix it. It never blocks; `TEAMWRIGHT_SESSION_CHECK=0` turns it off. A plugin loaded from a directory instead of the registry (`claude --plugin-dir`, the Agent SDK in an autonomous run) is not in the registry: set `TEAMWRIGHT_PLUGIN_DIR` to that directory; its version (`plugin.json`, else the directory's git commit) is still compared with the one the project was set up with.

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
