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
YML
cd "$P" || exit 1
printf '.teamwright/logs/\n' > .gitignore
echo one > app/a.txt
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
finish
