---
name: flow
description: Start or resume development on a teamwright project — a loop of router steps in one session. The router computes the next action and its stage deterministically (resume an interrupted task, analyze, red-tests, implement, review, verify, ask the owner, or start the next ready task); the flow shows a one-screen status, runs that stage as its stage command describes, and asks the router again, asking the owner only at decision points. Use when asked "what next", to continue work, or to pick up after an interruption. For one stage per session use /teamwright:router.
argument-hint: "[T-NNN] [--tasks N] [--status]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(git status *) Bash(git log *) Bash(git diff *) Bash(scripts/tw-run *)
---

# /teamwright:flow — the next step, then the lifecycle

You are the **orchestrator** (the main session in `AGENTS.md`): you pick the task, call the roles, change statuses and commit. You never review your own work and never write review or verify records yourself.

The flow is a loop of router steps in one session: ask the router, run the stage it names (each stage is described once, in its own command), ask again. `/teamwright:router` runs exactly one step per session; the stage commands (`/teamwright:analyze`, `red-tests`, `implement`, `review`, `verify`) run one named stage. All three follow the same stages and the same short protocol (`docs/process/stage-protocol.md`; the long explanation is `docs/process/sessions.md` §8).

Arguments: `$ARGUMENTS`
- `T-NNN` — work on this task instead of the router's pick (still subject to readiness and the gates; say so if the router disagrees and why).
- `--tasks N` — lower the pass cap for this run (never above the project's `process.batch`, see `docs/process/sessions.md` §3).
- `--status` — show the status screen and the router's decision, then stop.

Project files you follow (read them, do not restate them from memory): `AGENTS.md`, `docs/process/lifecycle.md`, `docs/process/sessions.md`, `PRINCIPLES.md`, `CLAUDE.md`, the task record, `.teamwright/config.yml` (read-only for you).

## Two rules that hold for the whole session

1. **Role agents run in the foreground.** Spawn every role agent (`problem-investigator`, `test-writer`, `developer`, `technical-writer`, `code-reviewer`, `task-validator`) as a blocking call and act on its result in the same turn: do not set `run_in_background`; if the runtime starts it in the background anyway, wait for its result with the runtime's blocking wait or output tool (one call that returns when the agent finishes) before doing anything else. Do **not** poll in a loop, and do not `sleep` — runtimes block it and each poll costs a turn. **No blocking wait available** → do nothing else: end the turn with one line ("waiting for <role> on T-NNN") and no `Outcome:` line. The Stop hook journals `outcome: waiting`, the runtime's completion notification starts your next turn, and you pick up from the result — commit, re-run the router, continue. What is never allowed is doing other work, or ending the session, while a role is still running: its result would land uncommitted and the task would stay in a transient status.
2. **After each role result**: read what it wrote, commit its record and the status change (§3), re-run the router (§1), and continue or stop by §6. Then the next step, or the end-of-session block (§7).

## 0. Context tools are connected

Read `tools.context` (and `tools.docs`) in `.teamwright/config.yml`. When it names an MCP-based provider (e.g. `serena`, `context7`), check that its tools are actually available in this session (the tool list, or `claude mcp list` in a terminal). Not available → say once: "<provider> is configured but not connected in this session — falling back to the built-in search (grep/glob/read); restart Claude Code and approve the server to use it", pass the same note to every role you spawn, and continue. Never stop the flow for this.

## 1. Ask the router

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --brief --pass "<ids this run has started, comma-separated; empty at first>"
```

`--pass` makes the router apply the project's process settings (`settings` in its output): the pass cap from `process.batch` (`budget`: taken, limit, left — lowered further by `--tasks`), and `autonomy.start` (`ask_owner: false` on `start` when it is `auto`). Count only tasks this run moved `TODO → ANALYSIS`.

It reads `docs/tasks/*.md` (with their `.reviews/` and `.verify/` records), the journals in `.teamwright/logs/`, `.teamwright/current-task`, the gate mode, `TEAMWRIGHT_PAUSE`, and git state (dirty tree, unpushed commits), and prints one decision:

| Field | Meaning |
|---|---|
| `action` | what to do next — one of `resume`, `continue`, `review`, `verify`, `reanalyze`, `decide`, `start`, `idle`, `paused` (table below) |
| `task` | the task id the action applies to (`T-NNN`), or `null` for `idle` / `paused` |
| `reason` | one line: why this action wins — the rule and the evidence (status, missing record, dirty files, interrupted session) |
| `alternatives` | other candidates in router order, each `{action, task, reason}` — shown to the owner when they want to pick something else |
| `role` | who acts: `orchestrator` (status moves, records), a role agent (e.g. `code-reviewer`, `task-validator`), or `owner` |
| `ask_owner` | `true` when this step is a decision point — ask before acting |
| `state` / `counts` | snapshot used for the status screen (gate mode, pause, git state; tasks by status). `--brief` leaves out the task list; `--json` (full) has it, open tasks only, with `ready`, `blockers`, `effective_priority` |
| `warnings` | record problems the router sees but does not decide on — e.g. a task that mentions an unresolved `OQ-NN` with an empty `blocked_on`, or a `stage:` field the evidence contradicts |
| `stage` | the stage that does this action: `analyze`, `red-tests`, `implement`, `review`, `verify`, or `null` (decide, merge, idle) |
| `candidates`, `batch`, `batch_cap` | the tasks waiting at that stage with the facts for choosing a batch (priority, unblocks, depends_on, seam paths, areas, overlaps, size); the router's default batch; the stage's cap |
| `stages`, `work_available`, `model` | per stage: waiting tasks, whether it is due (`process.stages`); whether any work exists; the stage's model (`process.models`, `null` = the role files decide) |

Notes on the helper's semantics: `paused` is checked before everything else; untracked files alone never trigger `resume`; `continue` with `role: orchestrator` also covers bookkeeping moves (APPROVE recorded → `CODE_COMPLETE`, REJECT_RECURRENCE → defer, PASS verify → advance, `deploys: false` + `surface: none` → close) — `reason` says which; `decide` also covers ESCALATE, uncommitted changes that belong to no single task, and unpushed commits (push needs the owner).

Router order (the helper applies it; you do not re-derive it):

| Order | Situation | `action` | What you do |
|---|---|---|---|
| 1 | Tracked changes in the tree, or the last session ended `interrupted` | `resume` | §4 Resume |
| 2 | A task in `ANALYSIS` / `IN_PROGRESS` | `continue` | its stage (`analyze`, or `red-tests` / `implement` by the task's `stage:` field checked against the evidence) — §3 |
| 3 | `NEEDS_REVIEW` without a review record for the current code | `review` | stage `review` — §3 |
| 4 | `CODE_COMPLETE` / `DEPLOYED` without a `PASS` verify record for the current code | `verify` | stage `verify` — §3 (after DRAIN when it deploys) |
| 4 | `VERIFY_FAIL` | `reanalyze` | stage `analyze`, with the failed record as evidence |
| 5 | `BLOCKED` with an owner decision pending | `decide` | ask the owner the pending question (decision point) |
| 6 | Ready `TODO` (every `depends_on` `VERIFIED` or `DONE`, or also `CODE_COMPLETE` / `DEPLOYED` with `process.ready.after: code_complete`; `blocked_on` empty or naming only answered/dropped `OQ-NN`), by effective priority — a task inherits the highest priority of the open tasks waiting on it — then how many tasks it unblocks, then id | `start` | stage `analyze` — §3 |
| 7 | Unpushed commits and nothing else to do | `decide` | push is a decision point (§3, Push) |
| — | The pass took as many tasks as `process.batch` allows (only with `--pass`) | `stop` | end the pass: §3, Next |
| — | A task worked in its own worktree (`tw/<ID>`, or `task/<ID>` made by hand) is approved there | `merge` | `/teamwright:parallel merge <ID>` for `tw/`; otherwise merge the branch the reason names and remove that worktree |

A stage held back by its threshold (`process.stages.<stage>.min`, `max_wait_hours`) moves behind the work that is due; its candidates say `(held: …)`. When nothing else is due, it runs.

**In a parallel worktree** (this tree is on branch `tw/<ID>`, started by `/teamwright:parallel`, or `task/<ID>`) the router offers only that task and ends `idle` once it is `CODE_COMPLETE`: no push, no verification here — both follow the merge in the main tree.
| — | Nothing ready | `idle` | report, outcome `idle` |
| — | `TEAMWRIGHT_PAUSE` exists | `paused` | report, no work that leads to a push; outcome `idle` |

**Warnings.** Show them on the status screen. A warning on the task you are about to start ("mentions unresolved OQ-NN but blocked_on is empty"): read its Context and Acceptance; when they say the question must be answered first, set `blocked_on: OQ-NN` in the task record, commit (`chore(task): T-NNN blocked_on OQ-NN`), and re-run the router instead of starting it. When the task deliberately does not wait for the question, write the mention as `non-blocking: OQ-NN — <why>`; the router stops warning.

The helper exits non-zero or prints something unparseable → say so, show its output, and fall back to the readiness rule in `docs/process/lifecycle.md` §4 by reading the task files yourself; tell the owner the decision was derived by hand. An `action` not in the table → show it and ask.

## 2. One-screen status

Before acting, show at most ~15 lines:

```
Mode: gate-first | enforce        Pause: no | yes (TEAMWRIGHT_PAUSE)
Tree: clean | dirty (<n> files)   Unpushed: <n> commits (<tasks>)
Tasks: TODO n · ANALYSIS n · IN_PROGRESS n · NEEDS_REVIEW n · CODE_COMPLETE n · DEPLOYED n · BLOCKED n · VERIFY_FAIL n · DONE n
Active: <current-task or none>
Next: <action> <task> — <title>
Why: <reason>
Other options: <alternative 1>; <alternative 2>
Warnings: <router warnings, or none>   Context tool: <provider — connected | not connected, fallback>
```

Then proceed **without asking** unless the next step is a decision point (§5). `--status` → stop here.

## 3. Run the stage the router names

Spawn each role as a **fresh subagent by its role file name** (`problem-investigator`, `test-writer`, `developer` or `developer-<area>`, `technical-writer`, `code-reviewer`, `task-validator`), **in the foreground** (session rules above), passing the task id and only what the role needs, and `model` = the router's `model` when it is set (`process.models`). The spawn's short description names **only that task** (`T-NNN code-reviewer`): the journal takes the task from it, and the review gate checks that the reviewer was spawned for this task. Never run a role as a fork of yourself, and never let the implementing agent review. Every status change is its own commit: `chore(task): T-NNN FROM→TO`, staged by path, with a `Co-Authored-By:` trailer.

| `stage` | Do — read and follow its § Work (its Entry and end block are the flow's §1 and §7) |
|---|---|
| `analyze` | `${CLAUDE_PLUGIN_ROOT}/skills/analyze/SKILL.md` — `start` / `continue` (ANALYSIS) / `reanalyze` → IN_PROGRESS at `stage: red-tests` |
| `red-tests` | `${CLAUDE_PLUGIN_ROOT}/skills/red-tests/SKILL.md` — failing tests, bite check, catalog → `stage: implement` |
| `implement` | `${CLAUDE_PLUGIN_ROOT}/skills/implement/SKILL.md` — green, failure-branch bite, gate, docs → `NEEDS_REVIEW` |
| `review` | `${CLAUDE_PLUGIN_ROOT}/skills/review/SKILL.md` — fresh reviewer, verdict → status, follow-ups |
| `verify` | `${CLAUDE_PLUGIN_ROOT}/skills/verify/SKILL.md` — fresh validator, records → `DONE` / back / owner |

Take the stage's batch from the router (`batch`, or your own choice from `candidates` within `batch_cap` — `docs/process/stage-protocol.md` §2), one task after another. Then:

- **Push (DRAIN)** — the router's `decide` "unpushed commits": no commit message carries `[skip ci]` (`[ci skip]`, `[no ci]`): CI decides by the pushed tip, and the tip is a status commit, so the marker would leave the code under it — and the pull request opened from it — unchecked (pre-push warns). Every task in the unpushed tail is `CODE_COMPLETE` or later (or `tail_code: ratified`) → decision point "push now?". On "yes": `git push`; the pre-push hook re-checks; tasks that deploy → `DEPLOYED`. `TEAMWRIGHT_PAUSE` present → no push, say so. `deploys: false` → no push needed for verification. When the task reaches `CODE_COMPLETE`, delete a `wip/<ID>` branch it used: `git push origin --delete wip/<ID>`.
- **Next** — the stage reached a barrier (its batch is done, or a decision point). Then:
  - `process.autonomy.continue: true` and no stop condition → back to §1 (tasks this run started added to `--pass`). A push question that can wait is **not** asked now: the pass keeps going, and push is asked once when the pass ends, for every task it brought to `CODE_COMPLETE`. Verification of those tasks follows the push.
  - `continue: false` (the default) → §1 again only while the same task moves on (its next stage); stop at `CODE_COMPLETE`, as before, then §7.
  - The router says `stop` (pass cap used) or `idle` → ask the pending push, if any, then §7.

Records are written only by their owners and only with Edit/Write: analysis by the investigator, review records by the reviewer, verify records by the validator. You never edit an earlier round.

## 4. Resume after an interruption

`resume` means unfinished work in the tree: tracked changes, or a session that ended `interrupted`. A task left at a stage on a clean tree is **not** a resume: its `stage:` is recorded and committed, and the router routes it to that stage (`continue`). The router has already decided the stage from facts (the `stage:` field checked against the evidence: analysis complete, `## Tests` filled); start cold, from evidence, not memory:

1. Read the task record, `git status`, `git diff --stat`, `git log` since the last `chore(task): T-NNN` commit.
2. Finish the router's `stage` for that task (§3), keeping the changes that belong to it.
3. Uncommitted changes that do not belong to the task → do not touch them, do not stash or revert; tell the owner and stage only the task's paths.
4. Say in one line where you resume and why, then continue.

## 5. Decision points — the only times you ask

Ask the owner (AskUserQuestion when available, 2–4 options, the recommended one first) only for:

- which task, when the owner asked to choose or the router offers equal alternatives — and only with `process.autonomy.start: ask` (with `auto` the router's `start` has `ask_owner: false`: take it);
- large work → spec tool first;
- `ESCALATE`, or a recurrence exit (b) architecture review (`/arch-review`) or (c) process amendment;
- push (DRAIN);
- `NEEDS_OWNER` from the validator, or a `kind: manual` verification that needs a `verify_exception`;
- anything in `docs/process/sessions.md` §4 (product decision, secrets/auth/money/data deletion/migrations not stated in the task, a dangerous function);
- switching to `enforce` when `/teamwright:status` says the project is ready.

Record each answer in `docs/decisions.md` (proposed-by: agent / decided: owner). Everything else — status changes, spawning roles, running the gate, local commits — proceeds without asking.

## 6. Stop conditions

Stop at the next safe point (after the current commit, never mid-edit) when any of these holds:

- **Escalation** — a decision point the owner has not answered, a `BLOCKED` task with nothing else ready, two `REQUEST_CHANGES` records in a row on the task, an rca task that shows a recurrence itself.
- **Pause** — `TEAMWRIGHT_PAUSE` appears at the repository root: finish the current local commit, push nothing, stop.
- **Budget** — the router answers `stop` (the pass used its `process.batch` cap, or `--tasks`), or the session context is getting long (large diffs, many tool outputs): stop at the next barrier rather than continuing on a crowded context; the next `/teamwright:flow` resumes cleanly.
- **Gate infrastructure broken** — a command that worked before is now `not runnable` (image missing, toolchain gone): report it; fixing the config goes through `config.next.yml` + `apply --config` with the owner.
- **Idle** — the router returns `idle`.
- **Interrupted** — a tool or the runtime fails mid-step in a way you cannot recover from in this session (the owner interrupts, a role agent crashes without a result, the context limit is near mid-edit): commit nothing half-done, say exactly where the task stands, and end with `Outcome: interrupted`; the next `/teamwright:flow` resumes from evidence (§4).

Waiting is never a stop condition: a running role agent is waited for, not left behind (session rule 1).

## 7. End-of-session summary

**Every** turn that ends this skill's work ends with this block — after a barrier, at a decision point you just asked about, on idle, on pause, and when interrupted. No exceptions: a turn without it is journaled as `outcome: none` and the next session cannot tell a clean stop from a crash. Before writing it, check that no role agent is still running (session rule 1) and that every record a role wrote is committed (`git status`).

Done this session: <T-NNN FROM→TO, …>   Commits: <n> (pushed: <n>)
Stage: flow
Batch: <the tasks this run worked> - <one line: why these>
Records: <reviews/<n>.md verdict · verify/<n>.md result>
Stopped because: <budget | decision point: … | pause | escalation | idle | interrupted: …>
Waiting for the owner: <question, or none>
Next: <router's next action and task> — run /teamwright:flow to continue
Outcome: <barrier | idle | escalate | interrupted>

`Stage:` and `Batch:` are journaled with the outcome (`outcomes.jsonl`: `stage`, `batch`, `batch_reason`). Write the `Outcome:` line as the **last line of your message**, as plain text (not inside a code block), with exactly one of the four words: the Stop hook (`scripts/hooks/journal.sh`) reads it into `.teamwright/logs/outcomes.jsonl`, and `tw-next.py` routes the next session on it.

- `barrier` — the work reached a safe point: budget used, a decision point asked, pause, or one task blocked while other work could continue.
- `idle` — the router returned `idle` or `paused`.
- `escalate` — nothing at all can proceed without the owner.
- `interrupted` — stopped mid-step (§6); the next session resumes the task.
