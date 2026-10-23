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
expect_deny "no evidence yet: the exit is BLOCKED with blocked_on (lifecycle)" "$out" "BLOCKED with \`blocked_on"
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
out="$(run Bash s1 "command=printf '%s\\n' '- note: status of the build checked' >> docs/tasks/T-1.md")"
expect_allow "appending a note (>>) is allowed even if it mentions status" "$out"
out="$(run Bash s1 "command=echo '- status note' | tee -a docs/tasks/T-1.md")"
expect_allow "tee -a appends a note: allowed" "$out"
out="$(run Bash s1 "command=echo 'status: DONE' > docs/tasks/T-1.md")"
expect_deny "overwriting a task file through > is still denied" "$out" "Edit/Write"
out="$(run Bash s1 "command=echo 'status: DONE' | tee docs/tasks/T-1.md")"
expect_deny "tee without -a is still denied" "$out" "Edit/Write"
# only the write target counts (issue #2): reading a record, writing elsewhere, or
# writing text that names a record is not a status rewrite
out="$(run Bash s1 "command=grep -n 'status:' docs/tasks/T-1.md; echo done | tee /tmp/x.log")"
expect_allow "read a record, tee to another file: allowed" "$out"
out="$(run Bash s1 "command=git status --short docs/tasks/ && sed -i 's/a/b/' /tmp/notes.txt")"
expect_allow "git status on docs/tasks, sed -i on another file: allowed" "$out"
out="$(run Bash s1 "command=cat > /tmp/note.md <<'X'
the status line of docs/tasks/T-1.md
X")"
expect_allow "heredoc to another file that names a record: allowed" "$out"
out="$(run Bash s1 "command=mkdir -p docs/tasks/T-1.reviews && git status")"
expect_allow "mkdir under docs/tasks with git status: allowed" "$out"
out="$(run Bash s1 "command=sed -n '/status/p' docs/tasks/T-1.md > /tmp/s.txt")"
expect_allow "redirect of a read to another file: allowed" "$out"
out="$(run Bash s1 "command=cat > docs/tasks/T-1.md <<'X'
status: DONE
X")"
expect_deny "heredoc overwriting a record is denied" "$out" "Edit/Write"
out="$(run Bash s1 "command=cd docs/tasks && sed -i 's/status: TODO/status: DONE/' T-1.md")"
expect_deny "sed -i on a record after cd docs/tasks is denied" "$out" "Edit/Write"
out="$(run Bash s1 "command=perl -pi -e 's/status: TODO/status: DONE/' docs/tasks/T-1.md")"
expect_deny "perl -pi on a record is denied" "$out" "Edit/Write"

# ---- the documented analysis blocks pass the gate, filled exactly as written ----
# The task template (active block, and the commented rca block) and every analysis
# block in the problem-investigator's output section are filled in place (placeholders
# replaced, nothing added) and moved ANALYSIS -> IN_PROGRESS.
IFS= read -r -d '' _docs_py <<'PY' || true
import os, re, sys
kit, out = sys.argv[1], sys.argv[2]
tpl = open(os.path.join(kit, "template/docs/tasks/_task-template.md")).read()
fm, rest = tpl.split("\n---\n", 1)
rca_fm = re.sub(r"(?m)^analysis:\n(  .*\n)+", "", fm)
rca_fm = re.sub(r"(?m)^# (analysis:|  \w+: \"\")$", r"\1", rca_fm)
rca_fm = re.sub(r"(?m)^type: feature$", "type: rca", rca_fm)
cases = [("template", "bug", fm), ("template-rca", "rca", rca_fm)]
inv = open(os.path.join(kit, "template/.claude/agents/problem-investigator.md")).read()
section = inv.split("## Output", 1)[1].split("\n## ", 1)[0]
for i, block in enumerate(re.findall(r"```yaml\n(.*?)```", section, re.S)):
    typ = "rca" if "# type: rca" in block else "bug"
    cases.append(("investigator-%d" % (i + 1), typ,
                  "---\nid: T-9\ntitle: x\ntype: %s\nstatus: ANALYSIS\n%s" % (typ, block)))
for name, typ, text in cases:
    text = re.sub(r'(?m)^(  \w+: )(""|<[^>\n]*>)$', r"\1filled from the evidence", text)
    text = re.sub(r"(?m)^status: \w+", "status: ANALYSIS", text).replace("id: T-NNN", "id: T-9")
    with open(os.path.join(out, name + "." + typ), "w") as fh:
        fh.write(text.rstrip("\n") + "\n---\nbody\n")
    print(name + "." + typ)
