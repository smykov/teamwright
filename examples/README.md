# Demo: one task through every gate

`demo.sh` shows what teamwright does in a repository without Claude Code, a network or Docker. It needs `bash` (3.2 or later), `git` and `python3`, and runs in a few seconds:

```bash
bash examples/demo.sh          # or: make demo
bash examples/demo.sh --keep   # keep the demo repository and print its path
bash examples/demo.sh --full   # the whole metrics report instead of a summary
```

## What it does

1. Creates a throwaway git repository under `mktemp -d` with a small shell function that has a bug: `slug "Release notes "` returns `release-notes-`.
2. Installs the kit from this checkout with `scripts/tw-install.py apply`, then switches the gates from warning to blocking with `tw-install.py enforce`.
3. Creates task `T-001` for the bug and walks it through the lifecycle:

| Step | Who acts | Gate decision |
|---|---|---|
| Edit `src/slug.sh` while the task is in `ANALYSIS` | developer | **denied** by the analysis gate |
| `ANALYSIS → IN_PROGRESS` with an empty analysis block | developer | **denied** by the analysis gate |
| Fill the analysis block, then `ANALYSIS → IN_PROGRESS` | problem-investigator, developer | allowed |
| A failing test, then the fix, each committed | test-writer, developer | allowed |
| `NEEDS_REVIEW → CODE_COMPLETE` without a review record | orchestrator | **denied** by the review gate |
| The developer writes the review record for its own task | developer | **denied** by the review gate |
| A journaled code-reviewer writes `APPROVE`, then `CODE_COMPLETE` | code-reviewer, orchestrator | allowed |
| `CODE_COMPLETE → DONE` without a verify record | orchestrator | **denied** by the verify gate |
| A `PASS` verify record for the current commit, then `DONE` | task-validator, orchestrator | allowed |

4. Runs `scripts/metrics/teamwright-metrics` on the result: git history, task transitions, review records and hook journals.

## How it simulates the agents

In Claude Code, every tool call goes through the hooks listed in the project's `.claude/settings.json`: the journal, then the analysis, review and verify gates. The hooks read a JSON event on stdin (`tool_name`, `tool_input`, `agent_type`, `agent_id`, `session_id`). The demo builds the same events and pipes them into the installed `scripts/hooks/*.sh`. A change is applied only when every gate allows it, and each step is committed with the commit convention, so the git hooks (secret scan, patch guard, commit message) run too.

What it does not show: the model's own work in a `/teamwright:flow` session (reading code, writing the analysis, choosing a fix). The gate decisions and the metrics are the real output of the kit.

The script exits non-zero if any gate decides differently than the walkthrough expects. `tests/test-demo.sh` runs it as part of `make test`, so the demo breaks the build when the gates change.

## The recording

`docs/assets/demo.gif` is this demo, recorded with `make-cast.py` (it runs the demo once and adds reading pauses; the text is unchanged) and rendered with [agg](https://github.com/asciinema/agg):

```bash
python3 examples/make-cast.py demo.cast
agg --font-size 14 --theme monokai --last-frame-duration 5 demo.cast docs/assets/demo.gif
```
