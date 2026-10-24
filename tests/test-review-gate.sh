#!/usr/bin/env bash
# Regression: review-gate.sh (+ journal.sh as the source of spawn facts).
# Identity model under test: subagents share the parent's session_id; only
# agent_id / agent_type tell the orchestrator, developer and reviewer apart.
. "$(dirname "$0")/lib.sh"
echo "review-gate"
GATE="$HOOKS/review-gate.sh"
JOURNAL="$HOOKS/journal.sh"
P="$TMP/proj"; mkdir -p "$P/docs/tasks"
export CLAUDE_PROJECT_DIR="$P"
S=sess-1                                   # one session for everybody
DEV=(@agent_id=a-dev @agent_type=developer)
REV=(@agent_id=a-rev @agent_type=code-reviewer)
run() { hook_json "$@" | bash "$GATE"; }
tf() { echo "$P/docs/tasks/$1.md"; }
rd() { echo "$P/docs/tasks/$1.reviews"; }
review_text() {  # review_text ID VERDICT [RCA] [REVIEWER]
  printf -- '---\ntask: %s\nround: 1\nreviewer: %s\nverdict: %s\n%s---\nfindings\n' \
    "$1" "${4:-code-reviewer}" "$2" "${3:+rca_task: $3
}"
}
# write_review ID N VERDICT WHO... : ask the gate as WHO; on allow, the tool "runs"
write_review() {
  local id="$1" n="$2" verdict="$3"; shift 3
  local content out
  content="$(review_text "$id" "$verdict")"
  out="$(run Write "$S" "file_path=$(rd "$id")/$n.md" "content=$content" "$@")"
  if [ -z "$out" ]; then mkdir -p "$(rd "$id")"; printf '%s\n' "$content" > "$(rd "$id")/$n.md"; landed "$(rd "$id")/$n.md" "$@"; fi
  printf '%s' "$out"
}
# landed FILE WHO... : the Write ran - PostToolUse turns the gate's pending ledger line and stamp into evidence
landed() { local f="$1"; shift; hook_json Write "$S" "file_path=$f" @hook_event_name=PostToolUse "$@" | bash "$GATE" >/dev/null; }
to_cc() {  # to_cc ID [WHO...]  (default: orchestrator = no agent fields)
  local id="$1"; shift
  run Edit "$S" "file_path=$(tf "$id")" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE" "$@"
}
spawn() {  # spawn TYPE PROMPT : journal the orchestrator's Agent call
  hook_json Agent "$S" "subagent_type=$1" "description=review" "prompt=$2" \
    @hook_event_name=PreToolUse | bash "$JOURNAL"
}

# ---- main flow: developer subagent -> reviewer subagent -> orchestrator -------
task_file "$(tf T-1)" T-1 TODO bug full
out="$(run Edit "$S" "file_path=$(tf T-1)" "old_string=status: TODO" "new_string=status: IN_PROGRESS" "${DEV[@]}")"
expect_allow "developer entering IN_PROGRESS is not this gate's business" "$out"
task_file "$(tf T-1)" T-1 IN_PROGRESS bug full
out="$(run Edit "$S" "file_path=$(tf T-1)" "old_string=status: IN_PROGRESS" "new_string=status: NEEDS_REVIEW" "${DEV[@]}")"
expect_allow "developer submitting for review is allowed" "$out"
if grep -qx "$S:a-dev" "$P/.teamwright/sessions/T-1.dev" 2>/dev/null; then
  ok "developer recorded by session_id + agent_id"; else bad "developer recorded by session_id + agent_id"; fi
task_file "$(tf T-1)" T-1 NEEDS_REVIEW bug full

out="$(to_cc T-1)"; expect_deny "CODE_COMPLETE without a review record is denied" "$out" "no review record"
out="$(write_review T-1 1 APPROVE)"
expect_deny "orchestrator (same session, no agent_type) cannot write the review" "$out" "only a code-reviewer"
out="$(write_review T-1 1 APPROVE "${DEV[@]}")"
expect_deny "developer subagent cannot write the review" "$out" "implemented"
out="$(write_review T-1 1 APPROVE @agent_id=a-dev @agent_type=code-reviewer)"
expect_deny "an implementing agent id stays denied even with reviewer type" "$out" "implemented"
out="$(run Write "$S" "file_path=$(rd T-1)/1.md" "content=$(review_text T-1 APPROVE "" human:alex)" "${REV[@]}")"
expect_deny "an agent cannot write a human review marker" "$out" "human"

