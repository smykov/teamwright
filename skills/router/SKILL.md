---
name: router
description: Ask the teamwright router what to do now and do exactly one stage of it — analyze, red-tests, implement, review or verify — on the batch it allows, then stop at the barrier with a Stage, Batch and Outcome line. A merge, a push or an owner decision is reported or asked instead. One stage per session keeps each context fresh; run it again (or from a scheduler, one stage per job) for the next stage. Use for "do the next step" when every stage should be its own session.
argument-hint: "[--status]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(git status *) Bash(git log *) Bash(git diff *) Bash(scripts/tw-test *) Bash(scripts/tw-gate *) Bash(scripts/tw-run *)
---

# /teamwright:router — one stage, then stop

Arguments: `$ARGUMENTS` (`--status` → show the decision and stop).

0. **Context tools** — `docs/process/stage-protocol.md` §0: the provider from `tools.context` is connected and answers before any role is spawned; otherwise ask the owner, or end headless with `Outcome: escalate`.
1. **Ask**: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --brief` (no task list: `request` and the candidates come first and stay small). Show at most six lines: the router's `action`, `task`, `reason`, `stage`, `stages` (waiting per stage, held ones with why), `warnings`. The script did the selection by status and the counting; do not read task files to look for work (unless `settings.router.select` is `agent`: then `docs/process/stage-protocol.md` §2).
2. **Act on `action`**:
   - a stage (`stage` set; actions `start`, `continue`, `resume`, `review`, `verify`, `reanalyze`) → run **that one stage** exactly as `${CLAUDE_PLUGIN_ROOT}/skills/<stage>/SKILL.md` says — its Entry with `--brief --stage <stage>` (it returns the candidates and the batch cap), the batch choice, its Work. `resume` = unfinished work in the tree: start cold from evidence — the task record, `git status`, `git diff`, the log since its last `chore(task)` commit — keep only the task's changes, and finish the stage the router names;
   - `merge` → `/teamwright:parallel merge <task>` for a `tw/` branch, else report the branch and path; one merge, then stop;
   - `decide` → the owner's decision the reason names (push = DRAIN, ESCALATE, NEEDS_OWNER, a blocked question, uncommitted changes of no task): ask it (AskUserQuestion), record the answer in `docs/decisions.md`, act on it (a push: `git push`, tasks that deploy → `DEPLOYED`), stop;
   - `idle`, `paused`, `stop` → report, stop.
3. **Stop** after that one stage: do not ask the router again in this session. End with the stage's end block (`docs/process/stage-protocol.md` §4): `Stage:`, `Batch:` with the chosen tasks and the one-line reason, and `Outcome:` as the last line (`idle` for idle, paused or a refused stage).

`/teamwright:flow` does the same in a loop, in one session. In an autonomous run (CI, a scheduler) run this command once per job: `tw-next.py --json` → `headless.prompt` and `headless.model` name the stage command and the model; `headless` takes the first piece of work past an owner decision and lists the decisions (`docs/usage.md`, *Autonomous runs*).
