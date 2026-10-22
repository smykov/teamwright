#!/usr/bin/env bash
# examples/demo.sh — one task through the teamwright lifecycle, offline, in a few seconds.
#
# Creates a throwaway git repository under `mktemp -d`, installs the kit from this
# checkout with scripts/tw-install.py, and walks task T-001 from TODO to DONE. Where an
# agent would act in Claude Code, the script sends the same hook input Claude Code sends
# (a PreToolUse JSON with tool_name, tool_input, agent_type) to the installed hooks, and
# applies the change only when the hook allows it. Every gate decision printed below is
# the real output of the project's scripts/hooks/*.sh.
#
# Needs bash (3.2+), git and python3. No network, no Claude Code, no Docker.
#
#   bash examples/demo.sh              # run, then delete the repository
#   bash examples/demo.sh --keep       # keep it and print its path
#   bash examples/demo.sh --full       # print the whole metrics report, not a summary
#   DEMO_PAUSE=1 bash examples/demo.sh # pause between steps (for recording)
#   DEMO_COLOR=1 bash examples/demo.sh # colours even when not writing to a terminal
#
# Exit code is non-zero if any gate decides differently than the walkthrough expects,
# so `make demo` (part of `make test`) keeps this file honest.
set -u

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0 FULL=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --full) FULL=1 ;;
    *) echo "usage: bash examples/demo.sh [--keep] [--full]" >&2; exit 2 ;;
  esac
done
PAUSE="${DEMO_PAUSE:-0}"
WORK="$(mktemp -d)"
if [ "$KEEP" -eq 0 ]; then trap 'rm -rf "$WORK"' EXIT; fi
P="$WORK/demo"
FAILED=0

# A clean, reproducible git and hook environment: no user config, fixed identities,
# none of the variables a real session might set.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Demo Owner" GIT_AUTHOR_EMAIL="owner@example.invalid"
export GIT_COMMITTER_NAME="Demo Owner" GIT_COMMITTER_EMAIL="owner@example.invalid"
unset TEAMWRIGHT_TASK PATCH_GUARD TEAMWRIGHT_ALLOW_PUSH TEAMWRIGHT_PAUSE_FILE TEAMWRIGHT_LOG_DIR \
  TEAMWRIGHT_REVIEWER_AGENT TEAMWRIGHT_PUSH_STATUSES TEAMWRIGHT_CLAUDE_MD_MAX_KB \
  TEAMWRIGHT_GATE_MODE TEAMWRIGHT_OWNER CLAUDECODE
export CLAUDE_PROJECT_DIR="$P"
export PYTHONDONTWRITEBYTECODE=1
SESSION="demo-session"
COAUTHOR="Co-Authored-By: Claude Code <agent@example.invalid>"

# Embedded helper (read into a variable: a heredoc inside $(...) breaks bash 3.2).
#   hook TOOL key=value... @top=value...  -> hook JSON on stdout
#   explain                               -> gate output on stdin, one readable verdict
IFS= read -r -d '' PYHELP <<'PY' || true
import json, sys, textwrap
cmd = sys.argv[1]
if cmd == "hook":
    tool, sid, kv = sys.argv[2], sys.argv[3], sys.argv[4:]
    ti, top = {}, {"hook_event_name": "PreToolUse"}
    for item in kv:
        k, v = item.split("=", 1)
        if k.startswith("@"):
            top[k[1:]] = v
        else:
            ti[k] = v
    out = {"tool_name": tool, "session_id": sid, "tool_input": ti}
    out.update(top)
    print(json.dumps(out))
elif cmd == "explain":
    raw = sys.stdin.read().strip()
    if not raw:
        print("allow"); sys.exit(0)
    try:
        d = json.loads(raw)
        hs = d.get("hookSpecificOutput", {})
        if hs.get("permissionDecision") == "deny":
            reason = hs.get("permissionDecisionReason", "")
            first = reason.split("\n")[0].strip()
            if first.endswith(":"):          # the rest is an example block: end the sentence
                first = first[:first.rstrip(":").rfind(". ") + 1] or first
            print("deny")
            for line in textwrap.wrap(first, 74):
                print("      " + line)
        else:
            print("warn " + d.get("systemMessage", "")[:200])
    except ValueError:
        print("unparsed " + raw[:200])
