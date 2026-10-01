#!/usr/bin/env bash
# Regression: analysis-gate.sh
. "$(dirname "$0")/lib.sh"
echo "analysis-gate"
GATE="$HOOKS/analysis-gate.sh"
P="$TMP/proj"; mkdir -p "$P/docs/tasks" "$P/src"
export CLAUDE_PROJECT_DIR="$P"
T="$P/docs/tasks/T-1.md"
run() { hook_json "$@" | bash "$GATE"; }
full_new() { task_file "$TMP/x.md" T-1 IN_PROGRESS bug full; cat "$TMP/x.md"; }
none_new() { task_file "$TMP/x.md" T-1 IN_PROGRESS bug none; cat "$TMP/x.md"; }

task_file "$T" T-1 TODO bug none
out="$(run Edit s1 "file_path=$T" "old_string=status: TODO" "new_string=status: IN_PROGRESS")"
expect_deny "TODO->IN_PROGRESS without analysis is denied" "$out" "root_cause"

out="$(run Edit s1 "file_path=docs/tasks/T-1.md" "old_string=status: TODO" "new_string=status: IN_PROGRESS")"
expect_deny "relative file path is recognised" "$out"

out="$(run Write s1 "file_path=$T" "content=$(full_new)")"
expect_allow "Write with complete analysis is allowed" "$out"

out="$(run Write s1 "file_path=$T" "content=$(none_new)")"
expect_deny "placeholder analysis (...) is denied" "$out" "evidence"

task_file "$T" T-1 TODO bug trivial
out="$(run Edit s1 "file_path=$T" "old_string=status: TODO" "new_string=status: IN_PROGRESS")"
expect_allow "analysis: skipped:trivial is an accepted exit" "$out"

task_file "$T" T-1 TODO rca none
out="$(run Edit s1 "file_path=$T" "old_string=status: TODO" "new_string=status: IN_PROGRESS")"
expect_deny "type: rca is not exempt: its analysis is required" "$out" "decision"
task_file "$T" T-1 TODO rca trivial
out="$(run Edit s1 "file_path=$T" "old_string=status: TODO" "new_string=status: IN_PROGRESS")"
expect_deny "type: rca cannot use analysis: skipped:trivial" "$out" "root_cause"
task_file "$T" T-1 TODO rca rca
out="$(run Edit s1 "file_path=$T" "old_string=status: TODO" "new_string=status: IN_PROGRESS")"
expect_allow "type: rca with root_cause + evidence + decision is allowed" "$out"
task_file "$T" T-1 TODO rca full
out="$(run Edit s1 "file_path=$T" "old_string=status: TODO" "new_string=status: IN_PROGRESS")"
expect_deny "type: rca with a feature-style block (no decision) is denied" "$out" "decision"

task_file "$T" T-1 IN_PROGRESS bug none
out="$(run Edit s1 "file_path=$T" "old_string=title: sample" "new_string=title: renamed")"
expect_allow "task already IN_PROGRESS: cosmetic edit allowed" "$out"

task_file "$T" T-1 TODO bug none
out="$(run Edit s1 "file_path=$T" "old_string=status: TODO" "new_string=status: ANALYSIS")"
expect_allow "TODO->ANALYSIS is allowed" "$out"

out="$(run MultiEdit s1 "file_path=$T")"
expect_allow "MultiEdit without edits list does nothing odd" "$out"
out="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"MultiEdit","session_id":"s","tool_input":{"file_path":sys.argv[1],"edits":[{"old_string":"title: sample","new_string":"title: x"},{"old_string":"status: TODO","new_string":"status: IN_PROGRESS"}]}}))' "$T" | bash "$GATE")"
expect_deny "MultiEdit entering IN_PROGRESS is denied" "$out"

