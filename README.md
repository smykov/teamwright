# teamwright

A Claude Code plugin that installs a team process into your repository: AI agents work on recorded tasks, and hooks block the steps they tend to skip — analysis, independent review, verification.

[![ci](https://github.com/smykov/teamwright/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/smykov/teamwright/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![release](https://img.shields.io/github/v/tag/smykov/teamwright?label=release&sort=semver)](CHANGELOG.md)

- **Analysis before code.** A task cannot start, and its code cannot be edited, until the root cause, the evidence and the place of the change are written down.
- **Review that actually ran.** Only a separate reviewer agent, logged when it was started, can approve a task. It also checks whether the same kind of bug was patched before.
- **Done means verified.** A task closes only with a recorded passing test run for the current commit. The process is measured from git and hook logs, not from what agents report.

## Quickstart

Requires Claude Code, `bash`, `git` and `python3` on Linux or macOS (Docker optional, for toolchains you do not want on the host). Commit your work, then in Claude Code at the repository root:

```text
/plugin marketplace add smykov/teamwright
/plugin install teamwright@teamwright
/teamwright:adopt        # existing project; /teamwright:init for a new one
/teamwright:flow         # pick the next task and drive it through the loop
```

`adopt` asks before every install, rewrite or commit. Gates start by warning; you switch them to blocking when your project's checks are green. To see the gates without Claude Code, run the demo: `bash examples/demo.sh` ([what it does](examples/README.md)).

![The demo: one task through the analysis, review and verify gates](docs/assets/demo.gif)

## How a task moves

```mermaid
flowchart TD
    SPEC["Large work: spec tool<br/>specify → plan → tasks"] -. "design_ref" .-> T
    T["TODO · task record"] --> A["ANALYSIS · problem-investigator<br/>root cause, evidence, seam, recurrence check"]
    A -- "analysis gate" --> RED["IN_PROGRESS 1 · test-writer<br/>a test that fails (red)"]
    RED --> GREEN["IN_PROGRESS 2 · developer<br/>smallest fix, tests green, local commit"]
    GREEN --> NR["NEEDS_REVIEW · code-reviewer<br/>fresh agent: diff, principles, recurrence"]
    NR -- "changes requested, max 2 rounds" --> GREEN
    NR -- "approve · review gate" --> CC["CODE_COMPLETE"]
    CC -- "push · pre-push gate" --> DEP["DEPLOYED"]
    CC -. "nothing to deploy" .-> VAL
    DEP --> VAL["task-validator<br/>API / UI tests on the running system"]
    VAL -- "PASS · verify gate" --> DONE["VERIFIED → DONE"]
    VAL -- "FAIL: re-analyse, do not re-patch" --> A
    NR -. "same bug class again" .-> RCA["root-cause task:<br/>code invariant, arch review or principle change"]
    RCA -.-> T
```

Every arrow marked *gate* is a hook that blocks the status change when its record is missing. Test first: the test-writer's tests are run and shown to fail for the right reason, and committed, before the developer touches the code; the reviewer checks that each guarantee has a test that fails without the change. A reviewer that sees the same class of bug patched again rejects the patch; the task waits for a root-cause task, which ends in a code invariant, an architecture decision or a process change. Full lifecycle with every status and exit: [docs/process/lifecycle.md](docs/process/lifecycle.md).

## What the demo shows

`examples/demo.sh` installs the kit into a throwaway repository and walks one bug fix through every gate by sending the hooks the same events Claude Code sends. An excerpt of its output:

```text
== 6. Review gate: approval only from a separate reviewer ==
> orchestrator: T-001 NEEDS_REVIEW -> CODE_COMPLETE
  DENIED by review-gate:
      REVIEW GATE: T-001 cannot become CODE_COMPLETE - no review record in
      docs/tasks/T-001.reviews/. Spawn a fresh code-reviewer subagent for T-001.
      Exit for trivial changes: `review: skipped:trivial`.
> developer writes the review record for its own task
  DENIED by review-gate:
      REVIEW GATE: this agent implemented T-001; its review does not count.
      Spawn a fresh code-reviewer subagent (not a fork of the author) to review
      it.
```

and the metrics report it ends with. The numbers are synthetic — the demo scripts its own commits — and show the format, not results:

| Metric | Value | Source |
|---|---|---|
| agent co-authored commits | 66.7% (4/6) | git log, task-status commits excluded |
| fix share | 16.7% (1/6) | git log, subject matches the fix pattern |
| tasks done | 1 | task-status commits |
| review rounds, mean | 1 (n=1) | `docs/tasks/<ID>.reviews/<n>.md` |
| approved without a review record | 0.0% (0/1) | review records vs `→ CODE_COMPLETE` |
| approvals with a journaled reviewer spawn | 100.0% (1/1) | hook journal vs `→ CODE_COMPLETE` |

Every number carries its n and source; a missing source prints `no data`, never `0`.

## Your first day

1. **`/teamwright:adopt`** looks at the repository, asks what the next release should achieve and which tools to use, and proposes the test and lint commands for each code area. It writes `.teamwright/config.yml`, installs the hooks, runs every command once and proposes a first sprint of tasks in `docs/tasks/`. Your `CLAUDE.md` and agents are kept, merged with you where they conflict.
2. **Gates warn first.** Until your checks are green, the gates report what they would block. `/teamwright:status` tells you when the project is ready and prints the `enforce` command; you run it yourself or approve Claude Code running it, and from then on the gates block. Lowering the mode back to gate-first is refused inside Claude Code: only you can do it, from your own shell.
3. **`/teamwright:flow`** picks the first ready task. A problem-investigator writes the analysis; a test-writer adds a failing test; a developer makes it pass; the orchestrator (the main session) commits locally.
4. **Review.** A fresh code-reviewer reads the diff, the task and the principles and writes a review record. Up to two rounds of changes, then it escalates to you.
5. **Push and verify.** You decide when to push. A task-validator runs the tests against the running system and writes a verify record; with a `PASS` for the current commit the task is `DONE`.
6. **`/teamwright:status`** at any time shows the mode, the tasks and the next action. After a week, run `python3 scripts/metrics/teamwright-metrics`.

More on onboarding, gate modes, the flow router, Docker runners, configuration changes, updating and manual install: [docs/usage.md](docs/usage.md).

## Glossary

| Term | Meaning |
|---|---|
| task record | `docs/tasks/T-NNN.md`: front matter with status, priority, `surface`, the analysis block; the body has acceptance criteria |
| status | `TODO → ANALYSIS → IN_PROGRESS → NEEDS_REVIEW → CODE_COMPLETE → DEPLOYED → VERIFIED → DONE`; side statuses `BLOCKED`, `DEFERRED`, `VERIFY_FAIL` |
| gate | a hook that checks a status change or an edit and blocks it (or warns, in gate-first mode) with the reason and the exit |
| gate-first / enforce | the two modes: gates warn while a project is being brought up to the process, then block |
| review record | `docs/tasks/<ID>.reviews/<n>.md`, written only by a code-reviewer that did not implement the task; verdict `APPROVE`, `REQUEST_CHANGES`, `REJECT_RECURRENCE` or `ESCALATE` |
| verify record | `docs/tasks/<ID>.verify/<n>.md`: which tests ran against the running system, for which commit, with what result; append-only |
| surface | what a task changes that can be verified: `api`, `ui`, `both` or `none`; decides which verify records `DONE` needs |
| recurrence | the same class of defect fixed again; the reviewer rejects the patch and a root-cause (`rca`) task takes over |
| seam | the one place in the code where a behaviour is owned, and where a fix belongs |
| tier | how a rule is enforced: T0 written guidance, T1 reviewer checklist, T2 hook warns, T3 hook or CI blocks |
| journal | `.teamwright/logs/*.jsonl`: tool calls, agent starts and session outcomes logged by a hook; no file contents or prompts |

## What gets installed

Paths are in your repository after install.

| Component | What it does | Tier |
|---|---|---|
| `scripts/hooks/analysis-gate.sh` | no `IN_PROGRESS` and no code edits without a filled analysis block | T3 |
| `scripts/hooks/review-gate.sh` | review records only from a code-reviewer that did not implement the task; `CODE_COMPLETE` only with an approval and a logged reviewer start; after two send-backs in a row the third record must escalate (or reject a recurrence), never approve | T3 |
| `scripts/hooks/verify-gate.sh` | `VERIFIED` / `DONE` only with a `PASS` verify record for the current code, of the kind the task's `surface` needs | T3 |
| `scripts/hooks/journal.sh` | logs tool calls, permission events and session outcomes to `.teamwright/logs/` | facts |
| `scripts/hooks/pre-push` | pushes only code of approved tasks; a `TEAMWRIGHT_PAUSE` file stops all pushes | T3 |
| `scripts/hooks/pre-commit` | secret scan (gitleaks or a built-in fallback); refuses `.env`, `*.local.json` | T3 |
| `scripts/hooks/commit-msg`, `patch-guard.sh` | warns on "one more special case" in an area fixed before | T2 |
| `.claude/settings.json` | registers the hooks; denies `git stash`, `reset --hard`, force-push, `rm -rf` | T3 |
| `.claude/agents/*.md`, `AGENTS.md` | roles: problem-investigator, test-writer, developer, technical-writer, code-reviewer, task-validator | T0–T1 |
| `PRINCIPLES.md` | principles P-001…P-015, each with its tier and check; amended only by the owner | T0–T3 |
| `docs/` | templates for tasks, review and verify records, sprints, decisions; the process reference; `docs/failures.md` starts empty for your own incidents | T0 |
| `scripts/metrics/teamwright-metrics` | metrics from git, task records and journals | measurement |

Every gate has a documented exit for the case where it is wrong (for example `analysis: skipped:trivial` for a typo fix). Gates and exits: [docs/process/gates.md](docs/process/gates.md). Why the kit is shaped this way: [docs/design-decisions.md](docs/design-decisions.md).

## Tools

The process is fixed; the tools that serve it are chosen per project, one per capability, and stored in `.teamwright/config.yml`. No hook depends on a tool: gates read task files and records.

| Capability | Used for | Default | Alternatives |
|---|---|---|---|
| `spec` | large work: specify → clarify → plan → tasks | [Spec Kit](https://github.com/github/spec-kit) | [OpenSpec](https://github.com/Fission-AI/OpenSpec), plain `docs/specs/<name>.md` |
| `context` | code-aware search before analysis, implementation and review | [Serena](https://github.com/oraios/serena) | [CodeGraphContext](https://github.com/CodeGraphContext/CodeGraphContext), built-in search |
| `docs` | package API lookup for the pinned version | [Context7](https://github.com/upstash/context7) | the package's own docs |
| `ui_verify` | end-to-end UI runs for UI verify records | [Playwright](https://playwright.dev/) | [Patrol](https://github.com/leancodepl/patrol), [Flutter `integration_test`](https://docs.flutter.dev/testing/integration-tests), [Maestro](https://github.com/mobile-dev-inc/maestro), Espresso / XCUITest, none |
| `api_verify` | API runs for API verify records | the project's own test runner | — |

`/teamwright:reconfigure` swaps a provider. Details: [docs/process/tools.md](docs/process/tools.md).

## Known limitations

- Claude Code gates see Edit/Write and obvious shell rewrites; a script that writes files directly bypasses them. Git hooks and review are the backstop.
- `git commit --no-verify` / `git push --no-verify` skip the git hooks; CI has to repeat the checks that matter.
- Ledgers and journals are local (`.teamwright/`, gitignored): a review done on another machine is not recognised, and a machine without journals is absent from metrics, not zero.
- One active task per working tree; parallel sessions need separate worktrees.
- The review gate trusts `agent_type`: whoever can edit `.claude/agents/` can name an agent `code-reviewer`. Review agent definitions like code.
- The deny list matches command text, not every form of a command (`sh -c`, scripts).
- Patch-guard signatures and fix detection are heuristics: expect false positives until tuned to your stack.
- Metrics depend on conventions: missing `Co-Authored-By:` trailers, fixes not called fixes, squash merges and area granularity all move the numbers. No metric is a target.
- The verify gate checks that a `PASS` record exists for the current code, not that the tests were meaningful; the reviewer and the validator judge that.
- Tool-level gates are Claude Code-specific; other runtimes get `AGENTS.md`, the git hooks and the metrics.
- 0.x: behaviour may change between minor versions ([CHANGELOG.md](CHANGELOG.md)).

## Documentation

- [docs/usage.md](docs/usage.md) — onboarding, gate modes, `/teamwright:flow`, Docker runners, configuration, updating, manual install, metrics
- [docs/process/](docs/process/) — the process reference installed into projects: [lifecycle](docs/process/lifecycle.md), [gates](docs/process/gates.md), [roles](docs/process/roles.md), [sessions](docs/process/sessions.md), [principles](docs/process/principles.md), [metrics](docs/process/metrics.md), [tools](docs/process/tools.md); installer and config schema in [plugin.md](docs/process/plugin.md)
- [examples/](examples/) — the offline demo
- [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) · [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## Status

Early: 0.x, built and tried by its author on real projects — so far adoption of one existing project and the task loop on it. Bug reports from other stacks are the most useful contribution.

## Roadmap

- End-to-end run of `/teamwright:init` on a new project: spec → tasks → lifecycle → verification → metrics.
- More provider adapters (spec, context and UI runners) as projects need them.
- A Spec Kit extension or preset: task and constitution templates and a `tasks.md` → task-record bridge. The deterministic gates stay Claude Code and git hooks.
- Tool-level gates for more agent runtimes.

## Author and license

Konstantin Smykov ([@smykov](https://github.com/smykov)). MIT — see [LICENSE](LICENSE).