PY

B="" C="" RED="" GRN="" R=""
if [ -t 1 ] || [ "${DEMO_COLOR:-0}" = 1 ]; then
  B=$'\033[1m' C=$'\033[36m' RED=$'\033[1;31m' GRN=$'\033[32m' R=$'\033[0m'
fi
say()  { printf '%s\n' "$*"; }
step() {
  [ "$PAUSE" != 0 ] && sleep "$PAUSE"
  printf '\n%s== %s ==%s\n' "$B" "$*" "$R"
}
act()  { printf '%s> %s%s\n' "$C" "$*" "$R"; }

commit() {  # commit MESSAGE [co] : git hooks run as in a real project; co = agent-written
  local msg="$1"
  [ "${2:-}" = co ] && msg="$(printf '%s\n\n%s' "$1" "$COAUTHOR")"
  git -C "$P" commit -q -m "$msg" 2>>"$WORK/git-hooks.log" || { say "commit failed: $1"; FAILED=1; }
  say "  commit  $1"
}

# call EXPECT AGENT TOOL key=value...  : one tool call as Claude Code makes it - the
# journal, then every PreToolUse gate on Edit|Write|Bash (the order in settings.json).
# EXPECT is `allow` or the gate that must deny. Prints the decision; returns 0 on allow.
call() {
  local expect="$1" agent="$2" tool="$3"; shift 3
  local who=() json out verdict g denied=""
  case "$agent" in main) ;; *) who=("@agent_id=a-$agent" "@agent_type=$agent") ;; esac
  json="$(python3 -c "$PYHELP" hook "$tool" "$SESSION" "$@" ${who[@]+"${who[@]}"})"
  printf '%s' "$json" | bash "$P/scripts/hooks/journal.sh"
  for g in analysis-gate review-gate verify-gate; do
    out="$(printf '%s' "$json" | bash "$P/scripts/hooks/$g.sh")"
    verdict="$(printf '%s' "$out" | python3 -c "$PYHELP" explain)"
    [ "$verdict" = allow ] && continue
    denied="$denied $g"
    say "  ${RED}DENIED by $g:${R}"
    printf '%s\n' "$verdict" | sed 1d
  done
  [ -z "$denied" ] && say "  ${GRN}allowed${R} (analysis-gate, review-gate, verify-gate)"
  if [ "$expect" = allow ] && [ -n "$denied" ]; then say "  !! expected allow"; FAILED=1; fi
  if [ "$expect" != allow ] && [ "$denied" != " $expect" ]; then
    say "  !! expected a deny from $expect only"; FAILED=1; fi
  [ -z "$denied" ]
}
# landed AGENT TOOL FILE : the call ran - PostToolUse to the journal and the analysis
# gate (which keeps .teamwright/current-task).
landed() {
  local agent="$1" tool="$2" file="$3" who=() json
  case "$agent" in main) ;; *) who=("@agent_id=a-$agent" "@agent_type=$agent") ;; esac
  json="$(python3 -c "$PYHELP" hook "$tool" "$SESSION" "file_path=$file" \
    @hook_event_name=PostToolUse ${who[@]+"${who[@]}"})"
  printf '%s' "$json" | bash "$P/scripts/hooks/journal.sh"
  printf '%s' "$json" | bash "$P/scripts/hooks/analysis-gate.sh" >/dev/null
}
sedi() { sed "$1" "$2" > "$2.tmp" && mv "$2.tmp" "$2"; }
TASK="$P/docs/tasks/T-001.md"
# move AGENT FROM TO EXPECT : an Edit of T-001's status; on allow it lands and is committed
move() {
  local agent="$1" from="$2" to="$3" expect="$4" name="$1"
  [ "$agent" = main ] && name=orchestrator
  act "$name: T-001 $from -> $to"
  if call "$expect" "$agent" Edit "file_path=$TASK" "old_string=status: $from" "new_string=status: $to"; then
    sedi "s/^status: $from\$/status: $to/" "$TASK"
    landed "$agent" Edit "$TASK"
    git -C "$P" add docs/tasks
    commit "chore(task): T-001 ${from}→${to}"
  fi
}

say "teamwright demo: one task, every gate, real hook output"
say "kit: this checkout, version $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$KIT/.claude-plugin/plugin.json")"

