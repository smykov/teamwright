---
name: sprint
description: Form a sprint for the autonomous contour — which tasks can go into the GitHub queue, which cannot and why, what would stop a chain, what must come first — and, after the owner's "yes", open their Issues and start the queue. Use when the owner asks to pick tasks for the autonomous queue, form a sprint, groom the backlog by user value, or choose candidates for a run.
argument-hint: "[N tasks] [goal, e.g. user value | measure | clear work] [T-NNN ...]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-sprint.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-groom.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" doctor *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-blockers.py" *) Bash(git status *) Bash(git log *) Bash(git add *) Bash(git commit *) Read Grep Write Edit
---

# /teamwright:sprint — what goes into the autonomous queue

Arguments: `$ARGUMENTS`. A sprint for the contour is the set of open Issues labelled `teamwright`. **The label starts spending money**: nothing here creates a label before the owner's "yes" on the exact list.

## 1. Data

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-sprint.py" --json
```

- `current_sprint` — `active`, the open labelled Issues with their `state` and `note`, the open pull requests from task branches.
- `candidates` — open tasks the queue can take: status, `stage`, priority, `surface`, `waits_for` (open `depends_on`), `overlaps`, `areas`, `acceptance_items`, `risks`, `value` (`kind` feature / invisible / owner, `group`, `reason`), `groom` (backlog facts on the record).
- `value_groups` — candidates by group, features first; `accelerators`: invisible tasks other tasks wait on.
- `plan_stages` — stages of `docs/plan.md` with a finding: no task, a release stage with no task, FR-NN with no task, a plan status that says "not started" while tasks are DONE.
- `excluded` — with the `reason`: already in the queue, `BLOCKED`, unanswered `blocked_on`.
- `follow_ups` — open follow-ups from every task (`items`), and `needs_task`: those at Medium or higher with no decision. Read from this tree: a line on an unmerged branch shows after its merge.
- `warnings` — unpushed commits, a task `IN_PROGRESS` on the default branch, a failed chain, GitHub not checked.

GitHub not checked → say so, do §1b, and stop: without the queue the current sprint is unknown.

Then `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" doctor --json --scope contour`: a contour check that is `missing` or `unknown` (the workflow, the model key secret, a label, an online runner, the CI dispatch) stops a chain before its first stage. Show those first, with class and fix; with any of them, a new sprint is offered only after the owner has fixed them or said to go anyway. `warn` lines (no branch protection, a shared runner) are shown once and do not stop.

## 1a. The current sprint comes first

`current_sprint.active` → **do not form a new sprint.** Show each Issue and pull request with what moves it, do §1b, and stop:

- `queued`, `running` — wait; `/teamwright:progress`.
- `stopped`, `failed`, `stalled` — `/teamwright:blockers`: fix the cause and set the label again, or take the task out of the queue on the owner's decision (remove the label).
- `finished`, or an open pull request — the owner merges through `/teamwright:blockers`; when the task is left at `CODE_COMPLETE`, set the label again for verify.

The candidates may be shown only if the owner asks to look ahead, marked as not startable yet. Adding to the running sprint is the owner's explicit decision: only after they ask for it, `issues … --add-to-current`.

## 1b. Open follow-ups

Show the count and the `needs_task` lines; the rest only if the owner asks (`--all-follow-ups`). For each `needs_task` line ask the owner: a task of its own, one umbrella task for several, or closed with a reason. No task is created without that answer: each one costs a full chain. On "a task", on the default branch after `git fetch` and fast-forward, with an id no remote branch uses: create it from the template (`type: chore`, `class: from-follow-up`, `priority: P3`, `surface: none`, `deploys: false`, the finding as Acceptance), end the line with `-> T-MMM`, commit. On "closed": `- [x] <the line> — closed: <why>`, commit. A line ending in `-> T-MMM` closes by itself when T-MMM is `DONE`; a follow-up of a `from-follow-up` task stays a line.

## 1c. Backlog facts

`groom` and `plan_stages` come from `scripts/tw-groom.py` (read-only; run it alone for the whole backlog, not only the candidates). Each is a fact with its evidence, not a verdict. Before proposing a task, read its record and settle each finding:

- `possibly-done` — read the named commits against the Acceptance. Done → leave it out and send it to `/teamwright:blockers` with the evidence; a full chain on it pays for nothing.
- `seam-changed`, `missing-path` — the record may describe code that moved: say so in the "what could stop it" column.
- `settled` — the block is over: `/teamwright:blockers` clears it.
- `too-large`, `duplicate` — propose a split or a merge to the owner; do not queue it as is.
- `inherits-priority` — it is worked at the higher priority already; say which task waits.
- `release-stage-empty`, `stage-empty` — offer the owner a task built from the stage's "Done when", created like a follow-up task (§1b) on their "yes".

A dismissed finding is not repeated.

## 2. Choose

Read the record of each task you are about to propose: `risks` come from a text match and can be wrong. A task whose acceptance needs a device, a person, a production key or an outside service goes out, with the reason. A `risks` line you checked and dismissed is not repeated.

The default size is 5 tasks; the owner's number wins. The goal changes the choice:

- **user value** — see §2a.
- **measure the contour** — a mix: different areas and types, not only the smallest, at least two tasks with overlapping seams when they exist. Say that a set of easy tasks would flatter the numbers.
- **clear work** (the default) — by `effective_priority`, then what the task unblocks.

The chosen goal reaches the router only through the sprint file (§2a, step 4) or priorities: without `process.ready.sprint_first` the router does not read sprint files.

### 2a. User value

For a mature backlog, where follow-ups, tests, guards and contour work crowd out what users wait for:

1. **Value table** from `value_groups`, after reading the records (the groups come from a heuristic; correct a wrong one and say why): feature, what the user gets, tasks, state. Then one line for the invisible tasks with their count, naming the accelerators and the flaky tests that redden other tasks' CI. Then the owner checks.
2. **Ask the goal**, one AskUserQuestion: 2–3 goals drawn from the top feature groups, plus "throughput first". Second question, what happens to the invisible tasks: **freeze except the named accelerators** (recommended: they stay in the backlog, outside the sprint) or leave them in the sprint. A `TODO` has no move to `DEFERRED`: freezing is leaving a task out of the sprint file, not a status.
3. **On "yes"**, write `docs/sprints/<N+1>.md` from the template: the goal, the tasks in their order in `## Tasks`, the frozen tasks in a `## Out of sprint` table, and a row in `docs/decisions.md`; commit `docs(sprint<N+1>): plan`.
4. **The router reads the sprint file only with `process.ready.sprint_first: true`** (`tw-next.py --json` → `settings.ready`). Then among ready tasks of equal effective priority the sprint's go first, and taking a task out of the table undoes it; a higher priority still wins. When it is off, say so and offer `/teamwright:settings`; editing priorities instead is the owner's explicit choice, one commit.

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
- Do not edit existing task records here: a task that needs an answer goes to `/teamwright:blockers`. Written here, each on the owner's "yes": a new task from a follow-up (§1b) or for an empty plan stage (§1c), and the sprint file with its decision row (§2a).
- No GitHub remote or no contour workflow in the project (doctor: `contour-workflow` missing) → do §1b, say that this command is for the autonomous queue, and offer `/teamwright:flow` or `/teamwright:parallel`.
