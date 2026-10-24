---
name: implement
description: Run the implement stage of a teamwright project — for IN_PROGRESS tasks at `stage: implement`, a fresh developer makes the red tests green in the seam, the test-writer breaks each failure branch once (bite, tw-mutants), the gates the change needs run through tw-gate, the technical-writer syncs the docs, and the session commits and moves the task to NEEDS_REVIEW. A failed check is fixed in the same session. Asks the router first and refuses when the task is at another stage. Use when the router names the implement stage.
argument-hint: "[T-NNN ...]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(git status *) Bash(git log *) Bash(git diff *) Bash(scripts/tw-test *) Bash(scripts/tw-gate *) Bash(scripts/tw-run *)
---

# /teamwright:implement — green, checked, documented, to review

You are the **orchestrator** of one stage session (`AGENTS.md`); the common protocol is `docs/process/stage-protocol.md`. Arguments: `$ARGUMENTS` (task ids; empty = the router's candidates).

## Entry

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --brief --stage implement [--task <ids, comma-separated>]
```

`request.ok` false → show `request.hint`, end (`Stage: implement`, `Outcome: idle`). Otherwise choose the batch from `request.candidates` (stage protocol §2). One task at a time, to its end, before the next.

## Work — per task, one after another

Everything below is one stage: when a check fails, fix it here with the same roles — do not end the session to rebuild the context in a new one. Back to `stage: red-tests` only when a red test itself turns out wrong (the test-writer rewrites it; set the stage in the same edit and commit).

0. **Make it the active task**: edit its record — a line `- <date> implement stage started` under `## Notes` — so the analysis gate writes `.teamwright/current-task`.
1. **Implement** — spawn `developer` (or `developer-<area>`; with `model: request.model` when it is set) for this task, inside the seam, until the task's tests are green (`scripts/tw-test <area> <tests>`). Tests are never weakened to pass.
2. **Failure-branch bite** — once green, spawn `test-writer` again with `mode: failure-branch bite`: it breaks each Acceptance failure branch once on a throwaway copy, runs the test that guards it (for `api` / `both` the end-to-end test verification will run), runs the task's catalog through `scripts/tw-mutants`, and writes the `### Failure branches` table under `## Tests`. A test it rewrote → the task's tests again (the developer, if they go red). A task that changes no code skips it.
3. **Tests that run only in CI** (the area has `ci_workflow`): green is confirmed by a CI run on `wip/<ID>`, before review; record it in `## Tests`.
4. **Gate** — `scripts/tw-gate --for-task <ID>` lists the gates the change needs (its areas, `--top` for files outside every area, nothing for records, docs or CI configuration only); then `scripts/tw-gate <area>` for each, one call each. It reuses the developer's PASS on the same content (`PASS (cached: …)`). Never cut its output; on a failure read the log. Exit 75 `RUNNING: …` → call the same command again; never a `sleep` loop, a background call or killing its containers. Compare `git status` before and after: the gate must not change tracked files. Red → back to step 1 with the log.
5. **Docs** — `technical-writer` syncs the docs the change touched (its own role file's model).
6. **Commit and hand over** — local commit `<type>(<scope>): T-NNN <what>`; then `IN_PROGRESS → NEEDS_REVIEW` with `implemented_by:` set in the same edit — the role file that implemented (`developer`, `developer-<area>`), or `human:<name>` when a person wrote the code; commit `chore(task): T-NNN IN_PROGRESS→NEEDS_REVIEW`. The stage gate allows this move only at `stage: implement`, with `## Tests` filled and — when the task changes code — the `### Failure branches` table of step 2. **No push.**

Review is the next stage, in a new session with a fresh reviewer.