# --------------------------------------------------------------------------------------
step "1. A small project with a bug"
mkdir -p "$P/src" "$P/test"
cd "$P" || exit 1
git init -q -b main .
cat > src/slug.sh <<'SH'
# slug TEXT -> lower-case words joined by dashes
slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-'
}
SH
cat > test/slug_test.sh <<'SH'
. src/slug.sh
fail=0
check() { got="$(slug "$1")"; [ "$got" = "$2" ] || { echo "FAIL slug '$1': got '$got', want '$2'"; fail=1; }; }
check "Hello World" "hello-world"
[ "$fail" -eq 0 ] && echo "tests: ok"
exit "$fail"
SH
git add -A && commit "chore: initial project"
act "sh test/slug_test.sh"
sh test/slug_test.sh | sed 's/^/  /'

# --------------------------------------------------------------------------------------
step "2. Install teamwright from this checkout"
cat > "$WORK/config.yml" <<'YML'
version: 1
process_version: 1.0.0
mode: gate-first
areas:
  - name: app
    source_dirs: [src]
    test_command: "sh test/slug_test.sh"
    api_test_command: "sh test/slug_test.sh"
    test_dirs: [test]
    stack: "POSIX shell"
gate_command: "sh test/slug_test.sh"
tools:
  spec: none
  context: builtin
  docs: none
  ui_verify: none
  api_verify: project-runner
language: en
YML
act "python3 scripts/tw-install.py apply --config config.yml"
python3 "$KIT/scripts/tw-install.py" --kit "$KIT" --project "$P" apply --config "$WORK/config.yml" \
  > "$WORK/apply.log" 2>&1 || { cat "$WORK/apply.log"; say "!! install failed"; exit 1; }
grep -E "conflict\(s\)|changed" "$WORK/apply.log" | tail -n 2 | sed 's/^/  /'
act "python3 scripts/tw-install.py enforce        # gates block instead of warning"
python3 "$KIT/scripts/tw-install.py" --kit "$KIT" --project "$P" enforce > "$WORK/enforce.log" 2>&1 ||
  { cat "$WORK/enforce.log"; exit 1; }
say "  mode: enforce"
say "  installed: AGENTS.md, CLAUDE.md, PRINCIPLES.md, .claude/agents/*,"
say "             .claude/settings.json (hooks), scripts/hooks/*, scripts/metrics/*,"
say "             docs/ templates; git core.hooksPath = scripts/hooks"
git add -A && commit "chore: adopt teamwright"

# --------------------------------------------------------------------------------------
step "3. Task T-001 is created"
cat > "$TASK" <<'MD'
---
id: T-001
title: slugs of titles with trailing spaces do not end with a dash
type: bug
status: TODO
sprint: 1
priority: P2
depends_on: []
deploys: false
surface: api
design_ref: ""
verify_exception: ""
class: input-normalisation
recurrence_of: []
absorbed_by: ""
blocked_on: ""
analysis:
  root_cause: ""
  evidence: ""
  invariant: ""
  seam: ""
  approach: ""
implemented_by: developer
review: ""
tail_code: ""
---

## Acceptance

- [ ] `slug "Release notes "` is `release-notes`
- [ ] Failure branch: trailing and leading spaces -> no leading or trailing dash, checked by test/slug_test.sh
MD
say "  docs/tasks/T-001.md: type bug, surface api, deploys false"
git add docs/tasks && commit "chore(task): T-001 →TODO"

# --------------------------------------------------------------------------------------
step "4. Analysis gate: no code before a written analysis"
move problem-investigator TODO ANALYSIS allow
act "developer edits src/slug.sh while T-001 is in ANALYSIS"
say "  (the session declared its task: TEAMWRIGHT_TASK=T-001)"
TEAMWRIGHT_TASK=T-001 call analysis-gate developer Edit "file_path=$P/src/slug.sh" \
  "old_string=tr -cs" "new_string=tr -s" || true
