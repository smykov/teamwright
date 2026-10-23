---
name: review
description: Run the review stage of a teamwright project — for tasks in NEEDS_REVIEW, spawn a fresh code-reviewer per task (one at a time, never in parallel), read the verdict it records and move the task (APPROVE → CODE_COMPLETE with follow-ups filed, REQUEST_CHANGES → IN_PROGRESS at `stage: implement`, REJECT_RECURRENCE → DEFERRED, ESCALATE → BLOCKED). Asks the router first; review may wait for a batch (process.stages.review). Use when the router names the review stage.
argument-hint: "[T-NNN ...]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(git status *) Bash(git log *) Bash(git diff *)
---

# /teamwright:review — a fresh reviewer per task

You are the **orchestrator** of one stage session (`AGENTS.md`); the common protocol is `docs/process/sessions.md` §8. You never review: the reviewer is a fresh subagent, never a fork of you or of the author. Arguments: `$ARGUMENTS` (task ids; empty = the router's candidates).

## Entry

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --json --stage review [--task <ids, comma-separated>]
```

`request.ok` false → show `request.hint`, end (`Stage: review`, `Outcome: idle`). Otherwise choose the batch from `request.candidates` (§8). Reviewers run **one at a time**: parallel reviewers hit rate limits and lose verdicts.

## Work — per task, one after another

A candidate whose verdict is already recorded (the router's `continue` with role `orchestrator`: APPROVE or REJECT_RECURRENCE on file) needs only step 2.

1. Spawn a **fresh `code-reviewer`** (with `model: request.model` when it is set) with the task id and the commit range; the spawn's short description names only this task (`T-NNN code-reviewer`) — the review gate checks the spawn by it. It runs the gates the change needs through `scripts/tw-gate` and writes `docs/tasks/T-NNN.reviews/<n>.md`.
2. Read its verdict and change the status; commit the record with the change:
   - `APPROVE` → `NEEDS_REVIEW → CODE_COMPLETE`. Findings left in the record's table are below the threshold (`process.review.blocking`): append each as an unchecked line to the sprint's follow-up task — `docs/tasks/<ID>.md` with `class: review-follow-up`, `type: chore`, `priority: P3`, `surface: none`, `deploys: false`, `sprint:` the active sprint, title `Review follow-ups — sprint <N>`; create it from the template if the sprint has none. Line format under `## Acceptance`: `- [ ] T-NNN r<round>#<n> <Severity> <category>: <finding> (<where>)`. Commit `chore(task): T-NNN NEEDS_REVIEW→CODE_COMPLETE, follow-ups → T-MMM`. One follow-up task per sprint; at most two new tasks from one review. In a parallel worktree (`tw/<ID>`) write them under `## Follow-ups` in the task's own record instead.
   - `REQUEST_CHANGES` → `NEEDS_REVIEW → IN_PROGRESS` with `stage: implement` in the same edit (`stage: red-tests` when the findings are about the tests themselves); the next implement session takes it with the findings. After two send-backs in a row the third record is `ESCALATE` or `REJECT_RECURRENCE` (the review gate refuses an `APPROVE` there).
   - `REJECT_RECURRENCE` → `DEFERRED` with `absorbed_by: <rca id>`; the rca task enters the queue; the investigator's recommended exit (b) or (c) is a decision point.
   - `ESCALATE` → `BLOCKED`, decision point: ask the owner, go on with the next task of the batch.
