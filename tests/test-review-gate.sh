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
  if [ -z "$out" ]; then mkdir -p "$(rd "$id")"; printf '%s\n' "$content" > "$(rd "$id")/$n.md"; fi
  printf '%s' "$out"
}
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
rm -f "$P/.teamwright/config.yml"

finish