out="$(run Write "$S" "file_path=$(rd T-1)/1.md" "content=$(review_text T-1 LGTM)" "${REV[@]}")"
expect_deny "unknown verdict is denied" "$out" "verdict"
out="$(run Write "$S" "file_path=$(rd T-1)/1.md" "content=$(review_text T-1 REJECT_RECURRENCE)" "${REV[@]}")"
expect_deny "REJECT_RECURRENCE without rca_task is denied" "$out" "rca"
out="$(run Write "$S" "file_path=$(rd T-1)/1.md" "content=$(review_text T-1 REJECT_RECURRENCE T-50)" "${REV[@]}")"
expect_deny "REJECT_RECURRENCE pointing at a missing task is denied" "$out" "rca"
task_file "$(tf T-51)" T-51 TODO bug full
out="$(run Write "$S" "file_path=$(rd T-1)/1.md" "content=$(review_text T-1 REJECT_RECURRENCE T-51)" "${REV[@]}")"
expect_deny "REJECT_RECURRENCE pointing at a non-rca task is denied" "$out" "rca"
task_file "$(tf T-50)" T-50 TODO rca none
out="$(run Write "$S" "file_path=$(rd T-1)/1.md" "content=$(review_text T-1 REJECT_RECURRENCE T-50)" "${REV[@]}")"
expect_allow "REJECT_RECURRENCE with a linked rca task is allowed" "$out"

out="$(write_review T-1 1 APPROVE "${REV[@]}")"
expect_allow "reviewer subagent (same session, own agent_id) writes the review" "$out"
spawn code-reviewer "Review task T-2 only"
out="$(to_cc T-1)"
expect_deny "approval without a journaled reviewer spawn for this task is denied" "$out" "journaled spawn"
spawn code-reviewer "Review T-1: diff, task record, principles"
if grep -q '"task_ids": \["T-1"\]' "$P/.teamwright/logs/tools.jsonl"; then
  ok "journal records the spawn with its task id"; else bad "journal records the spawn with its task id"; fi
out="$(to_cc T-1)"
expect_allow "orchestrator moves to CODE_COMPLETE after the reviewer's APPROVE" "$out"
out="$(to_cc T-1 "${DEV[@]}")"
expect_allow "who moves the status does not matter once the approval is genuine" "$out"

sedi 's/^title: sample/implemented_by: code-reviewer/' "$(tf T-1)"
out="$(to_cc T-1)"; expect_deny "reviewer equal to implemented_by is denied" "$out" "self-review"

# an approval from before a VERIFY_FAIL does not carry over (prove-it run 26, 24.10.2026)
task_file "$(tf T-70)" T-70 NEEDS_REVIEW bug full
spawn code-reviewer "Review T-70"
write_review T-70 1 APPROVE "${REV[@]}" >/dev/null
touch -d '2 days ago' "$(rd T-70)/1.md"
mkdir -p "$P/docs/tasks/T-70.validation"
printf -- '---\ntask: T-70\nround: 1\nverdict: FAIL\n---\nfailed\n' > "$P/docs/tasks/T-70.validation/1.md"
out="$(to_cc T-70)"; expect_deny "an APPROVE older than the task's failed check is denied" "$out" "older than its failed check"
spawn code-reviewer "Review T-70 after the failed check"
write_review T-70 2 APPROVE "${REV[@]}" >/dev/null
out="$(to_cc T-70)"; expect_allow "a fresh review round after the failed check passes" "$out"

# a record edited to APPROVE outside the reviewer
task_file "$(tf T-5)" T-5 NEEDS_REVIEW bug full
write_review T-5 1 REQUEST_CHANGES "${REV[@]}" >/dev/null
spawn code-reviewer "Review T-5"
sedi 's/^verdict: REQUEST_CHANGES/verdict: APPROVE/' "$(rd T-5)/1.md"
out="$(to_cc T-5)"; expect_deny "verdict changed after the reviewer wrote it is denied" "$out" "later changed"
printf -- '---\ntask: T-5\nround: 2\nreviewer: code-reviewer\nverdict: APPROVE\n---\n' > "$(rd T-5)/2.md"
out="$(to_cc T-5)"; expect_deny "review file with no ledger entry (written around the gate) is denied" "$out" "not written by a code-reviewer"

