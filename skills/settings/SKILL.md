---
name: settings
description: Show or change the project's process settings — the review blocking threshold, how many tasks a flow pass takes (per priority), autonomy (start a ready task without asking, continue after a barrier), batches and thresholds per stage, the model per stage, and who selects the tasks (the router script or the agent). The pipeline stays the same; only these parameters change. Changes go through config.next.yml and the installer, with the owner's approval, and are recorded in docs/decisions.md.
argument-hint: "[<key> <value>] — e.g. review.blocking medium, batch.max_tasks 3, stages.review.min 2, models.red-tests sonnet"
disable-model-invocation: true
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" plan *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-process.py" *) Bash(git status *) Bash(git log *)
---

# /teamwright:settings — tune the steps, keep the pipeline

Arguments: `$ARGUMENTS`. Without arguments: show the settings and offer changes.

The pipeline — statuses, roles, gates, records, "two send-backs → ESCALATE", DRAIN, acceptance — is the same in every project. These keys are parameters of its steps, a closed list (the installer refuses any other key):

| Key | Values | Default (key absent) | Recommended | What it changes |
|---|---|---|---|---|
| `review.blocking` | `low` · `medium` · `high` | `low` | `medium` | From which severity a review finding returns the task. Below it, findings are follow-ups (one task per sprint). Critical and the categories `secret-leak`, `security`, `weakened-test`, `done-not-working`, `recurrence` block always. The review gate checks that the verdict matches the findings table |
| `batch.max_tasks` | 1–5 | 1 | 3 | How many tasks one `/teamwright:flow` pass takes, one after another |
| `batch.by_priority.P0`…`P3` | 1–5 | P0 1, P1 1, P2 3, P3 3 | P0 1, P1 2, P2 3, P3 3 | Cap for a pass that holds a task of that priority; the lowest cap in the pass wins. The router checks it (`tw-next.py --pass`) |
| `batch.parallel` | 1–10 | 1 (off) | 1 | Tasks worked at the same time, each in its own worktree and session, when their seams do not overlap (`/teamwright:parallel`). Worth it when tasks are independent and each runs long; every extra session costs the owner's attention and the merges |
| `autonomy.start` | `ask` · `auto` | `ask` | `auto` | Start the router's ready task without asking which one |
| `autonomy.continue` | `true` · `false` | `false` | `true` | After a barrier, take the next task in the same pass instead of ending the session. Push stays the owner's decision: asked once at the end of the pass |
| `ready.after` | `verified` · `code_complete` | `verified` | `verified` | When a `depends_on` counts as finished: at `VERIFIED`/`DONE`, or already at `CODE_COMPLETE`/`DEPLOYED` — the dependent starts while the dependency's pipeline, deploy and verification run. A `VERIFY_FAIL` on the dependency can then reopen work already done on the dependent |
| `test_guard` | `block` · `warn` · `off` | `block` | `block` | The test guard: tests only through `scripts/tw-test`, gates through `scripts/tw-gate` — a direct test runner or gate script, and test output piped into `tail`/`grep`, are refused (`block`) or only warned about. Its own switch, not `mode`: it blocks in `gate-first` too |

