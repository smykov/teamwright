# Threat model

What teamwright protects, from whom, what actually stops each threat, and what does not. It covers the kit and the two ways it runs: an interactive flow and an autonomous chain on GitHub Actions. It does not cover the product a project builds with the kit.

**The short version.** The hooks are guardrails for a cooperative agent, not a sandbox ([SECURITY.md](../../SECURITY.md#scope)). They keep an agent from skipping process steps. They do not contain an agent that follows injected instructions: such an agent has the rights of the process it runs in, including Bash. In the autonomous chain the real boundaries are the runner's isolation, the token's scope and branch protection on the repository, and the kit configures none of these.

`tests/test-threat-model.sh` checks that every file, code symbol and test named in the tables exists, and that no row is `mitigated` without a test. It does not check that a control is sufficient.

Method: the four questions of the OWASP Threat Modeling Cheat Sheet (what are we building, what can go wrong, what do we do about it, did we do a good job), STRIDE on each trust boundary, two attack trees. OWASP lists were used afterwards as a checklist only.

## What are we protecting

| Asset | Why it matters |
|---|---|
| Secrets on the machine and in the job | Must be rotated once leaked; the kit's own scan sees only what is committed |
| The main branch | What ships; everything else exists to protect it |
| Task and review records, stamps, ledgers | The evidence the gates decide on; a forged record is a skipped review |
| Journals | The source of the metrics and of "the reviewer was spawned" |
| The model key and its budget | Spent by every job, with no limit of its own in the kit |
| The runner machine | Keeps workspaces between jobs, may hold other credentials |

## Actors

| Actor | Assumed intent and rights |
|---|---|
| Cooperative agent | Takes shortcuts under pressure. The case the gates are built for |
| Mistaken agent | Copies a token into a file, breaks a record. No intent, full tool rights |
| Author of a foreign Issue or PR | Controls text a model may read. No repository rights assumed |
| Malicious dependency | Runs as code during tests and gates, with the rights of whoever runs them |
| MCP server | Runs outside any sandbox; its output is model input. Anthropic does not audit servers |
| File contents | README, test output, vendored docs: anything the model reads can carry instructions |
| Compromised Action | Runs in the job with the job's token and environment |
| Human owner | Trusted, but overrides, approves many decisions, and may approve without reading |

## Data flows and trust boundaries

| Boundary | What crosses it |
|---|---|
| B1 | Outside text to the model: Issues, PRs, records, requirements, files, MCP output |
| B2 | Model to tools: Bash, Edit, Write, MCP. The hooks sit here |
| B3 | Agent to process evidence: records, stamps, ledgers, journals |
| B4 | Repository content to execution: config commands, tests, hooks, settings |
| B5 | Local to remote: push, merge, main |
| B6 | Third-party code to the machine: Actions, the plugin, dependencies, MCP servers |
| B7 | One job to the next: cache, workspace, the `wip/` branch |

**Interactive flow.** A person watches, and Claude Code asks for what is not pre-approved.

```text
owner --> Claude Code session --B2--> PreToolUse hooks --> tools --> working tree
              ^ B1                         |                  |
   files, records, MCP output     ledgers, journal (B3)   git hooks --B5--> remote
```

Skills pre-approve some commands while they run ([SECURITY.md](../../SECURITY.md#what-runs-without-a-prompt)), so "a person watches" is not "a person approves each call".

**Autonomous chain.** Nobody watches. The sketch is in [usage.md](../usage.md#autonomous-runs-one-stage-per-job); the real workflow lives in the project and may differ. A headless session shows neither the folder trust dialog nor the `.mcp.json` confirmation (Claude Code documentation, not tested here).

```text
workflow_dispatch --> job on a self-hosted runner (model key, repository token)
   checkout (B6) --> router --> stage session --B2--> hooks --> Bash, Edit, Write
                                  ^ B1                              |
              records, requirements, Issues, MCP output     commit on wip/
   cache of .teamwright/logs and the workspace (B7) <---------------+--B5--> push wip/, next job
```

The kit's Issue queue is wired by the project's workflow, so which text reaches the model and who can start a chain is the project's decision.

## Threats

Status: **mitigated** — the control works as far as we know, and a test checks it; **partial** — it stops common forms and not all; **accepted** — known and left that way on purpose; **open** — no working control, or a defect not yet fixed.

| ID | Threat | Boundary | STRIDE | Control in code | How it is checked | Status | Residual risk |
|---|---|---|---|---|---|---|---|
| TM-01 | Instructions in an Issue or a record steer an autonomous session | B1 | S, E | Router prompt carries no task text: `scripts/tw-next.py::def headless_for`. The session still reads the records. Warning: `docs/usage.md::a prompt injection in them runs with the job's rights` | `tests/test-usage-example.sh::prompt is the stage command`; no test of injection itself | open | Full rights of the job. No filter and no attack scenarios exist |
| TM-02 | Instructions in files or test output steer any session | B1 | S, E | None. In the interactive flow only permission prompts, where not pre-approved | no test | open | As TM-01, milder when a person is watching |
| TM-03 | Model key or repository token read and sent out from the job | B1, B2 | I | Advice only: `SECURITY.md::Keep the runner isolated`. No egress limit, no sandbox configured | no test | open | Assume readable by Bash and that the network is open; how the Action scrubs the environment was not checked |
| TM-04 | A secret gets committed | B5 | I | Forbidden files and a scan of added lines: `template/scripts/hooks/pre-commit::scan_diff` | `tests/test-pre-commit.sh::finding is reported with file:line`; `tests/test-installer.sh::untracked secret: scan exits 1` | partial | Regexes miss formats; anyone adding `teamwright:allow-secret` on the line or `--no-verify` passes |
| TM-05 | A secret lands in the journal | B3 | I | Detail is reduced to two words: `template/scripts/hooks/journal.sh::def shell_detail`. The second word is not filtered, so a password in a URL or a `-p` flag is stored. See Open gaps | `tests/test-journal.sh::Bash detail is program + subcommand only` covers `VAR=` and `cd` only | open | Defect. Journals are local, but the sketch caches them between jobs |
| TM-06 | An agent other than the reviewer writes an approval through Edit or Write | B3 | S | `template/scripts/hooks/review-gate.sh::only a %s agent writes review records` | `tests/test-review-gate.sh::developer subagent cannot write the review`; `tests/test-review-gate.sh::an implementing agent id stays denied even with reviewer type` | mitigated | Only for these tools, see TM-07 and TM-08 |
| TM-07 | A record, stamp or ledger is written by a script | B3 | T, S | Shell parsing: `template/scripts/hooks/_hookio.py::def shell_writes_records`, `template/scripts/hooks/_hookio.py::def runs_hook_script`; stamp versus ledger in pre-commit | `tests/test-review-gate.sh::no shell write of a stamp`; `tests/test-review-gate.sh::a stamp made by a script does not count where the task's ledger exists` | partial | Text parsing; a script file or a built path is not seen. Stamps are not signed, and a fresh checkout (every CI job) has no ledger to compare with |
| TM-08 | A committed `reviewer: human:<name>` record stands in for a review | B3 | S | Refused from Edit and Write: `tests/test-review-gate.sh::an agent cannot write a human review marker`. Accepted when no ledger entry exists | `tests/test-review-gate.sh::review committed by a person (reviewer: human:<name>) is accepted` | partial | Written by a script on a checkout without a ledger, it passes. Only review of the commit catches it |
| TM-09 | An agent definition is named `code-reviewer` | B4 | S | None; identity is the runtime's `agent_type`: `template/scripts/hooks/_hookio.py::def actor` | no test | accepted | Listed in SECURITY.md. Review `.claude/agents/` like code |
| TM-10 | Gates are removed by editing `.claude/settings.json` or `scripts/hooks/*` | B4 | T, E | None: the state guard covers neither. See Open gaps | no test; probed with hook input, all allowed | open | Defect. A chain's next job also runs the hooks from the `wip/` branch |
| TM-11 | The gate mode is lowered | B4 | T, E | `template/scripts/hooks/_hookio.py::def guard_state`; `scripts/tw-install.py::refusing enforce -> gate-first` | `tests/test-state-guard.sh::main session Write of config.yml denied`; `tests/test-state-guard.sh::python rewrite of config.yml denied`; `tests/test-installer.sh::proposal lowering the mode refused` | partial | A script file or built path slips through. `TEAMWRIGHT_GATE_MODE` from the environment wins over the config, and `env` in `settings.json` may set it (not tested), see TM-10 |
| TM-12 | Git hooks are switched off or skipped | B5 | T, E | Reported at session start only: `template/scripts/hooks/session-check.sh::git hooks are off on this clone` | `tests/test-session-check.sh::fresh clone without core.hooksPath: install-hooks hint` | accepted | `--no-verify` is listed in SECURITY.md. `git config core.hooksPath` is not refused. The autonomous sketch has no step that enables hooks, see Open gaps |
| TM-13 | An agent uses the human push override or removes the pause file | B5 | E, T | The override is an environment variable: `template/scripts/hooks/pre-push::TEAMWRIGHT_ALLOW_PUSH`. The state guard refuses two such variables, not this one. See Open gaps | `tests/test-pre-push.sh::human override pushes`; `tests/test-pre-push.sh::TEAMWRIGHT_PAUSE blocks every push`; refusal has no test, probed: allowed | open | Defect. DRAIN and the pause hold only against an agent that does not try |
| TM-14 | Unapproved code leaves under DRAIN's attribution rules | B5 | T | `template/scripts/hooks/pre-push::ATTRIBUTION` | `tests/test-pre-push.sh::commits without a known task id are not attributed`; `tests/test-pre-push.sh::code of a TODO task blocks the push` | accepted | A code commit naming no task, and commits to `AGENTS.md` or `CLAUDE.md` (agent instructions), pass by design |
| TM-15 | Owner-only exits are written by the agent | B3 | E, R | `tail_code: ratified` and `review: skipped:trivial` are plain record fields: `template/scripts/hooks/pre-push::tail_code: ratified`, `template/scripts/hooks/review-gate.sh::skipped:trivial` | `tests/test-pre-push.sh::tail_code: ratified lets it through`; refusal has no test | open | Visible in history and to the validator; nothing proves a person wrote it |
| TM-16 | The job pushes to main directly | B5 | E | Sketch pushes to `wip/` only: `docs/usage.md::leave the push to the main branch to a person`. Nothing enforces it; the token has `contents: write` | no test | open | Without branch protection on the repository, main is writable from the job |
| TM-17 | Headless parallel sessions run forbidden commands | B2 | E | `scripts/tw-parallel.py::DEFAULT_ARGS` disallows push, merge and `gh` by command text | no test of the flags; `tests/test-tw-parallel.sh::each stage is a claude -p session with the router's prompt` | partial | A wrapper script or another form of the command is not matched |
| TM-18 | Destructive commands in another form | B2 | T, D | Deny list by text: `template/.claude/settings.json::Bash(git push --force *)` | `tests/test-installer.sh::settings.json has gates and deny list` checks presence, not effect | accepted | Listed in SECURITY.md: `sh -c` and scripts are not matched |
| TM-19 | Project config carries a command that runs for everyone | B4 | T, E | `config.yml` is guarded (TM-11). `scripts/tw-progress.py::extra_command` reads `progress.json`, which is not | `tests/test-state-guard.sh::tee into config.yml denied`; none for `progress.json` | partial | SECURITY.md says to review these files like code; in a chain nobody does before the next job |
| TM-20 | A malicious dependency runs during tests or gates | B6 | E, I | Optional container: `template/scripts/tw-run::runner: host` or docker, which runs with the repository mounted, and no network limit is set | `tests/test-tw-run.sh::docker without image exits 2` tests wiring, not isolation | open | On `host` it has the user's rights. The kit does no dependency scanning for projects |
| TM-21 | An MCP server is added or swapped | B6 | S, E | Installer asks at install time and merges: `tests/test-installer.sh::.mcp.json merged, existing entries kept as-is`. `.mcp.json` is not guarded afterwards; headless shows no confirmation | no test of the headless path; probed: a write is allowed | open | A changed server may start in the next job without any question |
| TM-22 | A compromised Action runs in the job | B6 | T, I | Pins by SHA in the sketch and in the kit's CI; checksum for gitleaks: `.github/workflows/ci.yml::GITLEAKS_SHA256` | no test; check with `grep -n "uses:" .github/workflows/ci.yml` | partial | Pinned code can be bad too. A project's workflow is its own |
| TM-23 | A bad kit release reaches projects | B6 | T | Plan before apply: `scripts/tw-install.py::def plan`; version compared at session start. Tags are not signed, and the `next` channel has no version | `tests/test-tw-update.sh`; `tests/test-release-check.sh` | partial | Hooks run on every tool call, so a bad release has wide reach. Owner reads the plan or does not |
| TM-24 | Evidence is forged through the cache or the workspace between jobs | B7 | T | Advice only. `docs/usage.md::restore-keys: teamwright-state-` carries `.teamwright/logs`, which holds the journal and the gate cache: `template/scripts/tw-gate::LOGROOT=`. `clean: false` keeps files | `tests/test-usage-example.sh::the journal is kept between jobs` checks that it is cached, not that it is intact | open | A script in one job can leave a journal line or a cached gate PASS for the next |
| TM-25 | Spending runs away | B7 | D | Job timeout, one stage at a time, and a chain stops when a stage makes no commit: `docs/usage.md::the stage made no commit` | `tests/test-usage-example.sh::the dispatch step stops the chain when the stage made no commit` | partial | A stage that keeps committing keeps going. No budget for a sprint; the only hard cap is a limit on the API key, outside the kit |
| TM-26 | Whoever can label an Issue starts spending, and its title reaches the owner's session | B1, B5 | E, S | `scripts/tw-sprint.py::--start`; read-only listing: `scripts/tw-github.py::number,title,labels` | `tests/test-tw-sprint.sh::no label without --start` covers the kit's path only | partial | Labelling by hand starts the queue. Titles are model input for blockers and progress |
| TM-27 | Nobody can show who did what afterwards | B3 | R | Journal and ledgers refuse tool writes: `tests/test-state-guard.sh::Write of the journal denied`. Local, unsigned; trailers are written by the agent | `tests/test-journal.sh::no command arguments or secrets in the journal` tests privacy only | accepted | A forensic record needs logs off the machine, which the kit does not ship |
| TM-28 | A crash in a hook lets the call through | B2 | D, E | By rule: `CONTRIBUTING.md::Hooks fail open on internal errors`, so a broken hook does not stop work | no test as a security property | accepted | No `python3` or a hook error means no gate, silently |
| TM-29 | Project data leaks through `/teamwright:feedback` | B5 | I | Instructions in `skills/feedback/SKILL.md`; a person reads before sending. Kit's own CI: `.github/workflows/ci.yml::PRIVATE_NAMES_RE` | no test of the skill | accepted | Anonymisation is done by a model and checked by a person |
| TM-30 | The installer overwrites or writes outside the project | B4 | T | Keeps files it did not write; area paths stay inside | `tests/test-installer.sh::own CLAUDE.md untouched`; `tests/test-installer.sh::workdir must stay inside` | mitigated | Only for the cases those tests cover |

## Attack trees

Goals and paths, not steps. Each leaf names its row.

**Steal a secret**

- Get text in front of the model: an Issue (TM-01), a file or test output (TM-02), an MCP answer (TM-21)
  - Read it from the environment or disk, send it over the network (TM-03). **Nothing stops this in the job.**
  - Or leave it where it will be published: a commit (TM-04), the journal and its cache (TM-05, TM-24)
- Run as code without a model: a dependency (TM-20), an Action (TM-22), a kit release (TM-23)

**Get code into main**

- Directly: push with the job's token (TM-16), the push override (TM-13), a commit DRAIN does not attribute (TM-14)
- Through the process, with forged evidence:
  - a record, stamp or human marker made by a script (TM-07, TM-08), a cached journal or gate result (TM-24)
  - a renamed agent (TM-09), gates edited out (TM-10), mode lowered (TM-11), hooks off (TM-12), an exit written by the agent (TM-15)
- Through a person: an honest-looking pull request. The last real check is the owner reading the diff.

## Open gaps

Stated without a promise of a date.

Defects found while writing this, reproducible with hook input:

1. **The journal can store a secret (TM-05).** `shell_detail` keeps the second word of a command, so a URL with credentials or a password flag is written to `tools.jsonl`. The hook's header and SECURITY.md say command arguments are not stored.
2. **Gates and settings are not guarded (TM-10).** Edit, Write and shell writes to `scripts/hooks/*`, `.claude/settings.json`, `.claude/settings.local.json` and `.mcp.json` are allowed, while the config beside them is hard-denied. Whether Claude Code itself protects any of them was not checked.
3. **The push override is open to agents (TM-13).** `TEAMWRIGHT_ALLOW_PUSH=1 git push` and removing `TEAMWRIGHT_PAUSE` pass the gates.
4. **The autonomous sketch does not enable git hooks (TM-12).** `core.hooksPath` is local config and the example has no step for it, so on a fresh checkout pre-commit and pre-push do not run. The session check reports this, but no person reads it in a job.

Missing altogether:

- Any test of prompt injection against the chain, and any evidence of how the chain behaves under one.
- Isolation: no sandbox settings, no network limit, no scrubbing of the job's environment ships with the kit.
- Tamper evidence for stamps, ledgers and journals.
- A check that a project's repository has branch protection.
- Allow-listing or review of MCP servers after install.
- SAST or dependency audit of the kit's workflows and scripts, and for projects that install it.

## Checklist comparison

Used after STRIDE, to look for what it missed. Coverage here means "has a row", not "is solved".

**OWASP Top 10 for LLM Applications 2025.** LLM01 Prompt Injection: TM-01, TM-02. LLM02 Sensitive Information Disclosure: TM-03, TM-04, TM-05, TM-29. LLM03 Supply Chain: TM-20 to TM-23. LLM05 Improper Output Handling: TM-07, TM-18. LLM06 Excessive Agency: TM-16, TM-17. LLM10 Unbounded Consumption: TM-25. Not applicable to the kit, which holds no model, no embeddings and no product prompt of value: LLM04, LLM07, LLM08. LLM09 Misinformation: the process's reason to exist rather than a threat here (review, verify).

**OWASP Top 10 for Agentic Applications 2026.** Compared against secondary summaries only: the OWASP page was opened, the document itself was not read, so the names may differ from the original. Goal hijack: TM-01, TM-02. Tool misuse: TM-17, TM-18. Identity and privilege abuse: TM-06, TM-09, TM-16. Agentic supply chain: TM-21 to TM-23. Unexpected code execution: TM-19, TM-20. Memory and context poisoning: TM-07, TM-24. Inter-agent communication: records between roles, TM-07, TM-15. Cascading failures: TM-24, TM-25. Human-agent trust exploitation: TM-15, TM-26. Rogue agents: TM-10, TM-13.

## Out of scope

The same limits as [SECURITY.md](../../SECURITY.md#scope): `--no-verify`, a script or program writing files directly, shell forms the deny list does not match, an agent definition named `code-reviewer`, ledgers on another machine. They have rows here because they are real; they are not treated as vulnerabilities in the kit.

Also out of scope: the product a project builds; security of Claude Code, the model provider and GitHub themselves; a host already compromised; a malicious owner.

## Keeping this current

Update this file in the same change when a change touches hooks, the state guard, the installer's writes, the autonomous sketch, pre-approved commands, or adds a way to run without a person. Changing a row's status needs the code and the test, not a sentence. A reported bypass gets a fix or a row. Reread the whole document at each minor release; `make test` catches only references that went stale, not reasoning that did.
