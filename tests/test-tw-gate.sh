#!/usr/bin/env bash
# Regression: scripts/tw-gate runs an area's gate once per state of the code, keeps the
# full output in a log, and reuses only a PASS on the same tree.
. "$(dirname "$0")/lib.sh"
echo "tw-gate"
P="$TMP/proj"; mkdir -p "$P/.teamwright" "$P/scripts" "$P/app"
cp -R "$HOOKS" "$P/scripts/hooks"
cp "$KIT/template/scripts/tw-run" "$KIT/template/scripts/tw-gate" "$P/scripts/"
# the gate counts its runs in a file outside the repository and fails while app/FAIL exists
cat > "$P/.teamwright/config.yml" <<YML
version: 1
gate_command: "echo top >> $TMP/top.runs"
areas:
  - name: app
    workdir: app
    generate_command: "echo gen >> $TMP/gen.runs"
    gate_command: "echo run >> $TMP/app.runs; i=0; while [ \$i -lt 40 ]; do echo line-\$i; i=\$((i+1)); done; test ! -f FAIL"
  - name: core
  - name: dirty
    gate_command: "echo x > app/generated.txt"
  - name: srv
    workdir: srv
    source_dirs: [srv/src]
    test_dirs: [srv/test]
    gate_command: "echo run >> $TMP/srv.runs; sh ../tools/check.sh"
  - name: slow
    gate_command: "echo run >> $TMP/slow.runs; sleep 2; test ! -f $TMP/slowfail"
YML
cd "$P" || exit 1
printf '.teamwright/logs/\n' > .gitignore
echo one > app/a.txt
mkdir -p srv/src srv/test tools docs
echo s > srv/src/s.txt; echo t > srv/test/t.txt; echo 'exit 0' > tools/check.sh; echo d > docs/x.md
git init -q -b main . && git add -A && git commit -qm init
gate() { bash scripts/tw-gate "$@" 2>&1; }
runs() { if [ -f "$TMP/$1.runs" ]; then wc -l < "$TMP/$1.runs" | tr -d ' '; else echo 0; fi; }
G="$P/.teamwright/logs/gate"

out="$(gate app)"; rc=$?
expect_rc "first run: exit 0" 0 "$rc"
expect_rc "first run: gate executed once" 1 "$(runs app)"
expect_rc "first run: generate_command executed first" 1 "$(runs gen)"
printf '%s' "$out" | grep -q "^PASS app: exit 0" && ok "PASS summary printed" || bad "PASS summary printed" "$out"
log="$(printf '%s' "$out" | sed -n 's/^log: //p')"
[ -f "$log" ] && grep -q "line-39" "$log" && ok "full output in the log file" || bad "full output in the log file" "$log"
case "$log" in "$G"/app-*.log) ok "log under .teamwright/logs/gate" ;; *) bad "log under .teamwright/logs/gate" "$log" ;; esac
R='import json,sys; r=json.load(open(sys.argv[1])); print(" ".join(str(r[k]) for k in sys.argv[2:]))'
expect_rc "record: area head clean exit" "app $(git rev-parse HEAD) True 0" "$(python3 -c "$R" "$G/app.json" area head clean exit)"
python3 -c "$R" "$G/app.json" command | grep -q "scripts/tw-run app -- 'echo gen" && ok "record: command" \
  || bad "record: command" "$(python3 -c "$R" "$G/app.json" command)"

out="$(gate app)"; rc=$?
expect_rc "same commit, clean tree: exit 0" 0 "$rc"
expect_rc "same commit, clean tree: not rerun" 1 "$(runs app)"
printf '%s' "$out" | grep -q "^PASS (cached: same commit $(git rev-parse HEAD | cut -c1-10), .*, log $log)" \
  && ok "cached PASS names commit and log" || bad "cached PASS names commit and log" "$out"
expect_rc "cached answers are journaled" 2 "$(wc -l < "$G/runs.jsonl" | tr -d ' ')"

