---
name: requirements
description: Build or rebuild the product's requirements document (docs/requirements.md) before any spec or task — take the owner's existing brief, PRD or terms of reference as the base, or interview the owner when there is none; then a fresh requirements-reviewer roasts it, its findings become questions, and the loop repeats until the document is READY and the owner approves it. Called first by /teamwright:init, by /teamwright:adopt when the requirements are empty, or directly to rework them.
argument-hint: "[path to an existing brief | short product idea]"
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" inventory *) Bash(git status *) Bash(git log *) Bash(git add *) Bash(git commit *) Read Write Edit Agent AskUserQuestion
---

# /teamwright:requirements — the requirements document, before the spec

Input from the owner: `$ARGUMENTS` (a path to a brief, or a product idea, or nothing).

The spec tool (Spec Kit, OpenSpec or none) works one feature at a time; this step works on the whole product and runs before it. Its output is `docs/requirements.md` in the template's ten sections, approved by the owner, plus `docs/open-questions.md`. Structure and practices: `${CLAUDE_PLUGIN_ROOT}/template/docs/requirements.md` (the comments in each section say how to fill it).

## Rules

- **English in the repository.** Talk to the owner in their language; write the document in English. A source document in another language is translated into the structure; the original stays where it is (or is copied to `docs/sources/` on "yes") and is named in the document header.
- **Only what the owner said or approved.** Your guess is a *working assumption* in section 10, never a requirement. An unknown is an entry in `docs/open-questions.md` (`OQ-NN`), never a silent default.
- **Questions in rounds**: up to 5 questions per round, grouped by topic (the interview table below); fewer is fine — with a source document, gaps from neighbouring sections go into one round. Use AskUserQuestion when the answers can be listed (2–4 options, the recommended one first); otherwise a short numbered list. "I don't know" → offer a sensible default, record it as a working assumption, move on.
- **Never re-ask** what a source document already answers. Ask about gaps and contradictions only.
- The document author (you) never roasts it: the roast is a fresh `requirements-reviewer` subagent. Spawn it and **wait for its record** before doing anything else (the runtime may run it in the background — do not end your turn while it runs).
- **Commits**: ask once, at the start, whether to commit each step's result (draft, roast round, approval) as it lands; a "yes" covers the whole run, a "no" means nothing is committed until the end.
- **One exchange per round of decisions**: the section 9 block, the High questions and the Medium/Low batch of a roast round go to the owner together. In the interview, a table of proposals the owner confirms or corrects counts as one question.
- Spend the owner's attention carefully: a proposal with a recommended answer the owner can accept in one word beats an open question; the technical decisions come as one block to confirm.
- No secrets, real customer data or credentials in the document.

## 0. Before teamwright is installed

