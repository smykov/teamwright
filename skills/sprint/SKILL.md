---
name: sprint
description: Form a sprint for the autonomous contour — which tasks can go into the GitHub queue, which cannot and why, what would stop a chain, what must come first — and, after the owner's "yes", open their Issues and start the queue. Use when the owner asks to pick tasks for the autonomous queue, form a sprint, or choose candidates for a run.
argument-hint: "[N tasks] [goal, e.g. measure | clear bugs] [T-NNN ...]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-sprint.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-blockers.py" *) Bash(git status *) Bash(git log *) Read Grep
---

# /teamwright:sprint — what goes into the autonomous queue

Arguments: `$ARGUMENTS`. A sprint for the contour is the set of open Issues labelled `teamwright`. **The label starts spending money**: nothing here creates a label before the owner's "yes" on the exact list.

## 1. Data

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-sprint.py" --json
```

- `current_sprint` — `active`, the open labelled Issues with their `state` and `note`, the open pull requests from task branches.
- `candidates` — open tasks the queue can take: status, `stage`, priority, `surface`, `waits_for` (open `depends_on`), `overlaps`, `areas`, `acceptance_items`, `risks`.
- `excluded` — with the `reason`: already in the queue, `BLOCKED`, unanswered `blocked_on`.
- `warnings` — unpushed commits, a task `IN_PROGRESS` on the default branch, a failed chain, GitHub not checked.

GitHub not checked → say so and stop: without the queue the current sprint is unknown.

## 1a. The current sprint comes first

`current_sprint.active` → **do not form a new sprint.** Show each Issue and pull request with what moves it, and stop:

- `queued`, `running` — wait; `/teamwright:progress`.
- `stopped`, `failed`, `stalled` — `/teamwright:blockers`: fix the cause and set the label again, or take the task out of the queue on the owner's decision (remove the label).
- `finished`, or an open pull request — the owner merges through `/teamwright:blockers`; when the task is left at `CODE_COMPLETE`, set the label again for verify.

The candidates may be shown only if the owner asks to look ahead, marked as not startable yet. Adding to the running sprint is the owner's explicit decision: only after they ask for it, `issues … --add-to-current`.

## 2. Choose

Read the record of each task you are about to propose: `risks` come from a text match and can be wrong. A task whose acceptance needs a device, a person, a production key or an outside service goes out, with the reason. A `risks` line you checked and dismissed is not repeated.

The default size is 5 tasks; the owner's number wins. The goal changes the choice:

- **measure the contour** — a mix: different areas and types, not only the smallest, at least two tasks with overlapping seams when they exist. Say that a set of easy tasks would flatter the numbers.
- **clear work** (the default) — by `effective_priority`, then what the task unblocks.

Rules for any set:

1. A task `IN_PROGRESS` on the default branch goes first: the router lets nothing else into code until its pull request is merged.
2. Keep `waits_for` chains short: a dependent task starts only after the owner merges the pull request before it.
3. Tasks that overlap run one after another, each waits for the other's merge. That costs time, not correctness.
4. `CODE_COMPLETE` candidates need only verify: cheap, but say what they prove.

## 3. Show

A table: order, task, type, area, surface, status, overlaps, waits for, why it is here, what could stop it. Then the near misses with the reason, and `excluded` in one line each.

The budget in one line: no limit exists for a sprint, only one per stage. Give an estimate from the project's own run reports when it has them and say where it comes from; otherwise say there is no basis for one.

Say what the owner will have to do along the way: merge the pull requests, answer what stops.

Ask once: **start these N tasks?** — "yes" / "only the Issues, no label" / "change the list".

## 4. Start, on the owner's "yes"

Warnings about unpushed commits are settled first: the queue works from the remote's default branch. Push only on the owner's "yes".

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-sprint.py" issues <ID> [<ID> ...]            # Issues, nothing starts
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-sprint.py" issues <ID> [<ID> ...] --start    # Issues and label: the queue starts
```

Labels go on in the order shown; the queue takes as many at once as it has places, the rest wait. Report each Issue, then point to `/teamwright:progress` for the run and `/teamwright:blockers` for what waits for the owner.

## Rules

- Never pass `--add-to-current` on your own judgement.
- Never label a task the owner did not approve, and never widen the list after the "yes".
- Do not edit task records here: a task that needs an answer goes to `/teamwright:blockers`.
- No GitHub remote or no contour workflow in the project → say that this command is for the autonomous queue, and offer `/teamwright:flow` or `/teamwright:parallel`.
