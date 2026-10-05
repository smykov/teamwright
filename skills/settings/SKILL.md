---
name: settings
description: Show or change the project's process settings — the review blocking threshold, how many tasks a flow pass takes (per priority), and autonomy (start a ready task without asking, continue after a barrier). The pipeline stays the same; only these parameters change. Changes go through config.next.yml and the installer, with the owner's approval, and are recorded in docs/decisions.md.
argument-hint: "[<key> <value>] — e.g. review.blocking medium, batch.max_tasks 3, autonomy.start auto"
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
| `batch.parallel` | 1–4 | 1 (off) | 1 | Tasks worked at the same time, each in its own worktree and session, when their seams do not overlap (`/teamwright:parallel`). Worth it when tasks are independent and each runs long; every extra session costs the owner's attention and the merges |
| `autonomy.start` | `ask` · `auto` | `ask` | `auto` | Start the router's ready task without asking which one |
| `autonomy.continue` | `true` · `false` | `false` | `true` | After a barrier, take the next task in the same pass instead of ending the session. Push stays the owner's decision: asked once at the end of the pass |

Defaults are the behaviour before settings existed, so a plugin update changes nothing by itself.

## 1. Show

Read `.teamwright/config.yml` (missing → suggest `/teamwright:adopt` or `/teamwright:init`; stop). Effective values: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" --json` → `settings` (`explicit` lists the keys set in the config; the rest are defaults). One table: key · value · set or default · recommended.

Add what the data says, one line each, from `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-process.py" --json`: share of review send-backs, findings by severity, the categories that returned tasks, open follow-ups, when the settings last changed. Example: "46 % of review rounds were send-backs; 127 of 192 findings were Low — `review.blocking: medium` would have kept them as follow-ups". Facts only; the owner decides.

## 2. Change — the owner's decision

1. From the arguments, or ask (AskUserQuestion, up to four keys at once, the recommended value first, one line on its consequence). Name the trade-off plainly when there is one:
   - `review.blocking: high` → Medium findings, docs drift among them, stop returning tasks: the follow-up task grows and docs drift until it is done.
   - `batch.max_tasks` above 1 with `autonomy.continue: true` → longer sessions; the flow still stops at a barrier when the context gets long.
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
4. On "yes": `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" apply --config .teamwright/config.next.yml` (writes `config.yml`, deletes the proposal, re-renders). `kept-local` files (edited by hand) do not get the new values — say which.
5. Add a row to `docs/decisions.md`: the keys, old → new, why (the owner's words or the data from step 1), proposed-by: agent / decided: owner. Commit on "yes": `chore(process): <keys>`.
6. Say how to see the effect: `/teamwright:improve` compares before and after this commit.

Report: `Settings: <key old → new, …> · rendered into: <files> · decision #<n>`.
