#!/usr/bin/env bash
# Regression: template/scripts/tw-ci-changes - a CI run whose push carries only task
# records since the previous tip skips the gate; a push with code under a status commit
# (the DRAIN delivery shape) does not (#8: `[skip ci]` on status commits would skip it).
. "$(dirname "$0")/lib.sh"
echo "tw-ci-changes"
CC="$KIT/template/scripts/tw-ci-changes"
p="$TMP/proj"; mkdir -p "$p/docs/tasks" "$p/src"; cd "$p" || exit 1
git init -q -b main .
cc() { python3 "$CC" --before "$1" --after "$2" 2>/dev/null; }
echo a > src/a.py; echo "status: TODO" > docs/tasks/T-1.md; git add -A; git commit -qm init
base="$(git rev-parse HEAD)"
echo "status: NEEDS_REVIEW" > docs/tasks/T-1.md; git add -A; git commit -qm "chore(task): T-1 IN_PROGRESS→NEEDS_REVIEW"
echo "- round 1" > docs/decisions.md; git add -A; git commit -qm "docs: decision"
expect_rc "records only since the previous tip: code=false" "code=false" "$(cc "$base" HEAD)"
rec="$(git rev-parse HEAD)"
echo b >> src/a.py; git add -A; git commit -qm "fix(T-1): x"
echo "status: CODE_COMPLETE" > docs/tasks/T-1.md; git add -A; git commit -qm "chore(task): T-1 NEEDS_REVIEW→CODE_COMPLETE"
expect_rc "code under a status-commit tip (DRAIN delivery): code=true" "code=true" "$(cc "$rec" HEAD)"
expect_rc "new branch (zero sha): code=true" "code=true" "$(cc 0000000000000000000000000000000000000000 HEAD)"
expect_rc "no previous tip (first PR event): code=true" "code=true" "$(cc "" HEAD)"
expect_rc "unknown previous tip: code=true" "code=true" "$(cc 1234567890abcdef1234567890abcdef12345678 HEAD)"
git checkout -q -b side "$base"; echo c > docs/tasks/T-2.md; git add -A; git commit -qm side
expect_rc "previous tip not an ancestor (force-push): code=true" "code=true" "$(cc "$rec" HEAD)"
GITHUB_OUTPUT="$TMP/out" python3 "$CC" --before "$base" --after "$rec" >/dev/null 2>&1
expect_rc "the answer is appended to GITHUB_OUTPUT" "code=false" "$(cat "$TMP/out")"
same="$(python3 - "$KIT" <<'PY'
import importlib.machinery, importlib.util, os, re, sys
kit = sys.argv[1]
def load(name, path):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, path))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
sys.path.insert(0, os.path.join(kit, "template", "scripts", "hooks"))
import _task
cc = load("cc", os.path.join(kit, "template", "scripts", "tw-ci-changes"))
nx = load("nx", os.path.join(kit, "scripts", "tw-next.py"))
print("same" if cc.RECORDS == _task.RECORD_RE.pattern == nx.RECORD_RE.pattern else "differ")
PY
)"
expect_rc "one set of record paths: tw-ci-changes, the hooks and the router" "same" "$same"
finish
