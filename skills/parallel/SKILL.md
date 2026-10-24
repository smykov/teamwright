---
name: parallel
description: Work several tasks at the same time — each in its own git worktree and Claude Code session — when their seams do not overlap. Analyses the ready tasks in the main tree, groups the disjoint ones (up to process.batch.parallel), creates the worktrees, and later merges each approved branch back (rebased, gate green) before one push. Use when the owner wants parallel work, or the router offers `merge`.
argument-hint: "[auto | plan | start | status | merge [T-NNN]]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-parallel.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(git status *) Bash(git log *) Bash(git worktree *) Bash(git merge --ff-only *) Bash(git branch -d *) Bash(scripts/tw-gate *) Bash(sleep *) Bash(git -C * rebase *)
---

# /teamwright:parallel — one task per worktree, merged back in order

Arguments: `$ARGUMENTS` (empty → `status`, then whatever is next).

**Why worktrees and separate sessions.** The gates keep one active task per working tree (`.teamwright/current-task`), and each session journals what its agents did. Parallel work therefore runs as separate sessions in separate worktrees — each with its own hooks, journal and active task — and this main session only coordinates: analysis, grouping, merging, the push. The pipeline per task is unchanged.

Limit: `process.batch.parallel` (`/teamwright:settings`; 1 = off). Script: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-parallel.py" <plan|start|status|logs> …`.

## 0. Auto — the orchestrator runs the tasks itself

`/teamwright:parallel auto` (also what a stage session starts when analysed tasks wait in `wip_waiting` and `process.batch.parallel` is above 1): the orchestrator does §1–§4 without handing commands to the owner, and keeps the worktrees full until no task is left or a pause.

1. **Context tool first** — `docs/process/stage-protocol.md` §0 in the main tree.
2. **Analyse** the next ready tasks in the main tree — the analyze stage, its batch up to `stages.analyze.batch` (raise it to the parallel limit for a night run).
3. **Plan and start**: `tw-parallel.py plan`, then `start <ids>` for the group (no question in auto: the settings are the owner's answer).
4. **Prepare the index**: `tw-parallel.py prepare <ids>` — the context tool's index copied from the main tree and refreshed in each worktree. An error → that worktree is not launched (its stage sessions would stop at §0 anyway); say which and why.
5. **Launch**: `tw-parallel.py launch <ids>` — in each worktree a background loop asks the router and runs one stage per `claude -p` session (fresh context each time) until the task is `CODE_COMPLETE`, needs the owner, is paused (`TEAMWRIGHT_PAUSE`) or stops moving. At most `batch.parallel` at once; the rest report `waiting`.
6. **Watch**: `tw-parallel.py status` every few minutes (`sleep 300` between checks). Per worktree: `run.running`, `run.stage`, `run.outcome` (`done`, `escalate` with the reason, `idle`, `stuck`, `paused`, `limit`, `error`), the log at `.teamwright/parallel/<ID>.log`.
7. **Merge** each `ready_to_merge` one by §4 (rebase, gate in the worktree, fast-forward, logs, remove). A slot is free → back to step 2 for the next tasks.
8. **Owner decisions** (`escalate`) are collected, not answered: the worktree stays, its question is in the task record; the others go on. At the end list them with `/teamwright:blockers`.
9. **Verify** the merged tasks in the main tree (`/teamwright:verify`, its batch), then the usual DRAIN question — or, headless, leave the push for the owner.

The limit is the machine as much as the setting: each worktree runs its own gates and its own context-tool server. Start with what the machine carries (a build-heavy project: two or three) and raise `batch.parallel` when the gates stay fast.

## 1. Plan — in the main tree

1. Parallel off (`parallel: 1`) → say so, offer `/teamwright:settings batch.parallel 2`, stop.
2. Seams are known only after analysis. Take the router's ready tasks (`tw-next.py --json`, `start` and its alternatives, up to the limit plus one or two) and run the analysis for each **in the main tree** exactly as the analyze stage does (`/teamwright:analyze` § Work steps 1–2: `TODO → ANALYSIS`, `problem-investigator` fills the block, commit `chore(task): T-NNN analysis`). **Do not move them to `IN_PROGRESS` here**: that happens in their worktree.
3. `tw-parallel.py plan` → `group` (disjoint seams, priority order), `skipped` with the reason (overlaps T-x; seam names no path → it runs alone in the main tree with `/teamwright:flow`; limit reached), `analysis_incomplete`. A vague seam is a reason to sharpen the analysis, not to guess.
4. Show the group and ask once: "start T-a, T-b in parallel?"

## 2. Start

`tw-parallel.py start <ids>` → per task: the worktree path (`<repo>.worktrees/<ID>`, next to the repository), branch `tw/<ID>`, and the launch command:

```
cd <path> && claude "/teamwright:flow <ID>"
```

Give the owner these commands: each one is a session they open (a terminal tab, a background job). In that session the router sees only its own task, drives it from `ANALYSIS → IN_PROGRESS` to `CODE_COMPLETE` with fresh role agents, keeps review follow-ups in the task's own record (`## Follow-ups`) instead of the shared sprint task, and never pushes; it ends `idle` with "merge it from the main tree".

## 3. Status

`tw-parallel.py status` → per worktree: the task's status on its branch, commits ahead and behind the main branch, uncommitted files, `ready_to_merge`. The main session's router shows `merge T-NNN` for a ready one and skips the others.

## 4. Merge — one branch at a time, in priority order

For each `ready_to_merge` task:

1. **Bring it up to date in its worktree**, so the main branch never gets an untested combination: behind the main branch → `git -C <path> rebase <main>`. Conflict → `git -C <path> rebase --abort`; the task's own session resolves it (rebase there, gate, and a new review round when code changed); skip this task for now.
2. **Gate in the worktree** after the rebase: `<path>/scripts/tw-gate <area>` for each gate `<path>/scripts/tw-gate --for-task <ID>` lists (exit 75 `RUNNING`: the same command again) — that worktree's own copy, so it runs there (a rebase changes the content, so nothing cached before it is reused). Red → back to its session; skip.
3. **Merge**: `git merge --ff-only tw/<ID>` in the main tree (a fast-forward: what was tested is what lands).
4. **Follow-ups**: move the task's `## Follow-ups` lines into the sprint's `review-follow-up` task (`/teamwright:review` § Work), commit.
5. **Journal and clean-up**: `tw-parallel.py logs <ID>` (appends that session's journal to the main one — metrics keep it), then `git worktree remove <path>` and `git branch -d tw/<ID>`. A worktree with uncommitted changes is not removed: report it.
6. Next task — the others are now behind by this merge: step 1 again for each.

After the merges: the usual DRAIN — one push question for every task merged (pre-push checks the whole tail) — then verification per task, as in `/teamwright:flow` §3 (Push) and the verify stage (`/teamwright:verify`).

Report: `Parallel: running <ids> · merged <ids> · waiting <id — reason> · next: <router decision>`.
