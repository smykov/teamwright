---
name: red-tests
description: Run the red-tests stage of a teamwright project — for IN_PROGRESS tasks at `stage: red-tests`, a fresh test-writer writes one failing test per guarantee (a reproducing test for a bug, an end-to-end test for the failure branch), runs the bite check and the task's mutant catalog, confirms the tests fail for the right reason, and the session commits them with `stage: implement`. Asks the router first and refuses when the task is at another stage. Use when the router names the red-tests stage.
argument-hint: "[T-NNN ...]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(git status *) Bash(git log *) Bash(git diff *) Bash(scripts/tw-test *) Bash(scripts/tw-run *)
---

# /teamwright:red-tests — failing tests first

You are the **orchestrator** of one stage session (`AGENTS.md`); the common protocol is `docs/process/stage-protocol.md`. Arguments: `$ARGUMENTS` (task ids; empty = the router's candidates).

## Entry

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --brief --stage red-tests [--task <ids, comma-separated>]
```

`request.ok` false → show `request.hint`, end (`Stage: red-tests`, `Outcome: idle`). Otherwise choose the batch from `request.candidates` (stage protocol §2). One task at a time: the gates keep one active task per working tree.

## Work — per task, one after another

1. **Make it the active task**: edit its record — a line `- <date> red-tests stage started` under `## Notes` — so the analysis gate writes `.teamwright/current-task` (the journal and a later resume attribute the work to it; the file is not writable directly). Commit nothing yet.
2. Spawn `test-writer`, first spawn (with `model: request.model` when it is set), for this task only: one failing test per guarantee in Acceptance, a reproducing test for a bug, an end-to-end test for the **failure branch** when `surface` is `ui` / `api` / `both`. It also runs the bite check — 2–3 deliberately wrong implementations in a throwaway copy, each caught by a test, recorded under `## Tests`; mutations of existing code go into the catalog `docs/tasks/<ID>.mutants/`, which `scripts/tw-mutants` runs in one toolchain start. Code without tests in the seam → characterization tests first, capturing current behaviour.
3. Confirm red: `scripts/tw-test <area> <the new tests>` fails, and for the right reason (the missing behaviour, not a typo or an import error). Read the log it names; never cut the output.
4. **Tests that run only in CI** (the area has `ci_workflow`): commit the tests, `git push origin HEAD:wip/<ID>` (a `wip/*` branch is not a delivery) and wait for the run (`gh run watch`; no `gh` → ask the owner); record the run link and result in `## Tests`.
5. Commit the tests, the catalog and the record together, with `stage: implement` set in the same edit of the record that finishes `## Tests`: `test(<scope>): T-NNN red tests` (the record change in the same commit, or `chore(task): T-NNN red tests recorded, stage implement` right after). The stage gate allows `red-tests → implement` only; the router checks `## Tests` is filled.

A task whose change has no code (an rca exit (b) or (c)) has no red tests: write that in `## Tests` (`none — rca exit (b), decision #N`) and set `stage: implement`.
