---
name: improve
description: Analyse how the process is working in this project — send-back rate, review findings by severity and category, rounds per task, DRAIN exceptions, bookkeeping share, record sizes, context-tool use, metrics before and after the last settings change — and propose changes, each routed to where it belongs: a process setting, a project rule, or feedback to teamwright. Nothing is applied without the owner's yes. Use when the process feels slow or costly, after a sprint, or after changing settings.
argument-hint: "[--since YYYY-MM-DD]"
disable-model-invocation: true
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-process.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-context.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-progress.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(python3 scripts/metrics/teamwright-metrics *) Bash(git log *) Bash(git status *)
---

# /teamwright:improve — measure, diagnose, propose

Arguments: `$ARGUMENTS`. The pipeline is fixed; what can change here is a **setting**, a **project rule**, or **teamwright itself**. Every conclusion carries a number and its source; nothing comes from an agent's impression of how things went.

## 1. Data — scripts only

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-process.py" --json      # findings, verdicts, settings history, ratified, bookkeeping, records, follow-ups
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-context.py" --json      # context tool: languages indexed, share of code reading through it
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-progress.py" --json     # tasks, sprints, risks
python3 scripts/metrics/teamwright-metrics --json [--since …]      # lead time, rework, review rounds, recurrence, journal facts, per stage (journal.stages)
```

The settings changed (`settings_history` has more than one entry) → also `tw-process.py --json --split-date <date of the last change>` (verdicts, findings by severity and category, send-backs without a finding at the threshold in force — before and after) and `teamwright-metrics --json --split-date <date>` (lead time, rework, rounds). `--since <date>` narrows both to a period. Read the previous report in `docs/process-reviews/` if there is one: what was proposed, what was accepted.

## 2. Diagnosis — where the process costs more than it returns

Look at least at these, and say "fine" when they are:

| Signal | From | Typical reading |
|---|---|---|
| Send-back share, rounds per task | `tw-process` verdicts, rounds, `send_backs_without_blocking` | High share with mostly Low findings → the threshold, not the code, is the cost; send-backs with no finding at the threshold in force → the reviewer works from another threshold (a role file that kept an old value: `render_drift` in `tw-process`) |
| Findings by severity and category; categories that returned tasks | `tw-process` findings | Many `docs-drift` → docs referenced by line numbers, or no writer step; many `toothless-test` caught by review → tests are checked too late |
| DRAIN exceptions | `tw-process` ratified | Each is a false positive or a deliberate risk: read the commits |
| Bookkeeping share | `tw-process` bookkeeping | Most commits are `chore(task)` → CI runs on them? (`paths-ignore` on push, `scripts/tw-ci-changes` for pull requests — [usage](../../docs/usage.md#ci-record-only-pushes)) |
| Record sizes | `tw-process` records | Large `analysis` blocks re-read by every role → move investigation history out |
| Context tool | `tw-context` | A language not indexed, a role reading around the tool |
| Lead time, rework, recurrence, escalations, interrupted sessions | `teamwright-metrics` | Where time goes; whether recurrences get their rca task |
| Open follow-ups | `tw-process` follow_ups | Growing without being worked → the threshold is too high for the team's pace |
| Cost per stage: sessions, duration, tool calls, outcomes, tasks, tokens (per task, per model), cost | `teamwright-metrics --json` → `journal.stages` (cost with `--prices <json>` when the owner gives prices) | One stage taking most of the tokens or time per task → its model (`models.<stage>`), its batch (`stages.<stage>.batch`: context rebuilt per task) or its role instructions; many `escalate`/`none` outcomes at one stage → where sessions break. `no data` for tokens = journal older than 0.12 or no transcript path — say so, do not estimate |

Also what works: name it, so a proposal does not break it.

## 3. Proposals — each with its route

| Kind | Route | Who applies |
|---|---|---|
| **Setting** — threshold, pass size, autonomy, model or batch per stage | the exact `/teamwright:settings <key> <value>` and the number behind it | owner, through `/teamwright:settings` |
| **Project rule** — a check, a convention, a doc practice that belongs to this project | process amendment, exit (c) of `docs/process/lifecycle.md` §6: `PRINCIPLES.md` change in its own commit + a row in `docs/decisions.md` | owner decides, orchestrator writes |
| **Environment** — CI trigger, a missing language server, a cache | a task in the active sprint (`type: chore`) | flow |
| **teamwright itself** — a gate's false positive, a missing capability, a role instruction that misleads | a draft for `/teamwright:feedback` (problem, numbers, proposed change — no project names, paths or code) | owner sends it |

At most 5–7 proposals, ordered by expected effect; for each: the evidence, the change, what it might cost, and how the next `improve` will tell whether it helped.

## 4. Record and ask

1. Write `docs/process-reviews/<YYYY-MM-DD>.md`: data summary (numbers with sources), diagnosis, proposals with routes, and — when a previous report exists — "what changed since": the accepted proposals and their before/after numbers.
2. Ask the owner per proposal (AskUserQuestion, several at once): apply / skip / later.
3. Apply only what was accepted, by its route: run `/teamwright:settings` for settings, write the `PRINCIPLES.md` amendment and the decision row, create the chore tasks, hand the feedback drafts to `/teamwright:feedback`.
4. Commit the report and what was applied on one "yes": `docs(process): review <date>`.

Report: `Process review <date>: <n> proposals — settings <n>, rules <n>, tasks <n>, feedback <n>; accepted <n>. Report: docs/process-reviews/<date>.md`.
