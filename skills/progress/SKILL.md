---
name: progress
description: Progress report for the owner — tasks done by sprint, plan stage, milestone and area in percent, what is in flight, the next tasks, what waits for the owner, risks and git state. With --adapt, studies how this repository keeps and counts its work (an existing progress command, the spec tool's task lists, areas, the milestone) and writes the project's adaptation. Use when the owner asks for status, progress, what is done and what is left.
argument-hint: "[--gate] [--adapt]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-progress.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" check-commands *) Bash(git status *) Bash(git log *) Bash(git fetch *)
---

# /teamwright:progress

Arguments: `$ARGUMENTS`. Without `--adapt` the command is read-only. `--gate` also runs every configured command (about a minute or more). `--adapt` runs the adaptation below and then the report.

The report is for the owner, in the language of `language` in `.teamwright/config.yml` (or the language the owner writes in). **Every number comes from the script and the commands below** — never from the session's memory or an estimate.

## 1. Data

```bash
git fetch -q; python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-progress.py" --json
```

(no remote or no network → skip the fetch and say "not fetched"). The JSON:

- `installed: false` → teamwright is not set up here; suggest `/teamwright:adopt` or `/teamwright:init` and stop.
- `total`, `by_status`, `by_sprint` (goal, `active`, `closed`, `pending_forks`), `by_area`, `by_stage` (tasks matched to a `docs/plan.md` stage by the FR-NN they name; `frs_without_tasks`), `current_stage`, `milestone` (from the adaptation);
- `next`, `ready`, `in_flight` — from the router (`tw-next.py`), the same answer `/teamwright:flow` gives;
- `owner` — `decisions` (BLOCKED, ESCALATE, NEEDS_OWNER, unpushed commits, a dirty tree), `open_questions`, `pending_forks`;
- `follow_ups` — open review findings below the blocking threshold (unchecked items in the sprint's `review-follow-up` task);
- `risks` — `verify_fail`, `open_rca`, `recurrences`, `two_plus_review_rounds`, `warnings`;
- `unassigned` — tasks no area matched; `analysed: false` means no `analysis.seam` yet, so the area is not known before analysis;
- `extra` — the project's own reader (`extra_command` in the adaptation), `errors`, `git`.

Percentages count `DONE` tasks; `DEFERRED` tasks are left out (their scope moved to the rca task). Say this once under the first table.

`.teamwright/progress.md` exists (`adaptation_notes: true`) → read it and follow it: it says what this project adds to the report. `adapted: false` and the owner asks for something the generic report lacks → offer `--adapt`.

With `--gate`: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" check-commands` in the foreground; report pass / fail / not runnable per area. Without it write "gate not run".

## 2. Report — in this order

1. **One line**: `done N / M (P %)`, the milestone `n / m (p %)` if there is one, the current stage, the branch and the last commit. Uncommitted files, unpushed commits, a branch behind its remote or a pause — say it here.
2. **By area** — table "Area | Done | Left | %", last row "Total". Unassigned tasks: one line — how many are not analysed yet, and which analysed ones match no area (fix: name the area's directory in `analysis.seam`, or a rule in the adaptation) — never distribute them by eye.
3. **By sprint** — "Sprint | Goal | Done | Closed". **By stage** — "Stage | Done | Target | FR without tasks". An FR with no task means the stage's scope is not planned yet: its percentage overstates progress — say so.
4. **Milestone** (if adapted) — the same per area, then the open task count and the stages it still needs, with their "Done when".
5. **Now and next** — `in_flight`, then `next` and the first `ready` tasks with the router's reason.
6. **Needs the owner** — `owner.decisions`, `open_questions`, `pending_forks`; when `next` itself waits for the owner, say it plainly: "the next step waits for you — …".
7. **Risks** — `risks` and `errors`; open follow-ups when they grow sprint over sprint. Nothing → omit the section.
8. **Extra** — what `.teamwright/progress.md` asks for, from `extra`.

Short: tables with one sentence each, no session history.

## 3. Adaptation (`--adapt`; also step "Progress report" of adopt and init)

Goal: the report counts this repository's work the way the repository keeps it. Look before writing:

1. **An existing progress command** — `.claude/skills/*/SKILL.md`, `.claude/commands/*.md`, `scripts/`, Makefile targets whose name or description says progress, status, dashboard, report. Read it and its script whole: which sources it reads, how it maps work to modules, what it calls the milestone (MVP, release), what it reports that the generic report does not (owner actions from `docs/decisions.md`, batches, gate results).
2. **Where the work lives** — `docs/tasks/` records; the spec tool's task lists (`specs/*/tasks.md`, `openspec/changes/*/tasks.md`) and whether their items already have records (`design_ref`); `TODO.md`, `docs/plan.md`, `docs/sprints/`; an issue tracker named in the docs. Count each source and compare.
3. **Areas** — run the script, look at `unassigned` and at a sample of tasks per area. Wrong or missing → the cheapest fix first: a directory in the seam (task records belong to their owner), then `area_rules`, then per-task `areas`.
4. **Milestone** — the release-1 scope in `docs/requirements.md` / `docs/plan.md`, or the existing command's MVP definition, as a list of plan stages.

Then propose, as one diff the owner approves:

- `.teamwright/progress.json` — only the keys needed: `areas`, `area_rules`, `milestone {name, stages}`, `extra_command`. The format is in the docstring of `${CLAUDE_PLUGIN_ROOT}/scripts/tw-progress.py`.
- `extra_command` only for work that lives outside task records — a project script (e.g. `scripts/progress-extra.py`, stdlib only, read-only, JSON on stdout) that ports what the existing command reads. It reports next to the records; it never changes their counts. Work that should be task records is a sprint task to convert it, not an extra source.
- `.teamwright/progress.md` — a few lines: what the existing command reported that this report must keep (sections, where owner actions are recorded, a gate shortcut), and which sources were left out and why.
- An existing progress command → keep, or replace with `/teamwright:progress` (owner decides; removal is `git rm` on "yes").

Run the script again and show the result before committing; commit on "yes" (`docs(progress): adapt the report to this repository`).