# ---- review rounds are counted from files, not trusted from the task ----------
task_file "$(tf T-2)" T-2 NEEDS_REVIEW bug full      # review_rounds: 0 in the record
spawn code-reviewer "Review T-2"
write_review T-2 1 REQUEST_CHANGES "${REV[@]}" >/dev/null
out="$(to_cc T-2)"
expect_deny "CODE_COMPLETE after REQUEST_CHANGES is denied" "$out" "not APPROVE"
expect_deny "message uses the computed round count, not the field" "$out" "Review rounds so far: 1"
out="$(write_review T-2 2 REQUEST_CHANGES "${REV[@]}")"
expect_allow "second REQUEST_CHANGES is allowed" "$out"
out="$(to_cc T-2)"; expect_deny "after 2 rounds of changes the message demands escalation" "$out" "must be ESCALATE"
out="$(write_review T-2 3 REQUEST_CHANGES "${REV[@]}")"
expect_deny "third REQUEST_CHANGES is denied (escalate instead)" "$out" "ESCALATE"
out="$(write_review T-2 3 ESCALATE "${REV[@]}")"
expect_allow "ESCALATE after two rounds is allowed" "$out"
out="$(to_cc T-2)"; expect_deny "ESCALATE is not an approval" "$out" "not APPROVE"
expect_deny "after ESCALATE the message names the owner decision" "$out" "owner decides"

# ---- the third record of a run of send-backs: only ESCALATE or REJECT_RECURRENCE
task_file "$(tf T-7)" T-7 NEEDS_REVIEW bug full
spawn code-reviewer "Review T-7"
write_review T-7 1 REQUEST_CHANGES "${REV[@]}" >/dev/null
write_review T-7 2 REQUEST_CHANGES "${REV[@]}" >/dev/null
out="$(write_review T-7 3 APPROVE "${REV[@]}")"
expect_deny "APPROVE as the third record after two send-backs is denied" "$out" "third"
out="$(to_cc T-7)"; expect_deny "so the task cannot reach CODE_COMPLETE on round 3" "$out" "not APPROVE"
task_file "$(tf T-70)" T-70 TODO rca rca
out="$(run Write "$S" "file_path=$(rd T-7)/3.md" "content=$(review_text T-7 REJECT_RECURRENCE T-70)" "${REV[@]}")"
expect_allow "REJECT_RECURRENCE as the third record is allowed" "$out"
# an APPROVE or ESCALATE ends a run: a task back after VERIFY_FAIL starts a new count
task_file "$(tf T-8)" T-8 NEEDS_REVIEW bug full
spawn code-reviewer "Review T-8"
write_review T-8 1 REQUEST_CHANGES "${REV[@]}" >/dev/null
write_review T-8 2 APPROVE "${REV[@]}" >/dev/null
write_review T-8 3 REQUEST_CHANGES "${REV[@]}" >/dev/null
out="$(write_review T-8 4 APPROVE "${REV[@]}")"
expect_allow "after an APPROVE the send-backs are counted afresh" "$out"
out="$(to_cc T-8)"; expect_allow "round 4 APPROVE in a new run moves the task to CODE_COMPLETE" "$out"

# ---- human review outside Claude Code ------------------------------------------
task_file "$(tf T-3)" T-3 NEEDS_REVIEW bug full
mkdir -p "$(rd T-3)"; review_text T-3 APPROVE "" human:alex > "$(rd T-3)/1.md"
out="$(to_cc T-3)"; expect_allow "review committed by a person (reviewer: human:<name>) is accepted" "$out"

# ---- a whole session started as `claude --agent code-reviewer` ------------------
task_file "$(tf T-4)" T-4 NEEDS_REVIEW bug full
out="$(S=sess-review write_review T-4 1 APPROVE @agent_type=code-reviewer)"
expect_allow "top-level reviewer session (agent_type, no agent_id) writes the review" "$out"
out="$(to_cc T-4)"; expect_allow "its approval needs no spawn record" "$out"

# ---- send-back, shell writes, exits ----------------------------------------------
task_file "$(tf T-6)" T-6 NEEDS_REVIEW bug full
out="$(run Edit "$S" "file_path=$(tf T-6)" "old_string=status: NEEDS_REVIEW" "new_string=status: IN_PROGRESS")"
if grep -qx "$S:main" "$P/.teamwright/sessions/T-6.dev" 2>/dev/null; then
  bad "send-back not recorded as development"; else ok "send-back not recorded as development"; fi

out="$(run Bash "$S" "command=printf 'verdict: APPROVE' > docs/tasks/T-6.reviews/1.md")"
expect_deny "shell write of a review record is denied" "$out" "Edit/Write"
out="$(run Bash "$S" "command=rm -f .teamwright/sessions/T-6.dev")"
expect_deny "shell removal of a ledger is denied" "$out" "ledgers"
out="$(run Bash "$S" "command=cat docs/tasks/T-6.reviews/1.md 2>/dev/null")"
expect_allow "reading review records via shell is allowed" "$out"

