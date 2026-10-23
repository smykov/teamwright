#!/usr/bin/env bash
# Regression: pre-push (pause file + DRAIN rule) against a local bare remote.
. "$(dirname "$0")/lib.sh"
echo "pre-push"
git init -q --bare "$TMP/remote.git"
new_repo "$TMP/repo"
git remote add origin "$TMP/remote.git"
echo a > a.txt; git add -A; git commit -qm "chore: init"
push() { git push -q origin "${1:-main}" 2>"$TMP/err"; echo $?; }
status() { sedi "s/^status: .*/status: $2/" "docs/tasks/$1.md"; git add -A; git commit -qm "chore(task): $1 →$2" 2>/dev/null; }
code() { echo "$RANDOM" >> "src/$1"; git add -A; git commit -qm "$2" 2>/dev/null; }
mkdir -p src

expect_rc "first push (new branch, nothing pending) passes" 0 "$(push)"

# bookkeeping commits (only docs/tasks/**) belong to no task
task_file docs/tasks/T-3.md T-3 TODO bug full
git add -A; git commit -qm "chore(task): T-3 created" 2>/dev/null
expect_rc "creating a TODO task (task records only) does not block" 0 "$(push)"
mkdir -p specs/001 docs/sprints
echo "decision" >> docs/decisions.md; echo "spec" > specs/001/spec.md; echo "goal" > docs/sprints/1.md
git add -A; git commit -qm "docs(T-3): spec, sprint and decision for T-3" 2>/dev/null
expect_rc "a docs/specs-only commit naming a TODO task does not block (no tail_code needed)" 0 "$(push)"
echo "- new rule" >> PRINCIPLES.md; echo "process review" > docs/sprints/review.md
git add -A; git commit -qm "docs(process): review - T-3 raised to P2" 2>/dev/null
expect_rc "a process-review commit (PRINCIPLES.md + docs) naming a TODO task does not block (#4)" 0 "$(push)"

code a.py "feat(T-3): first cut"
expect_rc "code of a TODO task blocks the push" 1 "$(push)"
grep -q "T-3=TODO" "$TMP/err" && ok "blocked task and status are named" || bad "blocked task and status are named"
for st in ANALYSIS IN_PROGRESS NEEDS_REVIEW DEFERRED BLOCKED VERIFY_FAIL; do
  status T-3 "$st"
  expect_rc "code of a $st task blocks the push" 1 "$(push)"
done
for st in CODE_COMPLETE DEPLOYED VERIFIED DONE; do
  status T-3 "$st"
  expect_rc "code of a $st task may be pushed" 0 "$(git push -q --dry-run origin main 2>/dev/null; echo $?)"
done
expect_rc "push after approval passes" 0 "$(push)"

# code sent back after REQUEST_CHANGES (IN_PROGRESS again) must not leave
status T-3 IN_PROGRESS
code a.py "fix(T-3): address review"
expect_rc "code after a send-back (IN_PROGRESS) blocks" 1 "$(push)"
TEAMWRIGHT_ALLOW_PUSH=1 git push -q origin main 2>/dev/null; expect_rc "human override pushes" 0 "$?"

# a patch left in a DEFERRED task: blocked until the owner ratifies it
status T-3 DEFERRED
code a.py "fix(T-3): temporary workaround"
expect_rc "DEFERRED task with code in the tail blocks" 1 "$(push)"
printf 'tail_code: ratified\n' > "$TMP/tc"; sedi '/^status:/r '"$TMP/tc" docs/tasks/T-3.md
git add -A; git commit -qm "chore(task): T-3 tail_code ratified" 2>/dev/null
expect_rc "tail_code: ratified lets it through" 0 "$(push)"

