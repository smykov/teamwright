---
name: review
description: Run the review stage of a teamwright project — for tasks in NEEDS_REVIEW, spawn a fresh code-reviewer per task (one at a time, never in parallel), read the verdict it records and move the task (APPROVE → CODE_COMPLETE with follow-ups filed, REQUEST_CHANGES → IN_PROGRESS at `stage: implement`, REJECT_RECURRENCE → DEFERRED, ESCALATE → BLOCKED). Asks the router first; review may wait for a batch (process.stages.review). Use when the router names the review stage.
argument-hint: "[T-NNN ...]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(git status *) Bash(git log *) Bash(git diff *)
---

# /teamwright:review — a fresh reviewer per task

You are the **orchestrator** of one stage session (`AGENTS.md`); the common protocol is `docs/process/stage-protocol.md`. You never review: the reviewer is a fresh subagent, never a fork of you or of the author. Arguments: `$ARGUMENTS` (task ids; empty = the router's candidates).

**Before any role: §0 of the protocol** — the context tool from `tools.context` is connected and answers (one cheap call), else no role is spawned: ask the owner; headless, go on with the built-in search, tell the role so, and the record says `context_tool: builtin — <why>`. Every role's spawn prompt starts with the code-search line (§3).

## Entry

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --brief --stage review [--task <ids, comma-separated>]
```

`request.ok` false → show `request.hint`, end (`Stage: review`, `Outcome: idle`). Otherwise choose the batch from `request.candidates` (stage protocol §2). Reviewers run **one at a time**: parallel reviewers hit rate limits and lose verdicts.

## Work — per task, one after another

A candidate whose verdict is already recorded (the router's `continue` with role `orchestrator`: APPROVE or REJECT_RECURRENCE on file) needs only step 2.

1. Spawn a **fresh `code-reviewer`** (with `model: request.model` when it is set) with the task id and the commit range; the spawn's short description names only this task (`T-NNN code-reviewer`) — the review gate checks the spawn by it. It runs the gates the change needs through `scripts/tw-gate` and writes `docs/tasks/T-NNN.reviews/<n>.md`.
2. Read its verdict and change the status; commit the record with the change, together with the stamp the review gate wrote next to it (`docs/tasks/T-NNN.reviews/<n>.gate.json` — a status move in a later session, e.g. the next CI job, is checked against it):
   - `APPROVE` → `NEEDS_REVIEW → CODE_COMPLETE`. Findings left in the record's table are below the threshold (`process.review.blocking`): write each as an unchecked line in the task's own record, `docs/tasks/T-NNN.follow-ups/r<round>.md`, so branches never meet in a shared file. Line format: `- [ ] T-NNN r<round>#<n> <Severity> <category>: <finding> (<where>)`. No task is created here: a Medium or higher finding waits as a line for the owner's decision in `/teamwright:sprint` and `/teamwright:blockers`. Commit `chore(task): T-NNN NEEDS_REVIEW→CODE_COMPLETE, follow-ups recorded`. Lines are closed as `- [x] ... — closed: <why>`.
   - `REQUEST_CHANGES` → `NEEDS_REVIEW → IN_PROGRESS` with `stage: implement` in the same edit (`stage: red-tests` when the findings are about the tests themselves); the next implement session takes it with the findings. After two send-backs in a row the third record is `ESCALATE` or `REJECT_RECURRENCE` (the review gate refuses an `APPROVE` there).
   - `REJECT_RECURRENCE` → `DEFERRED` with `absorbed_by: <rca id>`; the rca task enters the queue; the investigator's recommended exit (b) or (c) is a decision point.
   - `ESCALATE` → `BLOCKED`, decision point: ask the owner, go on with the next task of the batch.