rm -rf "$(rd T-6)"
printf -- '---\nid: T-6\nstatus: NEEDS_REVIEW\nreview: skipped:trivial\n---\n' > "$(tf T-6)"
out="$(to_cc T-6)"; expect_allow "review: skipped:trivial is an accepted exit" "$out"

out="$(run Edit "$S" "file_path=$P/src/x.ts" "old_string=a" "new_string=b")"
expect_allow "non-task files are ignored" "$out"
out="$(hook_json Edit "$S" "file_path=$(tf T-1)" @hook_event_name=PostToolUse | bash "$GATE")"
expect_allow "PostToolUse events are ignored" "$out"
out="$(printf '{bad' | bash "$GATE")"; expect_allow "garbage input fails open" "$out"
# ---- process.review.blocking: the verdict must match the findings table ----------
rv_tab() {  # rv_tab ID N VERDICT "Sev|Cat" ... -> review text with a findings table
  local id="$1" n="$2" v="$3"; shift 3
  printf -- '---\ntask: %s\nround: %s\nreviewer: code-reviewer\nverdict: %s\n---\n\n## Findings\n\n| # | Severity | Category | Where | Finding | Required change |\n|---|---|---|---|---|---|\n' "$id" "$n" "$v"
  local i=0 r; for r in "$@"; do i=$((i+1)); printf '| %d | %s | %s | a.py:1 | x | y |\n' "$i" "${r%%|*}" "${r##*|}"; done
  printf '\n## Verdict rationale\n\nok\n'
}
wr() { run Write "$S" "file_path=$(rd "$1")/$2.md" "content=$(rv_tab "$@")" "${REV[@]}"; }
task_file "$(tf T-40)" T-40 NEEDS_REVIEW bug full
spawn code-reviewer "review T-40"
out="$(wr T-40 1 REQUEST_CHANGES "Low|maintainability")"
expect_allow "no process.review.blocking: findings are not checked (old behaviour)" "$out"
mkdir -p "$P/.teamwright"; printf 'version: 1\nprocess:\n  review:\n    blocking: medium\n' > "$P/.teamwright/config.yml"
out="$(wr T-40 1 REQUEST_CHANGES "Low|maintainability" "Low|docs-drift")"
expect_deny "medium: REQUEST_CHANGES with only Low findings is denied" "$out" "follow-ups"
out="$(wr T-40 1 APPROVE "Low|maintainability" "Low|docs-drift")"
expect_allow "medium: APPROVE with Low findings (follow-ups) is allowed" "$out"
out="$(wr T-40 1 APPROVE "Medium|docs-drift")"
expect_deny "medium: APPROVE with a Medium finding is denied" "$out" "blocking finding"
out="$(wr T-40 1 REQUEST_CHANGES "Medium|correctness")"
expect_allow "medium: REQUEST_CHANGES with a Medium finding is allowed" "$out"
printf 'version: 1\nprocess:\n  review:\n    blocking: high\n' > "$P/.teamwright/config.yml"
out="$(wr T-40 1 APPROVE "Low|secret-leak")"
expect_deny "high: an always-blocking category blocks at Low" "$out" "blocking finding"
out="$(wr T-40 1 APPROVE "Medium|weakened-test")"
expect_deny "high: weakened-test blocks whatever the severity" "$out" "blocking finding"
out="$(wr T-40 1 APPROVE "Medium|docs-drift" "Low|maintainability")"
expect_allow "high: Medium docs-drift is a follow-up" "$out"
out="$(wr T-40 1 APPROVE "Critical|correctness")"
expect_deny "Critical always blocks" "$out" "blocking finding"
out="$(wr T-40 1 APPROVE "Minor|correctness")"
expect_deny "an unknown severity is refused" "$out" "Severity Critical"
# the findings table is read wherever the reviewer put it, not only under `## Findings`
printf 'version: 1\nprocess:\n  review:\n    blocking: medium\n' > "$P/.teamwright/config.yml"
rv_head() {  # rv_head ID N VERDICT HEADING "Sev|Cat" -> one-row table under HEADING ("" = none)
  local id="$1" n="$2" v="$3" h="$4" r="$5"
  printf -- '---\ntask: %s\nround: %s\nreviewer: code-reviewer\nverdict: %s\n---\n\n### Review round %s\n\n' "$id" "$n" "$v" "$n"
  [ -n "$h" ] && printf '%s\n\n' "$h"
  printf '| # | Severity | Category | Where | Finding | Required change |\n|---|---|---|---|---|---|\n| 1 | %s | %s | a.py:1 | x | y |\n\n## Verdict rationale\n\nok\n' "${r%%|*}" "${r##*|}"
}
wh() { run Write "$S" "file_path=$(rd "$1")/$2.md" "content=$(rv_head "$@")" "${REV[@]}"; }
out="$(wh T-40 1 APPROVE "#### Findings" "Medium|correctness")"
expect_deny "a table under #### Findings is read: APPROVE with a Medium is denied" "$out" "blocking finding"
out="$(wh T-40 1 APPROVE "" "High|correctness")"
expect_deny "a table with no Findings heading is read: APPROVE with a High is denied" "$out" "blocking finding"
out="$(wh T-40 1 REQUEST_CHANGES "" "Medium|correctness")"
expect_allow "a table with no Findings heading is read: REQUEST_CHANGES with a Medium is allowed" "$out"
out="$(wh T-40 1 REQUEST_CHANGES "#### New in the fix" "Low|docs-drift")"
expect_deny "no Findings heading, only Low rows: REQUEST_CHANGES is still denied" "$out" "follow-ups"
rm -f "$P/.teamwright/config.yml"

