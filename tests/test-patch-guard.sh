#!/usr/bin/env bash
# Regression: patch-guard.sh via the commit-msg hook, in a temp git repo.
. "$(dirname "$0")/lib.sh"
echo "patch-guard / commit-msg"
new_repo "$TMP/repo"
echo ".teamwright/" >> .git/info/exclude          # project config stays out of the diffs
mkdir -p src/router src/clean src/legacy tests .teamwright
printf 'def route(x):\n    return x\n' > src/router/r.py
printf 'def ok():\n    return 1\n' > src/clean/c.py
printf 'def old():\n    return 0\n' > src/legacy/l.py
printf 'x = 1\n' > main.py; printf 'y = 1\n' > other.py
git add -A && git commit -qm "feat: initial" || exit 1
for i in 1 2; do echo "# $i" >> src/router/r.py; git commit -qam "fix(router): edge case $i"; done
OLD="$(python3 -c 'import datetime as d; print((d.datetime.now()-d.timedelta(days=200)).strftime("%Y-%m-%dT%H:%M:%S"))')"
for i in 1 2; do
  echo "# $i" >> src/legacy/l.py
  GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD" git commit -qam "fix(legacy): old edge case $i"
done
for i in 1 2; do echo "# $i" >> other.py; git commit -qam "fix: other $i"; done

commit() { git commit -q -m "$1" 2>"$TMP/err"; echo $?; }
conf() { printf '%s\n' "$@" > .teamwright/patch-guard.conf; }

# ---- defaults: warn only, literal-branch off -----------------------------------
printf 'SKIP_PATTERNS = ["a"]\n' >> src/router/r.py; git add -A
expect_rc "default mode warns (does not block) in a patched area" 0 "$(commit 'fix(router): skip one more')"
grep -q "warning - patch-like additions in an area" "$TMP/err" && ok "default warning names the patched area" \
  || bad "default warning names the patched area"
printf '    if x == "special":\n        return None\n' >> src/router/r.py; git add -A
commit 'feat: special case' >/dev/null
grep -q "patch-guard" "$TMP/err" && bad "literal-branch is off by default" || ok "literal-branch is off by default"

printf 'FORMATS = [\n    "text/plain",\n    "text/html",\n    "image/png",\n]\n' > src/router/formats.py; git add -A
commit 'feat(router): clipboard formats' >/dev/null
grep -q "patch-guard" "$TMP/err" && bad "a list in a NEW file is not a patch" || ok "a list in a NEW file is not a patch"

# ---- opt-in block ---------------------------------------------------------------
conf PG_MODE=block
printf 'IGNORE_RE = "b"\n' >> src/router/r.py; git add -A
expect_rc "PG_MODE=block blocks in an area with 2 recent fixes" 1 "$(commit 'fix(router): again')"
grep -q "BLOCKED" "$TMP/err" && ok "block message printed" || bad "block message printed"

expect_rc "Principle-Override trailer lets it through" 0 \
  "$(commit "$(printf 'fix(router): parse header\n\nPrinciple-Override: P-001 - header grammar, not failure recognition')")"

printf 'MORE_RE = "c"\n' >> src/router/r.py; git add -A
expect_rc "RCA trailer to a missing task does not override" 1 "$(commit "$(printf 'fix: again\n\nRCA: T-7')")"
task_file docs/tasks/T-8.md T-8 TODO bug full
expect_rc "RCA trailer to a non-rca task does not override" 1 "$(commit "$(printf 'fix: again\n\nRCA: T-8')")"
task_file docs/tasks/T-7.md T-7 TODO rca none
expect_rc "RCA trailer to an rca task without analysis does not override" 1 "$(commit "$(printf 'fix: again\n\nRCA: T-7')")"
grep -q "analysis incomplete" "$TMP/err" && ok "rejected RCA trailer is explained" || bad "rejected RCA trailer is explained"
task_file docs/tasks/T-7.md T-7 TODO rca rca
git add docs/tasks
expect_rc "an rca task id mentioned without the trailer does not override" 1 \
  "$(commit "$(printf 'fix: routing, see T-7 for the root cause')")"
expect_rc "RCA trailer to an rca task with filled analysis overrides" 0 \
  "$(commit "$(printf 'fix: routing root cause\n\nRCA: T-7')")"

