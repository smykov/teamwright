# Design decisions

Why teamwright is shaped the way it is. Each entry: context → decision → why.

## A layer on top of Spec Kit, not a replacement

**Context.** Spec-driven tools already cover specify → plan → tasks well.
**Decision.** teamwright starts where the spec tool's task list ends: each task becomes a `docs/tasks/T-NNN.md` record with `design_ref`, and from there the lifecycle, review, verification and metrics are teamwright's. [Spec Kit](https://github.com/github/spec-kit) is the default spec provider; [Serena](https://github.com/oraios/serena) the default for code navigation.
**Why.** The gap in agentic development is not planning but what happens after: agents patching symptoms, unreviewed merges, "done" without evidence. Competing on planning would add nothing.

## The core workflow

**Decision.** A spec for large work → TDD → review that checks for recurrence → verification of the running system (API tests, or an end-to-end UI run) → metrics from git and logs. A recurrence sends the task back to the architecture level instead of accepting another patch.
**Why.** A defect class patched again and again in one place is a design problem; reviews that only look at the diff never see it.

## Three exits from a recurrence

**Decision.** A repeated defect class is resolved at one of three levels: (a) code — an invariant in one seam, via an `rca` task; (b) architecture — `/arch-review`, owner decision, and a new spec if the change crosses seams; (c) process — a versioned amendment of `PRINCIPLES.md`. Each exit ends in `docs/decisions.md`.
**Why.** "Fix the root cause" is not actionable without saying where the root lives.

## A verification gate

**Decision.** A task cannot reach `VERIFIED` or `DONE` without a `PASS` verify record for the current code, matching the task's `surface` (`api`, `ui`, `both`, `none`). `kind: manual` is allowed only with a recorded `verify_exception`. The UI record names the tool (Playwright, Flutter `integration_test`, Patrol, Maestro, …).
**Why.** Passing unit tests and an approving review say nothing about the deployed system. The evidence must be a test run, not a statement.

## Gates are deterministic hooks

**Decision.** Rules that matter are enforced by Claude Code hooks and git hooks reading task files and records, not by prompt instructions. Review identity is the reviewer's `session_id` + `agent_id`, and only a code-reviewer may write review records.
**Why.** Instructions drift as context grows; a hook either allows the action or it does not. Known bypasses (writing files from a script, `--no-verify`) are documented rather than hidden.

## Describe the target process, not the current practice

**Decision.** The kit encodes the process a team should run. When a project lacks something the process needs (for example end-to-end UI tests), the project is brought up to the kit, not the kit down to the project.
**Why.** A template fitted to one project's habits carries its workarounds into every other project.

## Distributed as a Claude Code plugin

**Decision.** The repository is its own plugin marketplace. `/teamwright:adopt` fits an existing project, `/teamwright:init` starts a new one, `/teamwright:flow` runs and resumes the task loop. Hooks are installed into the project, not globally. Adoption starts in gate-first mode; init ends in enforce, because a project built to the process has no legacy to excuse a red gate.
**Why.** Copying a template by hand does not scale and cannot be updated; a plugin can be installed with one command and re-applied on update without overwriting local edits.

## Tools are pluggable, the process is fixed

**Decision.** At onboarding the owner picks a provider per capability — `spec`, `context`, `docs`, `ui_verify`, `api_verify` — and missing MCP servers are installed with consent. The choice lives in `.teamwright/config.yml`; no hook depends on a tool.
**Why.** Projects differ in stack and tooling; the value is the process and its gates, which must survive a tool swap.

## Step parameters are settings, the pipeline is not

**Decision.** A closed list of parameters of fixed steps is set per project in `process:` of `.teamwright/config.yml`: the review blocking threshold, how many tasks a flow pass takes (per priority), and autonomy (start without asking, continue after a barrier). Statuses, roles, gates, records and the escalation rule do not change. Hooks and the router read the settings, so they are checked, not just written down; agents cannot edit the config, so an agent cannot loosen its own threshold. A missing key is the earlier behaviour.
**Why.** A pilot spent 46 % of its review rounds on send-backs while 127 of 192 findings were Low: one full round each — tests, developer, gate, a fresh reviewer — for style. Rewriting the role files locally does not survive a kit update; a fork of the process per project does not compare. A threshold the owner sets and the gate enforces keeps the pipeline common and its cost tunable, and metrics split at the date of the change show whether it helped (`/teamwright:improve`).

## Toolchains can run in containers

**Decision.** Each area's commands run on the host or in Docker (`scripts/tw-run`), set per area in the config. A command that could not exercise the code is reported as `not runnable`, not as a failure.
**Why.** A gate that fails because a toolchain is missing on the machine teaches agents to ignore gates.

## Requirements before the stack

**Decision.** `/teamwright:init` starts with the requirements document, not with a stack question. The owner's brief is the base, or an interview fills a fixed ten-section template (Jobs To Be Done, story map with MoSCoW, EARS requirements with a failing example, measurable non-functional requirements, constraints and install policy, glossary, integrations, technical decisions, assumptions). A fresh `requirements-reviewer` roasts each draft until it is ready, and the owner approves it; the stack, the deploy target and UI verification are derived from it. Spec tools then work per feature from the approved version.
**Why.** A stack chosen before the requirements decides them by accident, and a spec tool works one feature at a time — nobody checks the product as a whole. The author of a draft fills its gaps with what they meant; a reviewer that reads only what is written finds the requirement nobody can test and the flow that stops halfway, before they become code. The roast is economical by design: Medium and Low findings go as one batch, and a new round runs only when an accepted change alters what gets built.

## Acceptance is a record, not a sentence

**Decision.** The task-validator's acceptance verdict is a record, `docs/tasks/<ID>.validation/<n>.md`, with the commit it checked, written through the verify gate like a verify record. `DONE` needs the latest verdict `PASS` for the task's current code — also for a task with nothing to deploy.
**Why.** In the first full task cycle on a pilot, a task with nothing to deploy reached `DONE` with no acceptance at all, because "the orchestrator reads the verdict" was a rule no hook checked. A verdict line in free text could be stale after rework, revived by deleting a later `FAIL`, or missed for its formatting; a record with a commit and a ledger cannot.