# ---- 7. one reviewed task spawns at most two new tasks ----------------------------
S7=sess-7
spawn7() {  # spawn7 TYPE DESCRIPTION [agent fields...] : a spawn in session S7
  local t="$1" d="$2"; shift 2
  hook_json Agent "$S7" "subagent_type=$t" "description=$d" "prompt=go" @hook_event_name=PreToolUse "$@" | bash "$JOURNAL"
}
newtask() {  # newtask ID [agent fields...] : ask the gate to create docs/tasks/ID.md; on allow, create it
  local id="$1" out; shift
  out="$(run Write "$S7" "file_path=$(tf "$id")" "content=---
id: $id
status: TODO
---
" "$@")"
  case "$out" in *'"deny"'*) ;; *) task_file "$(tf "$id")" "$id" TODO bug none ;; esac
  printf '%s' "$out"
}
out="$(newtask T-70)"; expect_allow "a new task outside a review is not counted" "$out"
spawn7 code-reviewer "T-71 code-reviewer"
out="$(newtask T-72 "${REV[@]}")"; expect_allow "review of T-71: first new task (by the reviewer)" "$out"
out="$(newtask T-73)"; expect_allow "review of T-71: second new task (by the orchestrator)" "$out"
out="$(newtask T-74)"; expect_deny "review of T-71: a third new task is refused" "$out" "at most 2"
out="$(run Edit "$S7" "file_path=$(tf T-73)" "old_string=body" "new_string=body, one more finding")"
expect_allow "adding to an existing task record is not a new task" "$out"
out="$(TEAMWRIGHT_REVIEW_NEW_TASKS=3 newtask T-74)"; expect_allow "TEAMWRIGHT_REVIEW_NEW_TASKS raises the limit" "$out"
rm -f "$(tf T-74)"
out="$(TEAMWRIGHT_GATE_MODE=warn newtask T-75)"
case "$out" in *'"deny"'*) bad "gate-first: a third new task warns, does not block" "$out" ;;
  *at\ most*) ok "gate-first: a third new task warns, does not block" ;;
  *) bad "gate-first: a third new task warns, does not block" "no warning: $out" ;; esac
spawn7 code-reviewer "T-76 code-reviewer"
out="$(newtask T-77)"; expect_allow "a new reviewer spawn opens a new count for its task" "$out"
spawn7 code-reviewer "T-76 code-reviewer" @agent_id=a-rev @agent_type=code-reviewer
out="$(newtask T-78)"; out="$(newtask T-79)"
expect_deny "a reviewer's own sub-spawn does not reset the count" "$out" "T-76"
spawn7 developer "T-80 developer"
out="$(newtask T-81)"; expect_allow "after a spawn of another role the review window is closed" "$out"

