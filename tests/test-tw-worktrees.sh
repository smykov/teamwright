#!/usr/bin/env bash
# Regression (#12): tasks worked in nested git worktrees on their own branches (task/<ID>,
# not only tw/<ID>) - the router and the progress report read the task's record from that
# worktree, the main tree skips it and offers merge when it is approved, a session in the
# worktree sees its own task only; $TEAMWRIGHT_TASK_BRANCH_RE overrides the branch pattern.
. "$(dirname "$0")/lib.sh"
echo "tw-worktrees"
NEXT="$KIT/scripts/tw-next.py"; PROG="$KIT/scripts/tw-progress.py"
mk() {  # mk ID STATUS [SEAM]
  { printf -- '---\nid: %s\ntitle: task %s\ntype: feature\nstatus: %s\npriority: P2\ndepends_on: []\nsurface: api\n' "$1" "$1" "$2"
    if [ -n "${3:-}" ]; then
      printf 'analysis:\n  root_cause: need\n  evidence: FR-01\n  invariant: holds\n  seam: "%s"\n  approach: do it\n' "$3"
    fi
    printf -- '---\nbody\n'; } > "docs/tasks/$1.md"
}
p="$TMP/proj"; mkdir -p "$p/.teamwright" "$p/docs/tasks"; cd "$p" || exit 1
git init -q -b main .
printf '.teamwright/logs/\n.teamwright/current-task\n.worktrees/\n' > .gitignore
printf 'version: 1\nmode: gate-first\nareas:\n  - name: ui\n    source_dirs: [web]\n  - name: core\n    source_dirs: [core]\n' > .teamwright/config.yml
mk T-6 TODO; mk T-7 TODO; mk T-8 TODO
git add -A; git commit -qm init

# T-6 is worked in a nested worktree on task/T-6-<slug>; its analysis exists only there
git worktree add -q -b task/T-6-parser .worktrees/T-6 HEAD
WT="$p/.worktrees/T-6"
( cd "$WT" && mk T-6 IN_PROGRESS "core/parse.py" && git add -A && git commit -qm "chore(task): T-6 TODO→IN_PROGRESS" )

nj() { python3 "$NEXT" --project "${1:-.}" --json; }
q() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
expect_rc "the main tree reads T-6's status from its worktree" "IN_PROGRESS" \
  "$(nj | q 'next(t["status"] for t in d["tasks"] if t["id"]=="T-6")')"
expect_rc "the task is marked in_worktree" "$(cd "$WT" && pwd -P)" \
  "$(nj | q 'next(t.get("in_worktree","") for t in d["tasks"] if t["id"]=="T-6")' | xargs -I{} sh -c 'cd "{}" && pwd -P')"
nj | q '" ".join("%s %s" % (x["action"], x["task"]) for x in [d]+d["alternatives"])' | grep -q "T-6" \
  && bad "the main tree does not offer T-6 (it runs in its worktree)" \
  || ok "the main tree does not offer T-6 (it runs in its worktree)"
expect_rc "the session in the worktree works its own task only" "continue T-6" "$(nj "$WT" | q 'd["action"]+" "+d["task"]')"
python3 "$NEXT" --project . | grep -q "in worktrees: T-6 IN_PROGRESS (task/T-6-parser)" \
  && ok "human output lists the worktree" || bad "human output lists the worktree" "$(python3 "$NEXT" --project .)"

# progress: the area comes from the seam in the worktree's record, not "unassigned"
expect_rc "progress takes the area from the worktree's analysis" "core" \
  "$(python3 "$PROG" --project . --json | q 'next(a["area"] for a in d["by_area"] if a.get("total",0) and a["area"]=="core")' 2>/dev/null)"
expect_rc "progress: T-6 is not unassigned" "" \
  "$(python3 "$PROG" --project . --json | q '" ".join(u["task"] for u in d["unassigned"] if u["task"]=="T-6")')"

# approved in the worktree -> the main tree offers merge, naming the branch and the path
( cd "$WT" && sedi 's/^status: .*/status: CODE_COMPLETE/' docs/tasks/T-6.md && git commit -qam "chore(task): T-6 →CODE_COMPLETE" )
m="$(nj | q 'next(("%s %s | %s" % (x["action"], x["task"], x["reason"]) for x in [d]+d["alternatives"] if x["action"]=="merge"), "none")')"
case "$m" in "merge T-6 | "*"task/T-6-parser"*".worktrees/T-6"*) ok "approved in its worktree: merge offered" ;;
  *) bad "approved in its worktree: merge offered" "$m" ;; esac

# another pattern: not recognised by default, recognised with TEAMWRIGHT_TASK_BRANCH_RE
git worktree add -q -b feature/T-7 .worktrees/T-7 HEAD
( cd "$p/.worktrees/T-7" && mk T-7 IN_PROGRESS "web/app.ts" && git add -A && git commit -qm "chore(task): T-7 TODO→IN_PROGRESS" )
expect_rc "feature/<ID> is not a task branch by default" "TODO" \
  "$(nj | q 'next(t["status"] for t in d["tasks"] if t["id"]=="T-7")')"
expect_rc "TEAMWRIGHT_TASK_BRANCH_RE overrides the pattern" "IN_PROGRESS" \
  "$(TEAMWRIGHT_TASK_BRANCH_RE='^feature/(T-[0-9]+)$' nj | q 'next(t["status"] for t in d["tasks"] if t["id"]=="T-7")')"

# the id ends at a separator: a worktree on task/T-80 is not T-8's
git worktree add -q -b task/T-80 .worktrees/T-80 HEAD
( cd "$p/.worktrees/T-80" && mk T-8 IN_PROGRESS "web/x.ts" && git add -A && git commit -qm "chore(task): T-8 edited on T-80" )
expect_rc "task/T-80 is not a branch of T-8" "TODO" \
  "$(nj | q 'next(t["status"] for t in d["tasks"] if t["id"]=="T-8")')"
finish