gate app --fresh >/dev/null; expect_rc "--fresh reruns" 2 "$(runs app)"

echo two > app/a.txt
gate app >/dev/null; expect_rc "dirty tree, new content: reruns" 3 "$(runs app)"
expect_rc "record notes dirty" False "$(python3 -c "$R" "$G/app.json" clean)"
gate app >/dev/null; expect_rc "dirty tree, same content as the last PASS: reused" 3 "$(runs app)"
git commit -qam two
out="$(gate app)"; expect_rc "committed the content that passed: reused" 3 "$(runs app)"
printf '%s' "$out" | grep -q "^PASS (cached: same tree" && ok "cached from the uncommitted run says so" || bad "cached from the uncommitted run says so" "$out"
echo new > app/untracked.txt
gate app >/dev/null; expect_rc "untracked file: reruns" 4 "$(runs app)"
rm app/untracked.txt

touch app/FAIL
out="$(gate app)"; rc=$?
expect_rc "FAIL: exit code propagates" 1 "$rc"
printf '%s' "$out" | grep -q "^FAIL app: exit 1" && ok "FAIL summary" || bad "FAIL summary" "$out"
printf '%s' "$out" | grep -q "line-39" && ok "FAIL prints the tail" || bad "FAIL prints the tail" "$out"
printf '%s' "$out" | grep -q "line-5$" && bad "FAIL prints only the tail" || ok "FAIL prints only the tail"
gate app >/dev/null; expect_rc "FAIL is never reused" 6 "$(runs app)"
rm app/FAIL
gate app >/dev/null; gate app >/dev/null
expect_rc "after the fix: one run, then reused" 7 "$(runs app)"

out="$(gate core)"; rc=$?
expect_rc "area without gate_command runs the top-level gate" "0 1" "$rc $(runs top)"

out="$(gate dirty)"; rc=$?
expect_rc "gate that writes files: exit 0" 0 "$rc"
printf '%s' "$out" | grep -q "WARNING the working tree changed" && ok "tree change warned" || bad "tree change warned" "$out"
expect_rc "gate that writes files: not reusable" False "$(python3 -c "$R" "$G/dirty.json" cacheable)"
rm -f app/generated.txt

printf 'version: 1\nareas:\n  - name: app\n    gate_command: "exit 3"\n' > "$TMP/c2.yml"
TEAMWRIGHT_CONFIG="$TMP/c2.yml" gate app >/dev/null; expect_rc "other exit codes propagate" 3 "$?"
TEAMWRIGHT_LOG_DIR="$TMP/logs" TEAMWRIGHT_CONFIG="$TMP/c2.yml" gate app >/dev/null
[ -f "$TMP/logs/gate/app.json" ] && ok "TEAMWRIGHT_LOG_DIR respected" || bad "TEAMWRIGHT_LOG_DIR respected"
printf 'version: 1\nareas:\n  - name: app\n' > "$TMP/c3.yml"
TEAMWRIGHT_CONFIG="$TMP/c3.yml" gate app >/dev/null; expect_rc "no gate configured exits 2" 2 "$?"
gate nope >/dev/null; expect_rc "unknown area exits 2" 2 "$?"
gate >/dev/null; expect_rc "no area exits 2" 2 "$?"