# ---- B2: the committed stamp survives a fresh checkout (an autonomous job) ----------
S9=sess-9
task_file "$(tf T-90)" T-90 NEEDS_REVIEW bug full
hook_json Agent "$S9" "subagent_type=code-reviewer" "description=T-90 code-reviewer" "prompt=go" @hook_event_name=PreToolUse | bash "$JOURNAL"
c90="$(review_text T-90 APPROVE)"
out="$(run Write "$S9" "file_path=$(rd T-90)/1.md" "content=$c90" "${REV[@]}")"
expect_allow "reviewer writes APPROVE for T-90" "$out"
mkdir -p "$(rd T-90)"; printf '%s\n' "$c90" > "$(rd T-90)/1.md"; S="$S9" landed "$(rd T-90)/1.md" "${REV[@]}"
[ -f "$(rd T-90)/1.gate.json" ] && ok "the gate writes the stamp next to the record" || bad "the gate writes the stamp next to the record"
grep -q '"spawned": true' "$(rd T-90)/1.gate.json" && ok "the stamp records the journaled spawn" || bad "the stamp records the journaled spawn" "$(cat "$(rd T-90)/1.gate.json" 2>/dev/null)"
mv "$P/.teamwright" "$TMP/tw-state"           # a fresh checkout: no ledgers, no journal
out="$(run Edit "$S9-next" "file_path=$(tf T-90)" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_allow "fresh checkout: the status move in a later session is checked against the stamp" "$out"
printf '%s\nedited later\n' "$c90" > "$(rd T-90)/1.md"
out="$(run Edit "$S9-next" "file_path=$(tf T-90)" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_deny "a record changed after its stamp does not count" "$out" "not written by a code-reviewer"
printf '%s\n' "$c90" > "$(rd T-90)/1.md"
out="$(run Write "$S9" "file_path=$(rd T-90)/1.gate.json" "content={}" "${REV[@]}")"
expect_deny "no agent writes a stamp (state guard)" "$out" "written only by the hooks"
out="$(run Bash "$S9" "command=echo {} > docs/tasks/T-90.reviews/1.gate.json")"
expect_deny "no shell write of a stamp" "$out" "never by shell"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["spawned"]=False; json.dump(d,open(p,"w"))' "$(rd T-90)/1.gate.json"
out="$(run Edit "$S9-next" "file_path=$(tf T-90)" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_deny "a stamp without the journaled spawn, journal gone: still denied" "$out" "journaled spawn"
rm -rf "$P/.teamwright"; mv "$TMP/tw-state" "$P/.teamwright"

# ---- N1: an approval copied to another task does not count there ----------------------
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["spawned"]=True; json.dump(d,open(p,"w"))' "$(rd T-90)/1.gate.json"
grep -q '"task": "T-90"' "$(rd T-90)/1.gate.json" && grep -q '"path": "docs/tasks/T-90.reviews/1.md"' "$(rd T-90)/1.gate.json" \
  && ok "the stamp names its task and record" || bad "the stamp names its task and record" "$(cat "$(rd T-90)/1.gate.json")"
task_file "$(tf T-91)" T-91 NEEDS_REVIEW bug full
mkdir -p "$(rd T-91)"; cp "$(rd T-90)/1.md" "$(rd T-90)/1.gate.json" "$(rd T-91)/"
out="$(run Edit "$S9-next" "file_path=$(tf T-91)" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_deny "with the local ledger: T-90's approval copied to T-91 does not count" "$out" "copied from another task"
mv "$P/.teamwright" "$TMP/tw-state"
out="$(run Edit "$S9-next" "file_path=$(tf T-91)" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_deny "fresh checkout: T-90's approval copied to T-91 does not count" "$out" "copied from another task"
sed 's/^task: T-90$/task: T-91/' "$(rd T-90)/1.md" > "$(rd T-91)/1.md"
out="$(run Edit "$S9-next" "file_path=$(tf T-91)" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_deny "fresh checkout: the copy renamed to T-91 no longer matches the stamp" "$out" "not written by a code-reviewer"
python3 - "$(rd T-91)/1.gate.json" "$(rd T-91)/1.md" <<'PY'
import hashlib, json, sys
st = json.load(open(sys.argv[1])); text = open(sys.argv[2]).read()
st["sha256"] = hashlib.sha256((text.rstrip("\n") + "\n").encode()).hexdigest()
json.dump(st, open(sys.argv[1], "w"))
PY
out="$(run Edit "$S9-next" "file_path=$(tf T-91)" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_deny "fresh checkout: a stamp re-hashed for T-91 still names T-90" "$out" "not written by a code-reviewer"
rm -rf "$P/.teamwright"; mv "$TMP/tw-state" "$P/.teamwright"
task_file "$(tf T-92)" T-92 NEEDS_REVIEW bug full
hook_json Agent "$S9" "subagent_type=code-reviewer" "description=T-92 code-reviewer" "prompt=go" @hook_event_name=PreToolUse | bash "$JOURNAL"
out="$(run Write "$S9" "file_path=$(rd T-92)/1.md" "content=$(review_text T-90 APPROVE)" "${REV[@]}")"
expect_deny "a review record naming another task is refused when written" "$out" "task: T-92"

