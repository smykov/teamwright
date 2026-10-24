---
name: parallel
description: Work several tasks at the same time — each in its own git worktree and Claude Code session — when their seams do not overlap. Analyses the ready tasks in the main tree, groups the disjoint ones (up to process.batch.parallel), creates the worktrees, and later merges each approved branch back (rebased, gate green) before one push. Use when the owner wants parallel work, or the router offers `merge`.
argument-hint: "[plan | start | status | merge [T-NNN]]"
disable-model-invocation: true
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-parallel.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(git status *) Bash(git log *) Bash(git worktree *) Bash(git merge --ff-only *) Bash(git branch -d *) Bash(git -C *)
---

# /teamwright:parallel — one task per worktree, merged back in order

Arguments: `$ARGUMENTS` (empty → `status`, then whatever is next).

**Why worktrees and separate sessions.** The gates keep one active task per working tree (`.teamwright/current-task`), and each session journals what its agents did. Parallel work therefore runs as separate sessions in separate worktrees — each with its own hooks, journal and active task — and this main session only coordinates: analysis, grouping, merging, the push. The pipeline per task is unchanged.

Limit: `process.batch.parallel` (`/teamwright:settings`; 1 = off). Script: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-parallel.py" <plan|start|status|logs> …`.

## 1. Plan — in the main tree

1. Parallel off (`parallel: 1`) → say so, offer `/teamwright:settings batch.parallel 2`, stop.
2. Seams are known only after analysis. Take the router's ready tasks (`tw-next.py --json`, `start` and its alternatives, up to the limit plus one or two) and run the analysis for each **in the main tree** exactly as `/teamwright:flow` §3 steps 1–2 do (`TODO → ANALYSIS`, `problem-investigator` fills the block, commit `chore(task): T-NNN analysis`). **Do not move them to `IN_PROGRESS` here**: that happens in their worktree.
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
4. **Follow-ups**: move the task's `## Follow-ups` lines into the sprint's `review-follow-up` task (`/teamwright:flow` §3 step 6), commit.
5. **Journal and clean-up**: `tw-parallel.py logs <ID>` (appends that session's journal to the main one — metrics keep it), then `git worktree remove <path>` and `git branch -d tw/<ID>`. A worktree with uncommitted changes is not removed: report it.
6. Next task — the others are now behind by this merge: step 1 again for each.

After the merges: the usual DRAIN — one push question for every task merged (pre-push checks the whole tail) — then verification per task, as in `/teamwright:flow` §3 steps 7–8.

Report: `Parallel: running <ids> · merged <ids> · waiting <id — reason> · next: <router decision>`.