PY
mkdir -p "$TMP/docs-blocks"
n=0
for f in $(python3 -c "$_docs_py" "$KIT" "$TMP/docs-blocks"); do
  n=$((n + 1))
  cp "$TMP/docs-blocks/$f" "$P/docs/tasks/T-9.md"
  out="$(run Edit s1 "file_path=$P/docs/tasks/T-9.md" "old_string=status: ANALYSIS" "new_string=status: IN_PROGRESS")"
  expect_allow "documented analysis block ($f) filled as written passes the gate" "$out"
done
[ "$n" -ge 4 ] && ok "found the template and investigator blocks ($n)" || bad "found the template and investigator blocks" "only $n"

# ---- 4. the stage field (0.12) ---------------------------------------------------------
staged() {  # staged STATUS [STAGE] -> T-1 with a full analysis and an optional stage line
  task_file "$T" T-1 "$1" bug full
  if [ -n "${2:-}" ]; then awk -v s="$2" '{print} /^status: /{print "stage: " s}' "$T" > "$T.tmp" && mv "$T.tmp" "$T"; fi
}
staged ANALYSIS
out="$(run Edit s1 "file_path=$T" "old_string=status: ANALYSIS" "new_string=status: IN_PROGRESS
stage: red-tests")"
expect_allow "ANALYSIS -> IN_PROGRESS with stage: red-tests is allowed" "$out"
out="$(run Edit s1 "file_path=$T" "old_string=status: ANALYSIS" "new_string=status: IN_PROGRESS
stage: implement")"
expect_deny "ANALYSIS -> IN_PROGRESS straight into stage: implement is denied" "$out" "red tests come before"
out="$(run Edit s1 "file_path=$T" "old_string=status: ANALYSIS" "new_string=status: IN_PROGRESS")"
expect_allow "ANALYSIS -> IN_PROGRESS without a stage (flow before 0.12) is allowed" "$out"
staged IN_PROGRESS red-tests
grep -q "^stage: red-tests" "$T" && ok "fixture carries the stage line" || bad "fixture carries the stage line"
out="$(run Edit s1 "file_path=$T" "old_string=stage: red-tests" "new_string=stage: implement")"
expect_allow "red-tests -> implement is allowed" "$out"
out="$(run Edit s1 "file_path=$T" "old_string=stage: red-tests" "new_string=stage: check")"
expect_deny "an unknown stage value is denied" "$out" "not a stage"
out="$(run Edit s1 "file_path=$T" "old_string=stage: red-tests" "new_string=")"
expect_deny "removing the stage of an IN_PROGRESS task is denied" "$out" "not removed"
out="$(run Edit s1 "file_path=$T" "old_string=status: IN_PROGRESS" "new_string=status: NEEDS_REVIEW")"
expect_deny "IN_PROGRESS -> NEEDS_REVIEW at stage red-tests is denied" "$out" "only the implement stage"
staged IN_PROGRESS implement
out="$(run Edit s1 "file_path=$T" "old_string=status: IN_PROGRESS" "new_string=status: NEEDS_REVIEW")"
expect_allow "IN_PROGRESS -> NEEDS_REVIEW at stage implement is allowed" "$out"
out="$(run Edit s1 "file_path=$T" "old_string=stage: implement" "new_string=stage: red-tests")"
expect_allow "implement -> red-tests (back from implement) is allowed" "$out"
staged IN_PROGRESS
out="$(run Edit s1 "file_path=$T" "old_string=status: IN_PROGRESS" "new_string=status: NEEDS_REVIEW")"
expect_allow "IN_PROGRESS -> NEEDS_REVIEW without a stage field (started before 0.12) is allowed" "$out"
staged NEEDS_REVIEW implement
out="$(run Edit s1 "file_path=$T" "old_string=status: NEEDS_REVIEW" "new_string=status: IN_PROGRESS")"
expect_allow "review send-back to IN_PROGRESS keeps stage: implement" "$out"
out="$(run Edit s1 "file_path=$T" "old_string=stage: implement" "new_string=stage: red-tests")"
expect_allow "back to red-tests from review is allowed" "$out"
out="$(run Bash s1 "command=sed -i 's/stage: red-tests/stage: implement/' docs/tasks/T-1.md")"
expect_deny "a shell rewrite of the stage is denied" "$out" "Edit/Write"
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\n' > "$TMP/gf.yml"; mkdir -p "$P/.teamwright"; cp "$TMP/gf.yml" "$P/.teamwright/config.yml"
staged IN_PROGRESS red-tests
out="$(run Edit s1 "file_path=$T" "old_string=status: IN_PROGRESS" "new_string=status: NEEDS_REVIEW")"
printf '%s' "$out" | grep -q "gate-first" && ok "gate-first: the stage gate warns" || bad "gate-first: the stage gate warns" "$out"
rm -f "$P/.teamwright/config.yml"

# fail-open
out="$(printf 'not json' | bash "$GATE")"; expect_allow "garbage input fails open" "$out"
out="$(printf '' | bash "$GATE")";         expect_allow "empty input fails open" "$out"
finish