# attribution: the first KNOWN task id in the message owns the commit
task_file docs/tasks/T-4.md T-4 IN_PROGRESS bug full
task_file docs/tasks/T-5.md T-5 DONE bug full
git add -A; git commit -qm "chore(task): T-4, T-5 records" 2>/dev/null
code b.py "feat(T-5): polish, prepares T-4"
expect_rc "only the first id owns the commit (T-5 DONE, T-4 mentioned)" 0 "$(push)"
code b.py "feat(T-404): unknown id first, then T-4"
expect_rc "unknown ids are skipped: the first known id (T-4) owns it" 1 "$(push)"
grep -q "T-4=IN_PROGRESS" "$TMP/err" && ok "owner after an unknown id is named" || bad "owner after an unknown id is named"
TEAMWRIGHT_ALLOW_PUSH=1 git push -q origin main 2>/dev/null
code c.py "feat: no task id at all"
expect_rc "commits without a known task id are not attributed" 0 "$(push)"
echo y >> src/c.py; sedi 's/^title: .*/title: changed/' docs/tasks/T-4.md; git add -A; git commit -qm "misc" 2>/dev/null
expect_rc "code commit that changes a task record is attributed to that task" 1 "$(push)"
TEAMWRIGHT_ALLOW_PUSH=1 git push -q origin main 2>/dev/null
# templates in docs/tasks/ are not task records: only a file named by a task id owns a commit
for t in "$KIT"/template/docs/tasks/_*-template.md; do cp "$t" docs/tasks/; done
git add -A; git commit -qm "chore: install record templates" 2>/dev/null
expect_rc "adding the record templates (docs only) does not block" 0 "$(push)"
echo z >> src/c.py; echo "# local note" >> docs/tasks/_review-template.md; echo "# note" >> docs/tasks/_task-template.md
git add -A; git commit -qm "chore: adapt templates" 2>/dev/null
expect_rc "a code commit that edits _*-template.md is not attributed to the template" 0 "$(push)"
grep -q "template" "$TMP/err" && bad "no template is named as a task" "$(cat "$TMP/err")" || ok "no template is named as a task"

# pause
touch TEAMWRIGHT_PAUSE
echo d > d.txt; git add d.txt; git commit -qm "chore: d"
expect_rc "TEAMWRIGHT_PAUSE blocks every push" 1 "$(push)"
grep -q "paused" "$TMP/err" && ok "pause message printed" || bad "pause message printed"
rm TEAMWRIGHT_PAUSE
export TEAMWRIGHT_PAUSE_FILE="$TMP/paused.flag"; touch "$TEAMWRIGHT_PAUSE_FILE"
expect_rc "custom pause file path is honoured" 1 "$(push)"
rm "$TEAMWRIGHT_PAUSE_FILE"
expect_rc "resume after removing the pause file" 0 "$(push)"

git checkout -q -b feature
code e.py "feat(T-4): on a branch"
expect_rc "new branch with code of an unapproved task is blocked" 1 "$(push feature)"
expect_rc "push to wip/* (CI only) is not a delivery: allowed with an unapproved task" 0 \
  "$(git push -q origin feature:wip/T-4 2>"$TMP/err"; echo $?)"
expect_rc "commits on a remote wip branch still count as undelivered" 1 "$(push feature)"
code e.py "feat(T-4): more"
expect_rc "an existing wip branch can be updated" 0 "$(git push -q origin feature:wip/T-4 2>/dev/null; echo $?)"
code e.py "feat(T-4): even more"
touch "$TEAMWRIGHT_PAUSE_FILE"
expect_rc "pause blocks wip pushes too" 1 "$(git push -q origin feature:wip/T-4 2>/dev/null; echo $?)"
rm "$TEAMWRIGHT_PAUSE_FILE"
git checkout -q main
git commit -q --allow-empty -m "chore(task): T-3 status [skip ci]"
expect_rc "a [skip ci] tip is not refused" 0 "$(push)"
grep -q "WARNING the pushed tip .* CI-skip marker" "$TMP/err" && ok "a [skip ci] tip is warned about" || bad "a [skip ci] tip is warned about" "$(cat "$TMP/err")"
git commit -q --allow-empty -m "chore(task): T-3 note"
push >/dev/null; grep -q "CI-skip marker" "$TMP/err" && bad "no warning without the marker" || ok "no warning without the marker"
finish