move developer ANALYSIS IN_PROGRESS analysis-gate
act "problem-investigator fills the analysis block"
if call allow problem-investigator Edit "file_path=$TASK" 'old_string=root_cause: ""' \
    "new_string=root_cause: tr turns every trailing non-alphanumeric run into a dash"; then
  sedi 's/^  root_cause: ""/  root_cause: tr -cs maps the trailing space run to a final dash/' "$TASK"
  sedi 's/^  evidence: ""/  evidence: src\/slug.sh:3, slug "Release notes " prints release-notes-/' "$TASK"
  sedi 's/^  invariant: ""/  invariant: a slug never starts or ends with a dash/' "$TASK"
  sedi 's/^  seam: ""/  seam: the slug function, the only producer of slugs/' "$TASK"
  sedi 's/^  approach: ""/  approach: strip leading and trailing dashes after the tr pipeline/' "$TASK"
  landed problem-investigator Edit "$TASK"
  git add docs/tasks && commit "docs(task): T-001 analysis"
fi
move developer ANALYSIS IN_PROGRESS allow
say "  active task: $(cat "$P/.teamwright/current-task" 2>/dev/null || echo none)"

# --------------------------------------------------------------------------------------
step "5. Red test first, then the fix"
act "test-writer adds a test for the failure branch"
if call allow test-writer Edit "file_path=$P/test/slug_test.sh" \
    'old_string=check "Hello World"' 'new_string=check "Release notes "'; then
  sedi 's/^check "Hello World" "hello-world"$/check "Hello World" "hello-world"\
check "Release notes " "release-notes"\
check "  Two  spaces  " "two-spaces"/' test/slug_test.sh
  landed test-writer Edit "$P/test/slug_test.sh"
fi
act "sh test/slug_test.sh        # must fail before the fix"
if sh test/slug_test.sh > "$WORK/red.log" 2>&1; then say "  !! test passed before the fix"; FAILED=1; fi
sed 's/^/  /' "$WORK/red.log"
git add test && commit "test(slug): T-001 trailing and leading spaces leave no dash" co
act "developer fixes src/slug.sh"
if call allow developer Edit "file_path=$P/src/slug.sh" \
    "old_string=tr -cs 'a-z0-9' '-'" "new_string=tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*\$//'"; then
  sedi "s/tr -cs 'a-z0-9' '-'\$/tr -cs 'a-z0-9' '-' | sed 's\/^-*\/\/; s\/-*\$\/\/'/" src/slug.sh
  landed developer Edit "$P/src/slug.sh"
fi
act "sh test/slug_test.sh"
if ! sh test/slug_test.sh > "$WORK/green.log" 2>&1; then say "  !! test still fails"; FAILED=1; fi
sed 's/^/  /' "$WORK/green.log"
git add src && commit "fix(slug): T-001 strip leading and trailing dashes" co
move developer IN_PROGRESS NEEDS_REVIEW allow

# --------------------------------------------------------------------------------------
step "6. Review gate: approval only from a separate reviewer"
move main NEEDS_REVIEW CODE_COMPLETE review-gate
REVIEW="$P/docs/tasks/T-001.reviews/1.md"
IFS= read -r -d '' REVIEW_TEXT <<'MD' || true
---
task: T-001
round: 1
reviewer: code-reviewer
verdict: APPROVE
recurrence_of: []
rca_task: ""
---

## Checked against

- [x] docs/failures.md and recent tasks touching the same seam: no earlier fix of this class
- [x] PRINCIPLES.md: no violation
- [x] Acceptance hits the failure branch; test/slug_test.sh fails without the change

## Verdict rationale

The fix restores the invariant in the only producer of slugs instead of patching callers.
MD
act "developer writes the review record for its own task"
call review-gate developer Write "file_path=$REVIEW" "content=$REVIEW_TEXT" || true
act "orchestrator spawns a code-reviewer agent for T-001 (journaled)"
python3 -c "$PYHELP" hook Agent "$SESSION" subagent_type=code-reviewer description=review \
  "prompt=Review T-001: diff, task record, principles, recurrence" | bash "$P/scripts/hooks/journal.sh"
say "  journal: .teamwright/logs/tools.jsonl records the spawn with task_ids [T-001]"
act "code-reviewer writes docs/tasks/T-001.reviews/1.md: APPROVE"
if call allow code-reviewer Write "file_path=$REVIEW" "content=$REVIEW_TEXT"; then
  mkdir -p "$(dirname "$REVIEW")" && printf '%s' "$REVIEW_TEXT" > "$REVIEW"
  landed code-reviewer Write "$REVIEW"
  python3 -c "$PYHELP" hook "" "$SESSION" @hook_event_name=SubagentStop @agent_id=a-code-reviewer \
    @agent_type=code-reviewer "@last_assistant_message=$(printf 'APPROVE T-001.\nOutcome: barrier')" |
    bash "$P/scripts/hooks/journal.sh"
  git add docs/tasks && commit "docs(review): T-001 round 1 APPROVE" co