# ---- N2: with a local ledger the ledger alone decides; no forging through the shell -----
task_file "$(tf T-93)" T-93 NEEDS_REVIEW bug full
hook_json Agent "$S9" "subagent_type=code-reviewer" "description=T-93 code-reviewer" "prompt=go" @hook_event_name=PreToolUse | bash "$JOURNAL"
mkdir -p "$(rd T-93)"
out="$(run Write "$S9" "file_path=$(rd T-93)/1.md" "content=$(review_text T-93 REQUEST_CHANGES)" "${REV[@]}")"
expect_allow "round 1 of T-93 goes through the gate (the ledger now exists)" "$out"
review_text T-93 REQUEST_CHANGES > "$(rd T-93)/1.md"; S="$S9" landed "$(rd T-93)/1.md" "${REV[@]}"
review_text T-93 APPROVE | sed 's/^round: 1$/round: 2/' > "$(rd T-93)/2.md"
python3 - "$HOOKS" "$P" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import _hookio as io
rel = "docs/tasks/T-93.reviews/2.md"; text = open(sys.argv[2] + "/" + rel).read()
io.write_stamp(sys.argv[2], rel, dict(session_id="sess-9", agent_id="a-x", agent_type="code-reviewer",
                                      gate="review", verdict="APPROVE", spawned=True), text)
PY
out="$(run Edit "$S9-next" "file_path=$(tf T-93)" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_deny "a stamp made by a script does not count where the task's ledger exists" "$out" "not written by a code-reviewer"
out="$(run Bash "$S9" "command=echo '{}' | bash scripts/hooks/review-gate.sh")"
expect_deny "piping a payload into a gate is refused" "$out" "scripts/hooks"
out="$(run Bash "$S9" "command=cd scripts/hooks && python3 -c 'import _hookio'")"
expect_deny "importing the hook helpers in a one-liner is refused" "$out" "scripts/hooks"
out="$(run Bash "$S9" "command=cat scripts/hooks/review-gate.sh")"
expect_allow "reading a hook is fine" "$out"
for c in "cd docs/tasks && cp T-90.reviews/1.md T-90.reviews/1.gate.json T-94.reviews/" \
         "cd docs/tasks/T-94.reviews && printf '{}' > 1.gate.json" \
         "git checkout HEAD~1 -- docs/tasks/T-94.reviews/1.md" \
         "rsync -a /tmp/copy/ docs/tasks/T-94.reviews/" \
         "dd if=/tmp/a of=docs/tasks/T-94.verify/1.gate.json" \
         "python3 -c \"open('docs/tasks/T-94.reviews/1.md','w').write('x')\"" \
         "perl -e 'open(F, \">docs/tasks/T-94.validation/1.md\")'" \
         "cp -r /tmp/T-94.reviews docs/tasks/"; do
  out="$(run Bash "$S9" "command=$c")"
  expect_deny "shell write into a record directory is refused: $c" "$out" "never by shell"
done
for c in "cd docs/tasks && cat T-90.reviews/1.md" "git add docs/tasks/T-90.reviews" "ls docs/tasks/T-90.reviews"; do
  out="$(run Bash "$S9" "command=$c")"; expect_allow "reading or staging records is fine: $c" "$out"
done

# minor: a review write the gate allowed but that never landed leaves no stamp or ledger line
task_file "$(tf T-95)" T-95 NEEDS_REVIEW bug full
out="$(run Write "$S9" "file_path=$(rd T-95)/1.md" "content=$(review_text T-95 APPROVE)" "${REV[@]}")"
expect_allow "the gate lets the review through (then the write is refused elsewhere)" "$out"
[ ! -e "$(rd T-95)/1.gate.json" ] && [ ! -e "$P/.teamwright/sessions/T-95.reviews.jsonl" ] \
  && ok "no stamp and no ledger line before the write lands" || bad "no stamp and no ledger line before the write lands"
mkdir -p "$(rd T-95)"; { review_text T-95 APPROVE; echo "changed after the check"; } > "$(rd T-95)/1.md"
S="$S9" landed "$(rd T-95)/1.md" "${REV[@]}"
[ ! -e "$(rd T-95)/1.gate.json" ] && ok "a landed file that differs from what the gate checked gets no stamp" \
  || bad "a landed file that differs from what the gate checked gets no stamp"