| `stages.<stage>.batch` | 1–10 | 1 | 1 (review: up to 3 when reviews pile up) | `<stage>` = `analyze`, `red-tests`, `implement`, `review`, `verify`. How many tasks one stage session (`/teamwright:router`, a stage command) takes, **one after another in that session** — not at the same time: that is `batch.parallel` (separate worktrees and sessions). red-tests and implement still hold one task `IN_PROGRESS` per working tree. Larger batches save context rebuilds; each task still gets its own records |
| `stages.<stage>.min` | 1–10 | 1 | 1 | Tasks waiting at the stage before the router runs it while other work is due. P0/P1 tasks and "nothing else to do" run it at once. E.g. `review.min: 2` reviews two tasks in one session instead of one now and one later; the cost is a task that waits |
| `stages.<stage>.max_wait_hours` | 0–168 | 0 (off) | 0 | With `min` above 1: the stage runs anyway once its oldest waiting task is this old |
| `models.<stage>` | `opus` · `sonnet` · `haiku` · `fable` · `claude-…` | unset (the role files' `model:`) | analyze, implement, review, verify `opus`; red-tests `sonnet` | The model of the stage's role agents (the agent tool's `model` parameter) and of an autonomous job's session. A cheap model on review or on a risky seam is a false saving (`docs/process/sessions.md` §5) |
| `router.select` | `script` · `agent` | `script` | `script` | Who finds the work: the router script selects by status and counts, and lists the candidates with their facts — the session only picks the batch (few tokens, deterministic); `agent` — the session reads the task records itself (more tokens each session; for task records the script cannot read) |

Defaults are the behaviour before settings existed, so a plugin update changes nothing by itself — except `test_guard`, which blocks from 0.11.0 on.

## 1. Show

Read `.teamwright/config.yml` (missing → suggest `/teamwright:adopt` or `/teamwright:init`; stop). Effective values: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --json` → `settings` (`explicit` lists the keys set in the config; the rest are defaults). One table: key · value · set or default · recommended — the recommended column from `recommended` in the same JSON (`_config.PROCESS_RECOMMENDED`: review, batch, autonomy, ready, `models` per stage, `stages` thresholds), never from memory. Then offer changes for **every** key, not only those that differ from the recommendation — a key at its default can still be worth changing for this project (`batch.parallel`, `test_guard`, `router.select`, the stage batches). AskUserQuestion takes at most four questions per call, so ask in rounds:
   1. One question, multiSelect: which groups to change — *review and flow passes* (`review.blocking`, `batch.max_tasks`, `batch.by_priority`), *autonomy* (`autonomy.start`, `autonomy.continue`, `ready.after`), *stages* (`stages.<stage>.batch`, `.min`, `.max_wait_hours`), *models and selection* (`models.<stage>`, `router.select`), *parallel work and the test guard* (`batch.parallel`, `test_guard`). Mark the groups holding a key whose current value differs from the recommendation. None chosen → stop, nothing changes.
   2. For each chosen group, one AskUserQuestion call with up to four questions, one per key (a group with more keys → a second call): current value, the recommended value first, one line on the consequence, "keep" changes nothing. Free text ("Other") is a value too.
   3. `models.<stage>` is one question, not five: options as sets — the recommendation (`analyze`, `implement`, `review`, `verify` opus; `red-tests` sonnet), all `opus`, unset (the role files' `model:`); a per-stage value through "Other" (`review: opus, red-tests: haiku`).
   4. `stages.<stage>`: ask first which stages to change (multiSelect), then batch / min / max_wait_hours per chosen stage.

Add what the data says, one line each, from `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-process.py" --json`: share of review send-backs, findings by severity, the categories that returned tasks, open follow-ups, when the settings last changed. Example: "46 % of review rounds were send-backs; 127 of 192 findings were Low — `review.blocking: medium` would have kept them as follow-ups". Facts only; the owner decides.

## 2. Change — the owner's decision

1. From the arguments, or ask (AskUserQuestion, up to four keys at once, the recommended value first, one line on its consequence). Name the trade-off plainly when there is one:
   - `review.blocking: high` → Medium findings, docs drift among them, stop returning tasks: the follow-up task grows and docs drift until it is done.
   - `batch.max_tasks` above 1 with `autonomy.continue: true` → longer sessions; the flow still stops at a barrier when the context gets long.
   - `stages.<stage>.min` above 1 → that stage waits while other work exists: tasks sit there longer, sessions are fewer and fuller. Pair it with `max_wait_hours`.
   - `models.<stage>` cheaper than `opus` on analyze, implement or review → more send-backs; measure with `/teamwright:improve` before keeping it.
2. **Agents cannot edit `.teamwright/config.yml`** (state guard) — that is what keeps an agent from loosening its own threshold. Copy it to `.teamwright/config.next.yml` with the Write tool and change only the `process:` keys:
   ```yaml
   process:
     review:
       blocking: medium
     batch:
       max_tasks: 3
       by_priority:
         P1: 2
     autonomy:
       start: auto
       continue: true
   ```
3. `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" plan --config .teamwright/config.next.yml --json` — validation errors, and the re-rendered lines in `AGENTS.md` and `code-reviewer.md`. Show them.
4. On "yes": `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" apply --config .teamwright/config.next.yml` (writes `config.yml`, deletes the proposal, re-renders). `kept-local` files (edited by hand) do not get the new values. Then `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-process.py" --json` and read `render_drift`: every file whose settings line still carries the old value. For each, offer to fix that one line (the owner's other edits stay) — a role that keeps the old threshold sends tasks back under it; the router warns until it is fixed.
5. Add a row to `docs/decisions.md`: the keys, old → new, why (the owner's words or the data from step 1), proposed-by: agent / decided: owner. Commit on "yes": `chore(process): <keys>`.
6. Say how to see the effect: `/teamwright:improve` compares before and after this commit.

Report: `Settings: <key old → new, …> · rendered into: <files> · decision #<n>`.