# ---- cache key: the area's files, not the whole tree ----
gate srv >/dev/null; expect_rc "scoped area: first run" 1 "$(runs srv)"
echo more >> docs/x.md; git commit -qam "docs only"
out="$(gate srv)"; expect_rc "docs-only commit: the area's PASS is reused" 1 "$(runs srv)"
printf '%s' "$out" | grep -q "^PASS (cached: srv files unchanged since the run at commit" && ok "cached PASS says only other files changed" || bad "cached PASS says only other files changed" "$out"
echo three > app/a.txt; git commit -qam "other area"
gate srv >/dev/null; expect_rc "a commit in another area: reused" 1 "$(runs srv)"
python3 -c "$R" "$G/srv.json" scope | grep -q "srv/src" && ok "record lists the scope" || bad "record lists the scope"
echo '# v2' >> tools/check.sh; git commit -qam "gate script"
gate srv >/dev/null; expect_rc "a file the gate command names changed: reruns" 2 "$(runs srv)"
echo '{}' > package.json; git add package.json; git commit -qm "manifest"
gate srv >/dev/null; expect_rc "a root manifest changed: reruns" 3 "$(runs srv)"
echo s2 > srv/test/t.txt
gate srv >/dev/null; expect_rc "a test file changed (uncommitted): reruns" 4 "$(runs srv)"
git commit -qam "srv test"
gate srv >/dev/null; expect_rc "then committed: reused" 4 "$(runs srv)"
echo new > app/untracked2.txt
gate app >/dev/null; expect_rc "an area without dirs keeps the whole-tree key: reruns on any change" 8 "$(runs app)"
rm app/untracked2.txt

# ---- --top ----
out="$(gate --top)"; rc=$?
expect_rc "--top runs the top-level gate" "0 2" "$rc $(runs top)"
[ -f "$G/_top.json" ] && ok "--top record _top.json" || bad "--top record _top.json"
gate --top >/dev/null; expect_rc "--top: cached on the same tree" 2 "$(runs top)"

# ---- which gates a task needs ----
echo y > srv/src/y.txt; git add -A; git commit -qm "feat(srv): T-7 y"
echo z > srv/src/z.txt; git add -A; git commit -qm "feat(srv): T-70 z"
mkdir -p .github/workflows; echo ci > .github/workflows/ci.yml; git add -A; git commit -qm "ci: T-8 workflow"
echo tool > tools/other.sh; git add -A; git commit -qm "chore: T-9 tool"
mkdir -p docs/tasks; echo r > docs/tasks/T-8.md; git add -A; git commit -qm "chore(task): T-8 record"
expect_rc "--for-task: a CI-only change needs no local gate" "" "$(bash scripts/tw-gate --for-task T-8 2>/dev/null)"
gate --for-task T-8 | grep -q "no local gate needed" && ok "--for-task says why nothing" || bad "--for-task says why nothing"
expect_rc "--for-task: a file outside every area -> --top" "--top" "$(gate --for-task T-9)"
echo w > app/w.txt
expect_rc "--for-task: uncommitted changes count" "app srv" "$(gate --for-task T-7 | tr '\n' ' ' | sed 's/ $//')"
rm app/w.txt
expect_rc "--for-diff: since a base" "srv --top" "$(gate --for-diff HEAD~4 | tr '\n' ' ' | sed 's/ $//')"
echo m > app/m.txt; git add -A; git commit -qm "ci: retry step" -m "after the run of T-7 the push failed"
echo n > tools/n.sh; git add -A; git commit -qm "fix(app): T-12 n" -m "found while doing T-7"
expect_rc "--for-task: a commit that names the task only in its body is not the task's" "srv" "$(gate --for-task T-7)"
git checkout -q -b task/T-7-run
echo b > srv/src/b.txt; git add -A; git commit -qm "feat(srv): T-7 b"
expect_rc "--for-task on a task branch: only the branch's own commits" "srv" "$(gate --for-task T-7 | tr '\n' ' ' | sed 's/ $//')"
git checkout -q -
gate --for-diff nope >/dev/null; expect_rc "--for-diff: unknown base exits 2" 2 "$?"

