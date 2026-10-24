---
name: analyze
description: Run the analyze stage of a teamwright project — start ready tasks (TODO → ANALYSIS) or take tasks back from a failed verification, have a fresh problem-investigator write each analysis block, and move each task to IN_PROGRESS at `stage: red-tests`, one task after another, up to the stage's batch. Asks the router first and refuses, with the right command, when the work belongs to another stage. Use for "analyse the next tasks" or when the router names the analyze stage.
argument-hint: "[T-NNN ...]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(git status *) Bash(git log *) Bash(git diff *)
---

# /teamwright:analyze — the analysis, then IN_PROGRESS at red-tests

You are the **orchestrator** of one stage session (`AGENTS.md`). The protocol every stage command follows — the router question, choosing the batch, role agents in the foreground, commits, the end block — is `docs/process/stage-protocol.md` (short; read it once), then do the steps below. Arguments: `$ARGUMENTS` (task ids; empty = the router's candidates).

## Entry

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --brief --stage analyze [--task <ids, comma-separated>]
```

`request.ok` false → show `request.hint` (it names the command to run instead), do nothing else, end with the end block (`Stage: analyze`, `Outcome: idle`). Otherwise choose the batch from `request.candidates` (stage protocol §2).

## Work — per task, one after another

1. **Start** (`action: start`): `TODO → ANALYSIS`, commit `chore(task): T-NNN TODO→ANALYSIS`. With `process.autonomy.start: ask` ask the owner once, before the first task, which of the candidates to start (the router's order first). A task back from `VERIFY_FAIL`: `VERIFY_FAIL → ANALYSIS`, and pass the failed verify record to the investigator as evidence — a failed verification means the analysis missed something.
2. **Analysis** — spawn `problem-investigator` (with `model: request.model` when it is set) for this task only. It fills the `analysis` block with evidence (`file:line`, log line, failing test), invariant, seam, approach, and the recurrence check against `docs/failures.md`. A `chore` with no degrees of freedom may use `analysis: skipped:trivial`.
   - The analysis shows the work is **large** (more than one seam, unsettled behaviour) → decision point "send through the spec tool?" (§5 of `/teamwright:flow`); stop the batch here.
   - Evidence missing → `ANALYSIS → BLOCKED` with `blocked_on`, commit, go on with the next task of the batch.
3. **Into IN_PROGRESS** — only when no other task of this working tree is `IN_PROGRESS` (one per tree: the router holds the rest, `state.wip_waiting`); otherwise commit the analysis (`chore(task): T-NNN analysis, waits for T-MMM`), leave the task in `ANALYSIS` and go on with the batch. In **one edit** of the task record: `status: IN_PROGRESS` and `stage: red-tests` (the analysis gate checks the block; the stage gate refuses `stage: implement` here). Commit the analysis with it: `chore(task): T-NNN ANALYSIS→IN_PROGRESS`.

The next stage is `red-tests`, in a new session (`/teamwright:router`, or the flow when it loops). Do not write tests here.
