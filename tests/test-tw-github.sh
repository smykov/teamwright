#!/usr/bin/env bash
# Regression: scripts/tw-github.py and what progress and blockers show of it - the state of
# each Issue in the autonomous queue, and "not checked" instead of an empty queue.
. "$(dirname "$0")/lib.sh"
echo "tw-github"
GH="$KIT/scripts/tw-github.py"
p="$TMP/proj"; mkdir -p "$p/docs/tasks" "$TMP/bin"; cd "$p" || exit 1
git init -q -b main .
git remote add origin https://github.com/acme/widget.git
for id in T-1 T-2 T-3 T-4 T-5 T-6 T-7; do
  printf -- '---\nid: %s\ntitle: task %s\ntype: feature\nstatus: TODO\npriority: P2\ndeploys: false\nsurface: none\ndepends_on: []\n---\nbody\n' "$id" "$id" > "docs/tasks/$id.md"
done
git add -A; git -c user.name=t -c user.email=t@t commit -qm init
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
[ -n "${GH_FAIL:-}" ] && { echo "$GH_FAIL" >&2; exit 1; }
case "$1" in
  issue) cat <<'J'
[{"number":1,"title":"T-1: queued","labels":[{"name":"teamwright"}],"url":"u1","comments":[]},
 {"number":2,"title":"T-2: running","labels":[{"name":"teamwright"},{"name":"tw:implement"}],"url":"u2","comments":[]},
 {"number":3,"title":"T-3: died","labels":[{"name":"teamwright"},{"name":"tw:red-tests"}],"url":"u3","comments":[]},
 {"number":4,"title":"T-4: stopped","labels":[{"name":"teamwright"},{"name":"tw:stop"}],"url":"u4","comments":[{"body":"\nneeds a production API key"}]},
 {"number":5,"title":"T-5: failed","labels":[{"name":"teamwright"},{"name":"tw:failed"}],"url":"u5","comments":[]},
 {"number":6,"title":"T-6: done","labels":[{"name":"teamwright"},{"name":"tw:finish"}],"url":"u6","comments":[]},
 {"number":7,"title":"T-7: nobody took it","labels":[],"url":"u7","comments":[]},
 {"number":8,"title":"a question about T-1","labels":[],"url":"u8","comments":[]}]
J
  ;;
  run) echo '[{"status":"in_progress","displayTitle":"teamwright agent T-2 implement","url":"r"},{"status":"completed","displayTitle":"teamwright agent T-3 red-tests","url":"r"}]' ;;
  pr) echo '[{"number":9,"title":"T-6: chain done","headRefName":"task/T-6","url":"p9"},{"number":10,"title":"other","headRefName":"fix/x","url":"p10"}]' ;;
esac
SH
chmod +x "$TMP/bin/gh"
export TW_GH="$TMP/bin/gh"
q() { python3 "$GH" --project . --json | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
b() { python3 "$KIT/scripts/tw-blockers.py" --project . --json | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
pr() { python3 "$KIT/scripts/tw-progress.py" --project . --json | python3 -c "import json,sys; d=json.load(sys.stdin)['github']; print($1)"; }

expect_rc "each Issue gets its state" "queued running stalled stopped failed finished" "$(q '" ".join(i["state"] for i in d["issues"])')"
expect_rc "only task branches count as task pull requests" "T-6" "$(q '" ".join(p["task"] for p in d["pull_requests"])')"
expect_rc "an Issue named after a task without the label is reported" "T-7" "$(q '" ".join(u["task"] for u in d["unlabelled"])')"
expect_rc "the note is the comment's first non-empty line" "needs a production API key" "$(q 'd["issues"][3]["note"]')"
expect_rc "blockers list what stopped, failed, stalled and waits for a merge" "failed merge stalled stopped" "$(b '" ".join(sorted(i["kind"] for i in d["items"]))')"
expect_rc "the class of a stopped chain comes from its note" "credentials" "$(b '[i["cls"] for i in d["items"] if i["kind"]=="stopped"][0]')"
expect_rc "a queued or running chain is not a blocker" "[]" "$(b '[i["id"] for i in d["items"] if i["id"] in ("T-1","T-2")]')"
expect_rc "progress shows the queue" "6" "$(pr 'len(d["issues"])')"
python3 "$KIT/scripts/tw-progress.py" --project . | grep -q "^autonomous queue: " && ok "progress human output" || bad "progress human output"

export GH_FAIL="gh auth login"
expect_rc "no answer from gh is not an empty queue" "False gh auth login" "$(q 'str(d["checked"]) + " " + d["reason"]')"
python3 "$KIT/scripts/tw-blockers.py" --project . | grep -q "GitHub not checked: gh auth login" && ok "blockers say it was not checked" || bad "blockers say it was not checked"
unset GH_FAIL
export TW_GH="$TMP/bin/no-such-gh"
expect_rc "gh not installed" "False" "$(q 'd["checked"]')"
git remote remove origin
expect_rc "no GitHub remote: not applicable" "False" "$(q 'd["applicable"]')"
python3 "$KIT/scripts/tw-blockers.py" --project . | grep -q "GitHub not checked" && bad "no remote: nothing to report" || ok "no remote: nothing to report"
finish
