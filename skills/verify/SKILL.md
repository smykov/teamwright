---
name: verify
description: Run the verify stage of a teamwright project — for tasks at CODE_COMPLETE or later (after the push when they deploy), spawn a fresh task-validator that runs the committed tests against the running system, failure branch included, and writes the verify record and the acceptance verdict; then close the task (DONE), send it back (IN_PROGRESS / VERIFY_FAIL) or ask the owner (NEEDS_OWNER). Asks the router first. Use when the router names the verify stage.
argument-hint: "[T-NNN ...]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(git status *) Bash(git log *) Bash(git diff *)
---

# /teamwright:verify — the running system, recorded

You are the **orchestrator** of one stage session (`AGENTS.md`); the common protocol is `docs/process/sessions.md` §8 and the VERIFY session is §7 there. You never write a verdict yourself. Arguments: `$ARGUMENTS` (task ids; empty = the router's candidates).

## Entry

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --json --stage verify [--task <ids, comma-separated>]
```

`request.ok` false → show `request.hint`, end (`Stage: verify`, `Outcome: idle`). Otherwise choose the batch from `request.candidates` (§8). A task that deploys is verified after DRAIN (the push is the owner's decision — the router asks it as `decide`); a task with `deploys: false` is verified against a locally started system.

## Work — per task, one after another

A candidate whose verdict is already recorded (the router's `continue` with role `orchestrator`: acceptance PASS → close, FAIL → back) needs only step 2.

1. Spawn a **fresh `task-validator`** (with `model: request.model` when it is set) with the task id, `surface`, environment and commit. It runs the committed tests against the running system, failure branch included, and writes `docs/tasks/T-NNN.verify/<n>.md`, and the acceptance verdict `docs/tasks/T-NNN.validation/<n>.md` (verdict + the commit it checked). With `deploys: false` + `surface: none` it gives only the acceptance verdict. The router's reason says when this round must be `method: sweep` or `NEEDS_OWNER`.
2. Act on the records; commit them, and the validator's additions to `docs/tasks/T-NNN.mutants/`, with the status change:
   - verify `PASS` for the current commit and acceptance `PASS` → `VERIFIED → DONE` (the verify gate checks both);
   - verify `FAIL` → `VERIFY_FAIL`; the next analyze session re-analyses it;
   - verify `PASS`, acceptance `FAIL` → back to `IN_PROGRESS` with the findings and `stage: implement` (or `red-tests` when a test is missing or toothless), then a new review;
   - `NEEDS_OWNER` → decision point with the exact action needed.
   Survivors listed under `Follow-ups` go to the sprint's follow-up task (`- [ ] T-NNN v<round> mutant <name>: <what it changed>`), whatever the verdict.
