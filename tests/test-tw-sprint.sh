#!/usr/bin/env bash
# Regression: scripts/tw-sprint.py - what can go into the autonomous queue, and that the
# label is set only on request, on a candidate, with nothing left unpushed.
. "$(dirname "$0")/lib.sh"
echo "tw-sprint"
S="$KIT/scripts/tw-sprint.py"
p="$TMP/proj"; mkdir -p "$p/docs/tasks" "$TMP/bin"; cd "$p" || exit 1
git init -q -b main .
mk() {  # id status blocked_on depends_on seam acceptance
  printf -- '---\nid: %s\ntitle: task %s\ntype: bug\nstatus: %s\npriority: P2\ndeploys: false\nsurface: none\ndepends_on: [%s]\nblocked_on: "%s"\nanalysis:\n  seam: "%s"\n---\n\n## Acceptance\n- [ ] %s\n' \
    "$1" "$1" "$2" "$4" "$3" "$5" "$6" > "docs/tasks/$1.md"
}
mk T-1 TODO "" "" "app/a.py" "works"
mk T-2 TODO "" "" "app/a.py" "works"
mk T-3 TODO "" "T-1" "app/b.py" "works"
mk T-4 BLOCKED "a key" "" "" "works"
mk T-5 TODO "OQ-01" "" "" "works"
mk T-6 DONE "" "" "" "works"
mk T-7 TODO "" "" "" "checked on a real device"
mk T-8 TODO "" "" "" "queued already"
mk T-9 TODO "" "" "app/c.py" "has an Issue without the label"
printf '| ID | Q | Status |\n|---|---|---|\n| OQ-01 | q | open |\n' > docs/open-questions.md
git add -A; git -c user.name=t -c user.email=t@t commit -qm init
git update-ref refs/remotes/origin/main HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git remote add origin https://github.com/acme/widget.git
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue list")
    if [ -n "${GH_ACTIVE:-}" ]; then echo '[{"number":8,"title":"T-8: queued","labels":[{"name":"teamwright"}],"url":"u8","comments":[]},{"number":9,"title":"T-9: open","labels":[],"url":"u9","comments":[]}]'
    else echo '[{"number":9,"title":"T-9: open","labels":[],"url":"u9","comments":[]}]'; fi ;;
  "pr list") if [ -n "${GH_PR:-}" ]; then echo '[{"number":5,"title":"T-1: done","headRefName":"task/T-1","url":"p5"}]'; else echo '[]'; fi ;;
  "run list") echo '[]' ;;
  *) echo "https://github.com/acme/widget/issues/99" ;;
esac
SH
chmod +x "$TMP/bin/gh"
export TW_GH="$TMP/bin/gh" GH_LOG="$TMP/gh.log"; : > "$GH_LOG"
q() { python3 "$S" --project . --json | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
c() { q "next(x for x in d['candidates'] if x['id']=='$1')$2"; }

export GH_ACTIVE=1
expect_rc "the current sprint is reported" "True T-8" "$(q 'str(d["current_sprint"]["active"]) + " " + d["current_sprint"]["issues"][0]["task"]')"
python3 "$S" issues T-1 --start --project . >/dev/null 2>&1; rc=$?
expect_rc "an unfinished sprint refuses a new start" 3 "$rc"
python3 "$S" issues T-1 --project . >/dev/null 2>&1; rc=$?
expect_rc "an unfinished sprint refuses Issues without a label too" 3 "$rc"
grep -q "issue create\|issue edit" "$GH_LOG" && bad "nothing written while a sprint runs" "$(cat "$GH_LOG")" || ok "nothing written while a sprint runs"
: > "$GH_LOG"; python3 "$S" issues T-1 --start --add-to-current --project . >/dev/null
grep -q "issue create.*--label teamwright" "$GH_LOG" && ok "--add-to-current adds on the owner's decision" || bad "add to current" "$(cat "$GH_LOG")"
python3 "$S" --project . | grep -q "current sprint is not finished" && ok "the human output says it first" || bad "human output" ""
expect_rc "candidates: open, unblocked, not queued" "T-1 T-2 T-3 T-7 T-9" "$(q '" ".join(x["id"] for x in d["candidates"])')"
expect_rc "excluded with a reason" "T-4 T-5 T-8" "$(q '" ".join(x["id"] for x in d["excluded"])')"
expect_rc "the unanswered question is named" "blocked_on: OQ-01" "$(q 'next(x["reason"] for x in d["excluded"] if x["id"]=="T-5")')"
expect_rc "seams that share a path overlap" "['T-2']" "$(c T-1 "['overlaps']")"
expect_rc "an open dependency is shown" "['T-1']" "$(c T-3 "['waits_for']")"
expect_rc "a seam with no path is not reported as an overlap" "[]" "$(c T-7 "['overlaps']")"
c T-7 "['risks']" | grep -q "person, a device" && ok "a device in the acceptance is a risk" || bad "device risk" "$(c T-7 "['risks']")"

unset GH_ACTIVE
export GH_PR=1
python3 "$S" issues T-1 --project . >/dev/null 2>&1; rc=$?
expect_rc "an open task pull request keeps the sprint open" 3 "$rc"
unset GH_PR
: > "$GH_LOG"; python3 "$S" issues T-1 --project . >/dev/null
grep -q "issue create" "$GH_LOG" && ok "issues creates the Issue" || bad "issues create" "$(cat "$GH_LOG")"
grep -q -e "--label" -e "--add-label" "$GH_LOG" && bad "no label without --start" "$(cat "$GH_LOG")" || ok "no label without --start"
: > "$GH_LOG"; python3 "$S" issues T-1 --start --project . >/dev/null
grep -q "issue create.*--label teamwright" "$GH_LOG" && ok "--start labels a new Issue" || bad "--start new" "$(cat "$GH_LOG")"
: > "$GH_LOG"; python3 "$S" issues T-9 --start --project . >/dev/null
grep -q "issue edit 9 --add-label teamwright" "$GH_LOG" && ok "--start labels the open Issue, no duplicate" || bad "--start existing" "$(cat "$GH_LOG")"
: > "$GH_LOG"; python3 "$S" issues T-4 --start --project . >/dev/null 2>&1; rc=$?
expect_rc "an excluded task is refused" 2 "$rc"
grep -q "issue create\|issue edit" "$GH_LOG" && bad "nothing written for a refused task" "$(cat "$GH_LOG")" || ok "nothing written for a refused task"

printf x > extra; git add extra; git -c user.name=t -c user.email=t@t commit -qm local
q '" ".join(d["warnings"])' | grep -q "not on origin/main" && ok "unpushed commits warn" || bad "unpushed warn" "$(q 'd["warnings"]')"
: > "$GH_LOG"; python3 "$S" issues T-1 --start --project . >/dev/null 2>&1; rc=$?
expect_rc "--start refuses unpushed commits" 2 "$rc"

export TW_GH="$TMP/bin/no-such-gh"
python3 "$S" issues T-1 --project . >/dev/null 2>&1; rc=$?
expect_rc "without GitHub nothing is created" 2 "$rc"
q '" ".join(d["warnings"])' | grep -q "GitHub not checked" && ok "not checked is said" || bad "not checked" ""
finish