# code edits against the active task
echo "x" > "$P/src/a.txt"
out="$(run Edit s1 "file_path=$P/src/a.txt" "old_string=x" "new_string=y")"
expect_allow "code edit with no active task declared is allowed" "$out"
mkdir -p "$P/.teamwright"; echo T-1 > "$P/.teamwright/current-task"
out="$(run Edit s1 "file_path=$P/src/a.txt" "old_string=x" "new_string=y")"
expect_deny "code edit while active task is TODO is denied" "$out" "T-1"
task_file "$T" T-1 IN_PROGRESS bug full
out="$(run Edit s1 "file_path=$P/src/a.txt" "old_string=x" "new_string=y")"
expect_allow "code edit for IN_PROGRESS task with analysis is allowed" "$out"
out="$(run Edit s1 "file_path=$P/docs/notes.md" "old_string=a" "new_string=b")"
expect_allow "docs edits are never gated as code" "$out"
echo T-9 > "$P/.teamwright/current-task"
out="$(run Edit s1 "file_path=$P/src/a.txt" "old_string=x" "new_string=y")"
expect_deny "active task without a record is denied" "$out" "T-9"
rm -f "$P/.teamwright/current-task"

# rca task as the active task: code edits need its analysis too
echo T-1 > "$P/.teamwright/current-task"
task_file "$T" T-1 IN_PROGRESS rca none
out="$(run Edit s1 "file_path=$P/src/a.txt" "old_string=x" "new_string=y")"
expect_deny "code edit under an rca task without analysis is denied" "$out" "decision"
task_file "$T" T-1 IN_PROGRESS rca rca
out="$(run Edit s1 "file_path=$P/src/a.txt" "old_string=x" "new_string=y")"
expect_allow "code edit under an rca task with analysis is allowed" "$out"
rm -f "$P/.teamwright/current-task"

# the gate itself keeps .teamwright/current-task (PostToolUse = the edit landed)
post() { hook_json Edit s1 "file_path=$1" @hook_event_name=PostToolUse | bash "$GATE"; }
CT="$P/.teamwright/current-task"
task_file "$P/docs/tasks/T-7.md" T-7 IN_PROGRESS bug full
out="$(post "$P/docs/tasks/T-7.md")"
expect_allow "PostToolUse bookkeeping prints nothing" "$out"
expect_rc "entering IN_PROGRESS writes current-task" "T-7" "$(cat "$CT" 2>/dev/null)"
task_file "$P/docs/tasks/T-8.md" T-8 TODO bug full
post "$P/docs/tasks/T-8.md" >/dev/null
expect_rc "editing another task that is not IN_PROGRESS keeps current-task" "T-7" "$(cat "$CT" 2>/dev/null)"
task_file "$P/docs/tasks/T-7.md" T-7 NEEDS_REVIEW bug full
post "$P/docs/tasks/T-7.md" >/dev/null
if [ -e "$CT" ]; then bad "leaving IN_PROGRESS clears current-task"; else ok "leaving IN_PROGRESS clears current-task"; fi
task_file "$P/docs/tasks/T-7.md" T-7 IN_PROGRESS bug full
post "$P/docs/tasks/T-7.md" >/dev/null
out="$(run Edit s1 "file_path=$P/src/a.txt" "old_string=x" "new_string=y")"
expect_allow "code edit for the task made active by the gate is allowed" "$out"
task_file "$P/docs/tasks/T-7.md" T-7 DEFERRED bug full
post "$P/docs/tasks/T-7.md" >/dev/null
[ -e "$CT" ] && bad "DEFERRED clears current-task" || ok "DEFERRED clears current-task"
task_file "$P/docs/tasks/T-7.md" T-7 TODO bug none
out="$(run Edit s1 "file_path=$P/docs/tasks/T-7.md" "old_string=status: TODO" "new_string=status: IN_PROGRESS")"
[ -e "$CT" ] && bad "a denied PreToolUse transition does not set current-task" || ok "a denied PreToolUse transition does not set current-task"

# shell rewrites of status
out="$(run Bash s1 "command=sed -i 's/status: TODO/status: IN_PROGRESS/' docs/tasks/T-1.md")"
expect_deny "sed -i on a task status is denied" "$out" "Edit/Write"
out="$(run Bash s1 "command=grep status docs/tasks/T-1.md")"
expect_allow "reading task status via shell is allowed" "$out"

# fail-open
out="$(printf 'not json' | bash "$GATE")"; expect_allow "garbage input fails open" "$out"
out="$(printf '' | bash "$GATE")";         expect_allow "empty input fails open" "$out"
finish