`/teamwright:init` runs this step before the templates are installed. When `docs/requirements.md`, `docs/open-questions.md` or `docs/decisions.md` do not exist, create them from `${CLAUDE_PLUGIN_ROOT}/template/docs/` (install keeps them as the project's documents); remove the template's example rows (`OQ-01 <question>`, `#1 <date>`) so their ids are free. When the `requirements-reviewer` agent type is not installed, spawn a general-purpose subagent whose prompt is the body of `${CLAUDE_PLUGIN_ROOT}/template/.claude/agents/requirements-reviewer.md` plus the inputs, and tell it the kit's process docs are in `${CLAUDE_PLUGIN_ROOT}/docs/process/`.

## 1. Find what already exists

1. `git status`; `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" inventory --json` → `kind`, `requirement_docs`, `unfilled_docs`.
2. Candidates for the base: the path in `$ARGUMENTS`, `docs/requirements.md` if it is not the template, every file in `requirement_docs` (brief, PRD, ТЗ, spec, README). Read each one (md, txt directly; docx, pdf with the available reader — if none, ask the owner to export to text or markdown).
3. Tell the owner in a short table what you found and how complete it looks against the ten sections: **full**, **partial** or **none**. Nothing found → skip the table and go to the interview. Otherwise, in the same question: which document is the base when there are several, and — only for a source outside the repository or in a binary format — whether to copy it to `docs/sources/`.

## 2. Build the draft

**A source exists** → map it into the ten sections. The header's `Source:` line names the documents; statements keep a short pointer to their place in the source (`(brief §3)`, `(brief, item 4)`) — the pointers stay after approval, they are the trace back to the owner's words. Then interview only the gaps (empty sections, Must items without acceptance, requirements that are not testable).

**Nothing exists** → interview in this order; each topic is one round:

| Round | Section | Practice | Ask |
|---|---|---|---|
| 1 | 1. Problem and users | Jobs To Be Done | who the users are; "When …, I want …, so I can …"; what they do today without the product |
| 2 | 2. First release | measurable goal | the one flow that must work end to end; how we know the release succeeded (number, date) |
| 3 | 3. Scope | User Story Mapping, MoSCoW, no-gos | the user's activities left to right; the thinnest release-1 path through all of them; what is explicitly out |
| 4 | 4. Functional | EARS, Example Mapping | per release-1 step: "When … the system shall …"; a concrete example and a failing one ("If … then …") |
| 5 | 5. Non-functional | ISO/IEC 25010 checklist | only the characteristics that apply, each with a number |
| 6 | 6–8. Constraints, glossary, integrations | ubiquitous language | platforms, store and legal rules, date, budget; **what may be installed on the dev machine, in CI and on the server** (packages, containers, MCP servers, downloads); the domain terms; external services and accounts |
| 7 | 10. Assumptions and risks | pre-mortem | "three months after release 1 it failed — why?" |

Section 9 (technical decisions) is not asked: it is derived in step 3 from what the owner said.

Write the draft as `Version: 1 · Status: draft`. Commit on "yes": `docs(requirements): draft v1`.

## 3. Roast

Spawn a fresh **`requirements-reviewer`** subagent (§0 when it is not installed) and wait for its record. Give it: the round number, the paths of the draft, the open questions and the source documents, the owner's install policy (section 6) and what the host already has (`command -v` for the likely toolchains), so its stack proposal can actually run here. It writes `docs/requirements.reviews/<n>.md` (findings, a pre-mortem, questions for the owner, verdict `READY` / `NOT_READY`). Never write or edit that record yourself.

The reviewer also proposes **section 9** from round 1: stack and areas, what "deployed" means, where verification runs — each driven by requirement ids, with one alternative. Show them to the owner as one block to confirm or change; the confirmed choices go into section 9. An empty section 9 before that is expected and does not block the verdict.

Then:

1. Show the owner the Blocker and High findings as questions (rounds of up to four).
2. Medium and Low go as **one** question: the list with each suggested change, and the options "accept all", "accept all except <numbers>", "go through them". Declined items are dropped; items the owner wants to think about go to `docs/open-questions.md`.
3. Write the answers into the document (version +1), move resolved open questions to `answered`. Update the header: `Version: <N>` and `Roast: round <n> <verdict> (on v<N-1>)`.
4. Commit the draft together with the roast record on "yes": `docs(requirements): v<N> after roast round <n>`.
5. **Another round only when it can change the verdict**: the round was `NOT_READY`, or the owner accepted a finding the reviewer tagged `Changes build: yes`. Accepted findings tagged `no` (wording, an example, a number, a validation detail) go straight in. A new round is a fresh reviewer that checks the changed rows and any finding still open, not the whole document again.
6. At most **two** rounds without a Blocker — this overrides step 5. After the second round, every remaining High (new or old) is asked once; the owner's answer closes it (the change goes in) or turns it into an open question. The header then reads `Roast: round 2 NOT_READY (on v<N-1>), remaining High closed by the owner`. With a Blocker, stop after three `NOT_READY` rounds and ask the owner how to proceed.
7. Skip a round when every `NOT_READY` cause was accepted exactly as the reviewer suggested and tagged `Changes build: no`.
8. A reviewer that stopped without handing back (interrupted, crashed) may leave a record behind: delete that record and run the round again with a fresh reviewer — it is not an earlier round.

## 4. Approval

When no further round is needed (step 5), show the owner the document's outline: the release-1 flow, Must requirements with their failure branches, section 9, open questions. Ask: **"Approve the requirements as version N?"** On "yes": header `Status: approved · Approved by the owner: <date>`, commit `docs(requirements): approved v<N>` (it may be the same commit as step 4 of the last round). Later changes are a new version with a line in `docs/decisions.md`.

## Report

```
Requirements: docs/requirements.md v<N> — <approved | draft>
Base: <source documents | interview>
Release 1: <the flow, one line> · Must: <n> FR, <n> NFR · failure branches: <n>/<n Must>
Roast: <rounds> round(s), last <READY|NOT_READY> — docs/requirements.reviews/<n>.md
Technical decisions: <stack, deployed means, verification> | open
Open questions: <ids> | none
```

### Next steps (mandatory)

- Called from `/teamwright:init` → return to it (stack, skeleton, spec).
- Called from `/teamwright:adopt` → return to it (tools, sprint).
- Called directly → "Derive specs and tasks from the approved requirements with the spec tool?" — on "yes", run the spec step of `/teamwright:init` (§ First specs) for the features that are new or changed.
