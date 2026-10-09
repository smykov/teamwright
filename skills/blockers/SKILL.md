---
name: blockers
description: What the team is waiting on a person for — open questions, escalated reviews, acceptance that needs the owner, BLOCKED and held tasks, stale blocked_on, uncommitted or unpushed work — each with its class (credentials, infrastructure, external, device, decision) and the tasks it unblocks, highest impact first. Then, on request, walks the owner through the open questions and decisions one at a time and records each answer (decisions.md, open-questions.md, blocked_on, BLOCKED → TODO), so the flow can pick the tasks up again. Use when the owner asks what is stuck, what is blocked, what needs their decision or answer.
argument-hint: "[--answer] [OQ-NN | T-NNN ...]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-blockers.py" *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-next.py" *) Bash(git status *) Bash(git log *) Bash(git diff *) Bash(scripts/tw-req *)
---

# /teamwright:blockers — what waits for you, and your answers

Arguments: `$ARGUMENTS`. Without `--answer` the command is read-only: the list, then one question — answer now? `--answer` goes straight to answering; ids narrow it to those items.

Talk to the owner in the language of `language` in `.teamwright/config.yml` (or the language they write in). Every item and number comes from the script — never from the session's memory.

## 1. Data

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-blockers.py" --json
```

- `installed: false` → suggest `/teamwright:adopt` or `/teamwright:init` and stop.
- `items` — already ordered by impact (highest priority they unblock, then how many tasks). Each: `kind` (question, escalated, acceptance, blocked, held, tree), `id`, `cls` (credentials, infrastructure, external, device, decision, other), `need`, `tasks` (held directly), `unblocks` (those plus everything depending on them), `top_priority`, `evidence` (records to read), and for a question `options`, `asked`, `mentioned_by`, `in_table`.
- `stale` — `blocked_on` names a question that is already answered: the task waits for nothing but a field edit.
- `stuck_tasks` of `open_tasks`, `by_class`, `paused`.

## 2. The list

1. **One line** — "N items hold M of K open tasks" (+ "team paused" when `paused`).
2. **Decisions and questions** (`cls: decision`) — table "Item | What is needed | Unblocks | Asked". For a question, the question and its options; for `escalated`, read the review record in `evidence` and say in one sentence what the reviewer asks the owner to decide; for `acceptance`, the validator's ask from its record.
3. **Actions outside the repository** — `credentials`, `infrastructure`, `external`, `device`, `other`, grouped by class: what to do by hand and where (a key in the provider's console, a DNS record, a check on a real phone). The team cannot do these; after the owner does one, the next `/teamwright:flow` continues the task (for `acceptance`: a new validation round).
4. **Clean-up** — `stale` items (clear `blocked_on`), a question `mentioned_by` tasks whose `blocked_on` is empty (does the task wait for it? — the router's warning), a question missing from `docs/open-questions.md` (`in_table: false`: add the row), `tree` items.

Nothing waits → say so in one line and stop. Then ask once (AskUserQuestion): **answer the open questions and decisions now?** — "yes, in order of impact" (recommended) / "only some" / "not now".

## 3. Answering (`--answer`, or "yes")

Only items the owner can settle here: `question`, `escalated`, `acceptance` whose ask is a decision, `blocked` / `held` whose reason is a decision, and `stale`. One item at a time, in the list's order (or the ids given).

For each:

1. **Context first** — read what the item points to: the question's row, the tasks it holds (`Context`, `Acceptance`, `analysis`), the spec sections and requirements they name (`scripts/tw-req <ID>`), the review or validation record. One short paragraph: what is asked, why it matters now, what it unblocks.
2. **Ask** — AskUserQuestion with the row's options (or options drawn from the records when the row has none), the recommended one first with its consequence in one line; the owner can always write their own answer. Add "drop the question" when the records show it may no longer matter, and "skip for now". Never answer for the owner, and never pick a default because the owner is away.
3. **Record the answer** (Edit, never the shell):
   - `docs/decisions.md` — a new row at the end of the table (append-only): date, task, the question (`OQ-NN: …`), `Was` = the options offered, **the decision**, why in the owner's words, `Proposed by` (agent / owner), `Decided by: owner`.
   - `docs/open-questions.md` — the row's Status: `answered → decisions.md #N` or `dropped (why)`.
   - Every task whose `blocked_on` now names only resolved questions → `blocked_on: ""`; free-text `blocked_on` the answer settles → `""`.
   - A `BLOCKED` task the answer settles → `BLOCKED → TODO` (lifecycle: "decision made"); it keeps its analysis. A task the answer changes (scope, acceptance) — update its `Acceptance` / `Context` in the same edit, and say what changed.
   - `escalated` → the owner's decision goes into `docs/decisions.md`; then the task follows it: `BLOCKED → TODO` with the decision in its `Context`, or `DEFERRED` / a new task when the owner says so. The review records stay as they are.
   - `acceptance` (NEEDS_OWNER) → write what the owner did or decided into the task's `## Validation` notes; the next flow spawns `task-validator` for a new round.
   - `skip` → nothing changes; `stale` → only the field edit.
4. Next item. After each answer say in one line what it unblocked.

At the end: one list of every file changed, then **commit once on "yes"**, staged by path — `docs: answers to OQ-01, OQ-03` for the documents, plus one `chore(task): T-NNN BLOCKED→TODO` line per status change in the body (the commit-msg convention). Do not push. Then run `tw-next.py --json` and say what `/teamwright:flow` will do next.

## Rules

- Read-only until the owner says "yes" to answering; nothing is recorded without their answer.
- Status changes only `BLOCKED → TODO` here; everything else is the flow's.
- An answer that contradicts `docs/requirements.md` or an earlier decision → say which, and ask whether it replaces it (then the new row's `Was` references the old #; old rows are never edited) — never record two decisions that disagree.
- Questions that arise while answering are new `OQ-NN` rows at the end of the table, not inline notes.