# ---- detached run, bounded wait ----
jobdir() { find "$G/jobs" -mindepth 1 -maxdepth 1 -name "slow.*" -type d | head -1; }
wait_runs() { i=0; while [ $i -lt 100 ] && [ "$(runs slow)" -lt "$1" ]; do sleep 0.1; i=$((i+1)); done; }
wait_done() { i=0; while [ $i -lt 100 ] && ! [ -f "$(jobdir)/rc" ]; do sleep 0.1; i=$((i+1)); done; }
out="$(TW_WAIT_SECONDS=0 gate slow)"; rc=$?
expect_rc "over the wait budget: exit 75" 75 "$rc"
printf '%s' "$out" | grep -q "^RUNNING: gate slow (pid [0-9]*), started .*, log .* run the same command again" && ok "RUNNING line names pid, start and log" || bad "RUNNING line" "$out"
out="$(TW_WAIT_SECONDS=0 gate slow)"; rc=$?
expect_rc "called again: still 75" 75 "$rc"
printf '%s' "$out" | grep -q "attached to the running gate of slow" && ok "called again: attaches" || bad "called again: attaches" "$out"
out="$(TW_WAIT_SECONDS=30 gate slow)"; rc=$?
expect_rc "attached until done: the gate's exit code" 0 "$rc"
printf '%s' "$out" | grep -q "^PASS slow: exit 0" && ok "attached: normal result" || bad "attached: normal result" "$out"
expect_rc "attaching never starts a second run" 1 "$(runs slow)"
gate slow | grep -q "^PASS (cached" && ok "after a detached PASS: cached" || bad "after a detached PASS: cached"

touch "$TMP/slowfail"
TW_WAIT_SECONDS=0 gate slow --fresh >/dev/null; wait_done
out="$(gate slow)"; rc=$?
expect_rc "a FAIL nobody waited for is printed by the next call" "1 2" "$rc $(runs slow)"
printf '%s' "$out" | grep -q "^FAIL slow: exit 1" && ok "uncollected FAIL: full result" || bad "uncollected FAIL: full result" "$out"
rm -f "$TMP/slowfail"
TW_WAIT_SECONDS=30 gate slow >/dev/null; expect_rc "collected once: the next call runs again" 3 "$(runs slow)"

TW_WAIT_SECONDS=0 gate slow --fresh >/dev/null
out="$(TW_WAIT_SECONDS=30 gate slow --fresh)"; rc=$?
expect_rc "--fresh while running: attaches, no second run" "0 4" "$rc $(runs slow)"

TW_WAIT_SECONDS=0 gate slow --fresh >/dev/null
wait_runs 5; kill -9 -- "-$(cat "$(jobdir)/pid")" 2>/dev/null
out="$(TW_WAIT_SECONDS=30 gate slow --fresh)"; rc=$?
printf '%s' "$out" | grep -q "ended without a result (killed?)" && ok "a killed run is noticed" || bad "a killed run is noticed" "$out"
expect_rc "a killed run: cleaned up and run again" "0 6" "$rc $(runs slow)"

TW_WAIT_SECONDS=0 gate slow --fresh >/dev/null
echo other > other.txt
out="$(TW_WAIT_SECONDS=30 gate slow)"; rc=$?
printf '%s' "$out" | grep -q "on other content is running" && ok "other content: waits for the running one first" || bad "other content: waits first" "$out"
expect_rc "other content: then runs its own" "0 8" "$rc $(runs slow)"
rm -f other.txt

TW_WAIT_SECONDS=30 bash scripts/tw-gate slow --fresh >/dev/null 2>&1 &
caller=$!; wait_runs 9; kill "$caller" 2>/dev/null; wait "$caller" 2>/dev/null
out="$(TW_WAIT_SECONDS=30 gate slow)"; rc=$?
expect_rc "a killed caller leaves the run going; the next call gets its result" "0 9" "$rc $(runs slow)"

TW_WAIT_SECONDS=0 gate slow --fresh >/dev/null
out="$(gate --stop slow)"
printf '%s' "$out" | grep -q "stopped the gate of slow" && ok "--stop ends a running gate" || bad "--stop" "$out"
expect_rc "--stop removes the job" "" "$(jobdir)"
expect_rc "--stop with nothing running" "tw-gate: no running gate of slow" "$(gate --stop slow)"
finish