# ---- lookback window ------------------------------------------------------------
printf 'OLD_RE = "d"\n' >> src/legacy/l.py; git add -A
expect_rc "fixes older than PG_LOOKBACK_DAYS (90) do not count" 0 "$(commit 'fix(legacy): case')"
conf PG_MODE=block PG_LOOKBACK_DAYS=0
printf 'OLDER_RE = "e"\n' >> src/legacy/l.py; git add -A
expect_rc "PG_LOOKBACK_DAYS=0 counts the whole history" 1 "$(commit 'fix(legacy): case')"
git reset -q HEAD -- src/legacy/l.py; git checkout -q -- src/legacy/l.py
conf PG_MODE=block

# ---- root files are their own area ---------------------------------------------
printf 'ROOT_RE = "f"\n' >> main.py; git add -A
expect_rc "root file: fixes in other root files do not count (area is the file, not .)" 0 "$(commit 'feat: main')"
for i in 1 2; do echo "# $i" >> main.py; git commit -qam "fix: main $i" 2>/dev/null; done
printf 'ROOT2_RE = "g"\n' >> main.py; git add -A
expect_rc "root file with its own 2 fixes is blocked" 1 "$(commit 'fix: main again')"
grep -q "area main.py" "$TMP/err" && ok "root area reported as the file" || bad "root area reported as the file"
git reset -q HEAD -- main.py; git checkout -q -- main.py

# ---- other behaviour ------------------------------------------------------------
printf 'IGNORE_LIST_RE = "c"\n' >> src/clean/c.py; git add -A
expect_rc "patch signature in a clean area only warns" 0 "$(commit 'feat: clean area')"
grep -q "warning" "$TMP/err" && ok "warning printed for clean area" || bad "warning printed for clean area"
mkdir -p kit .teamwright; printf 'IGNORE_LIST_RE = "k"\n' > kit/tool.py
printf '{"kit/tool.py": "x", "@accepted": {}}\n' > .teamwright/installed.json; git add kit/tool.py
commit 'chore: install kit' >/dev/null
grep -q "warning" "$TMP/err" && bad "files the installer wrote are not patches" "$(cat "$TMP/err")" || ok "files the installer wrote are not patches"
rm -f .teamwright/installed.json

# shellcheck disable=SC2016
conf PG_MODE=block 'PG_SIGNATURES="$PG_SIGNATURES
$PG_SIG_LITERAL_BRANCH"'
printf '    if y == "other":\n        return 2\n' >> src/router/r.py; git add -A
expect_rc "literal-branch can be enabled in project config" 1 "$(commit 'fix(router): other case')"
git reset -q HEAD -- src/router/r.py; git checkout -q -- src/router/r.py
conf PG_MODE=block

printf 'X_ALLOWLIST = ["t"]\n' > tests/test_router.py; git add -A
expect_rc "test files are excluded" 0 "$(commit 'test: fixtures')"

printf 'SKIP_RE = "z"\n' >> src/router/r.py; git add -A
PATCH_GUARD=off git commit -qm "fix: hotfix" 2>/dev/null; expect_rc "PATCH_GUARD=off bypasses" 0 "$?"

# status-commit convention note
task_file docs/tasks/T-9.md T-9 TODO bug full; git add -A; git commit -qm "chore: add T-9" 2>/dev/null
sedi 's/^status: TODO/status: IN_PROGRESS/' docs/tasks/T-9.md; git add -A
commit "update" >/dev/null
grep -q "chore(task)" "$TMP/err" && ok "status change with free-form subject gets a note" || bad "status-commit note"
task_file docs/tasks/T-10.md T-10 TODO bug full; git add -A
commit "chore(task): T-10 →TODO" >/dev/null
grep -q "preferred subject" "$TMP/err" && bad "a new task (no FROM status) gets no note" || ok "a new task (no FROM status) gets no note"
task_file docs/tasks/_task-template.md T-NNN TODO bug full; git add -A
commit "docs: task template" >/dev/null
grep -q "preferred subject" "$TMP/err" && bad "templates in docs/tasks/_*.md are not tasks" || ok "templates in docs/tasks/_*.md are not tasks"
finish