# minor: a review approved before 0.12 (no stamp) is recognised on a fresh checkout
L="$TMP/legacy"; mkdir -p "$L/docs/tasks/T-1.reviews" "$L/.teamwright"; git -C "$L" init -q -b main .
lg() { CLAUDE_PROJECT_DIR="$L" run "$@"; }
kitv() { printf '{"@kit": {"plugin": "teamwright@teamwright", "version": "%s"}}\n' "$1" > "$L/.teamwright/installed.json"; git -C "$L" add -A; git -C "$L" commit -qm "chore: kit $1"; }
kitv 0.11.0
task_file "$L/docs/tasks/T-1.md" T-1 NEEDS_REVIEW bug full; task_file "$L/docs/tasks/T-2.md" T-2 NEEDS_REVIEW bug full
review_text T-1 APPROVE > "$L/docs/tasks/T-1.reviews/1.md"; git -C "$L" add -A; git -C "$L" commit -qm "docs(review): T-1 APPROVE"
kitv 0.12.0
out="$(lg Edit s-l "file_path=$L/docs/tasks/T-1.md" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_allow "a review committed before the upgrade to 0.12, no stamp, fresh checkout: recognised" "$out"
mkdir -p "$L/docs/tasks/T-2.reviews"; review_text T-2 APPROVE > "$L/docs/tasks/T-2.reviews/1.md"; git -C "$L" add -A; git -C "$L" commit -qm "docs(review): T-2"
out="$(lg Edit s-l "file_path=$L/docs/tasks/T-2.md" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_deny "a review without a stamp committed after the upgrade: not recognised" "$out" "not written by a code-reviewer"
echo "edited" >> "$L/docs/tasks/T-1.reviews/1.md"
out="$(lg Edit s-l "file_path=$L/docs/tasks/T-1.md" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_deny "a legacy review edited in the tree: not recognised" "$out" "not written by a code-reviewer"
git -C "$L" add -A; git -C "$L" commit -qm "docs: T-1 edit"
out="$(lg Edit s-l "file_path=$L/docs/tasks/T-1.md" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_deny "a legacy review changed after the upgrade: not recognised" "$out" "not written by a code-reviewer"
N="$TMP/new012"; mkdir -p "$N/docs/tasks/T-1.reviews" "$N/.teamwright"; git -C "$N" init -q -b main .
task_file "$N/docs/tasks/T-1.md" T-1 NEEDS_REVIEW bug full; review_text T-1 APPROVE > "$N/docs/tasks/T-1.reviews/1.md"
git -C "$N" add -A; git -C "$N" commit -qm "pre-existing review"
printf '{"@kit": {"plugin": "teamwright@teamwright", "version": "0.12.0"}}\n' > "$N/.teamwright/installed.json"; git -C "$N" add -A; git -C "$N" commit -qm "chore: install 0.12.0"
out="$(CLAUDE_PROJECT_DIR="$N" run Edit s-l "file_path=$N/docs/tasks/T-1.md" "old_string=status: NEEDS_REVIEW" "new_string=status: CODE_COMPLETE")"
expect_deny "installed at 0.12 from the start: a record without a stamp is never legacy" "$out" "not written by a code-reviewer"

# ---- m3: records created outside Edit/Write still count, at the reviewed task's status move ----
G="$TMP/gproj"; mkdir -p "$G/docs/tasks"; git -C "$G" init -q -b main .
task_file "$G/docs/tasks/T-1.md" T-1 NEEDS_REVIEW bug full; git -C "$G" add -A; git -C "$G" commit -qm "chore(task): T-1"
gr() { CLAUDE_PROJECT_DIR="$G" run "$@"; }
CLAUDE_PROJECT_DIR="$G" hook_json Agent s8 "subagent_type=code-reviewer" "description=T-1 code-reviewer" "prompt=go" @hook_event_name=PreToolUse | CLAUDE_PROJECT_DIR="$G" bash "$JOURNAL"
printf -- '---\nid: T-2\n---\n' > "$G/docs/tasks/T-2.md"; printf -- '---\nid: T-3\n---\n' > "$G/docs/tasks/T-3.md"
out="$(gr Edit s8 "file_path=$G/docs/tasks/T-1.md" "old_string=status: NEEDS_REVIEW" "new_string=status: IN_PROGRESS")"
expect_allow "two records made by the shell during the review: within the limit" "$out"
printf -- '---\nid: T-4\n---\n' > "$G/docs/tasks/T-4.md"
out="$(gr Edit s8 "file_path=$G/docs/tasks/T-1.md" "old_string=status: NEEDS_REVIEW" "new_string=status: IN_PROGRESS")"
expect_deny "a third record made outside Edit/Write is counted at the status move" "$out" "created 3 new task records (T-2, T-3, T-4)"
git -C "$G" add -A; git -C "$G" commit -qm "chore(task): follow-ups"
out="$(gr Edit s8 "file_path=$G/docs/tasks/T-1.md" "old_string=status: NEEDS_REVIEW" "new_string=status: IN_PROGRESS")"
expect_deny "committed since the reviewer spawn: still counted" "$out" "created 3 new task records"
out="$(gr Edit s9 "file_path=$G/docs/tasks/T-1.md" "old_string=status: NEEDS_REVIEW" "new_string=status: IN_PROGRESS")"
expect_allow "another session without a review window: not counted" "$out"

finish