fi
move main NEEDS_REVIEW CODE_COMPLETE allow

# --------------------------------------------------------------------------------------
step "7. Verify gate: done means a recorded PASS for the current code and an acceptance PASS"
move main CODE_COMPLETE DONE verify-gate
act "task-validator runs the API tests and records the run"
mkdir -p reports
sh test/slug_test.sh > reports/T-001-api.log 2>&1
SHA="$(git rev-parse HEAD)"
VERIFY="$P/docs/tasks/T-001.verify/1.md"
VERIFY_TEXT="$(printf -- '---\ntask: T-001\nround: 1\nkind: api\ncommand: sh test/slug_test.sh\nenvironment: local\ncommit: %s\nresult: PASS\nevidence: reports/T-001-api.log\nverifier: task-validator\n---\n\n## Scenarios checked\n\n- Happy path: "Hello World" -> hello-world\n- Failure branch: "Release notes " and "  Two  spaces  " -> no leading or trailing dash\n' "$SHA")"
if call allow task-validator Write "file_path=$VERIFY" "content=$VERIFY_TEXT"; then
  mkdir -p "$(dirname "$VERIFY")" && printf '%s\n' "$VERIFY_TEXT" > "$VERIFY"
  landed task-validator Write "$VERIFY"
  git add docs/tasks && commit "docs(verify): T-001 round 1 api PASS" co
fi
move main CODE_COMPLETE DONE verify-gate
act "task-validator checks every Acceptance item against evidence: acceptance PASS"
VALIDATION="$P/docs/tasks/T-001.validation/1.md"
VALIDATION_TEXT="$(printf -- '---\ntask: T-001\nround: 1\nverdict: PASS\ncommit: %s\nvalidator: task-validator\n---\n\n## Claims\n\n- both Acceptance items: test/slug_test.sh, run in verify/1.md\n' "$(git rev-parse HEAD)")"
if call allow task-validator Write "file_path=$VALIDATION" "content=$VALIDATION_TEXT"; then
  mkdir -p "$(dirname "$VALIDATION")" && printf '%s\n' "$VALIDATION_TEXT" > "$VALIDATION"
  landed task-validator Write "$VALIDATION"
  git add docs/tasks && commit "docs(validation): T-001 round 1 PASS" co
fi
move main CODE_COMPLETE DONE allow
python3 -c "$PYHELP" hook "" "$SESSION" @hook_event_name=Stop \
  "@last_assistant_message=$(printf 'T-001 done.\nOutcome: idle')" | bash "$P/scripts/hooks/journal.sh"

# --------------------------------------------------------------------------------------
step "8. Metrics from git and the hook journals"
act "python3 scripts/metrics/teamwright-metrics"
python3 scripts/metrics/teamwright-metrics > "$WORK/metrics.md" 2>&1 || { cat "$WORK/metrics.md"; FAILED=1; }
if [ "$FULL" -eq 1 ]; then
  cat "$WORK/metrics.md"
else
  # a few rows of the real report (value with its n); --full prints all of it with sources
  for m in "commits" "agent co-authored commits" "fix share" "tasks done" "review rounds mean" \
      "approved without review record" "sessions with reviewer evidence" \
      "approvals (-> CODE_COMPLETE) with a journaled reviewer spawn"; do
    awk -F' [|] ' -v m="$m" '$1 == "| " m { printf "  %-62s %s\n", m, $2; exit }' "$WORK/metrics.md"
  done
  grep -E '^- (Session|Subagent) outcomes' "$WORK/metrics.md" | sed 's/^- /  /'
  say "  (summary; --full prints the whole report with the source of every number)"
fi

say ""
if [ "$KEEP" -eq 1 ]; then say "demo repository kept: $P"; fi
if [ "$FAILED" -ne 0 ]; then say "DEMO FAILED: a gate decided differently than expected"; exit 1; fi
say "demo: ok"
