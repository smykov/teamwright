#!/usr/bin/env bash
# Regression: scripts/tw-test runs an area's test command for the chosen tests once, keeps
# the full output in a log, prints a short summary and answers a repeat from its cache.
. "$(dirname "$0")/lib.sh"
echo "tw-test"
P="$TMP/proj"; mkdir -p "$P/.teamwright" "$P/scripts" "$P/srv/src" "$P/srv/tests" "$P/fx" "$P/docs"
cp -R "$HOOKS" "$P/scripts/hooks"
cp "$KIT/template/scripts/tw-run" "$KIT/template/scripts/tw-gate" "$KIT/template/scripts/tw-test" "$P/scripts/"
# a fake runner: counts its runs, prints its arguments and the workers, fails while FAIL exists
cat > "$P/srv/fake.sh" <<EOF
echo run >> "$TMP/srv.runs"
echo "workers=\${W:-unset} args=\$*"
i=0; while [ \$i -lt 40 ]; do echo noise-\$i; i=\$((i+1)); done
if [ -f FAIL ]; then
  echo "=========================== short test summary info ============================"
  echo "FAILED tests/test_a.py::test_two - AssertionError: assert 1 == 2"
  echo "ERROR tests/test_b.py::test_three - fixture 'caplog' not found"
  echo "=================== 1 failed, 5 passed, 1 error in 0.12s ==================="
  exit 1
fi
echo "============================== 6 passed in 0.10s =============================="
EOF
cat > "$P/.teamwright/config.yml" <<YML
version: 1
areas:
  - name: srv
    workdir: srv
    source_dirs: [srv/src]
    test_dirs: [srv/tests]
    test_command: "sh fake.sh all"
    test_select_command: "W=\${W:-4} sh fake.sh {tests}"
  - name: plain
    test_command: "echo plain-args"
  - name: fx
    workdir: fx
    test_command: "cat"
  - name: slow
    test_command: "echo run >> $TMP/slow.runs; sleep 2; echo done"
  - name: none
YML
cd "$P" || exit 1
printf '.teamwright/logs/\n' > .gitignore
echo s > srv/src/s.txt; echo t > srv/tests/t.txt; echo d > docs/x.md
git init -q -b main . && git add -A && git commit -qm init
tt() { bash scripts/tw-test "$@" 2>&1; }
runs() { if [ -f "$TMP/$1.runs" ]; then wc -l < "$TMP/$1.runs" | tr -d ' '; else echo 0; fi; }
L="$P/.teamwright/logs/test"

out="$(tt srv tests/test_a.py "tests/x y.py")"; rc=$?
expect_rc "PASS: exit 0" 0 "$rc"
expect_rc "ran once" 1 "$(runs srv)"
printf '%s' "$out" | grep -q "^PASS srv tests/test_a.py tests/x y.py: exit 0" && ok "PASS line names area and selectors" || bad "PASS line" "$out"
printf '%s' "$out" | grep -q "^  6 passed (pytest)" && ok "pytest counts recognised" || bad "pytest counts recognised" "$out"
printf '%s' "$out" | grep -q "noise-" && bad "stdout carries only the summary" "$out" || ok "stdout carries only the summary"
log="$(printf '%s' "$out" | sed -n 's/^log: //p')"
case "$log" in "$L"/srv-*.log) ok "log under .teamwright/logs/test" ;; *) bad "log under .teamwright/logs/test" "$log" ;; esac
grep -q "noise-39" "$log" && ok "full output in the log" || bad "full output in the log"
grep -q "workers=4 args=tests/test_a.py tests/x y.py" "$log" && ok "test_select_command: {tests} quoted, workers from the config string" \
  || bad "test_select_command" "$(grep workers "$log")"

out="$(tt srv tests/test_a.py "tests/x y.py")"; rc=$?
expect_rc "identical repeat: not run again" "0 1" "$rc $(runs srv)"
printf '%s' "$out" | grep -q "^PASS srv .*(cached: srv files, command and selectors unchanged since the run at commit" && ok "cached summary says so" || bad "cached summary" "$out"
printf '%s' "$out" | grep -q "^log: $log" && ok "cached summary gives the log" || bad "cached summary gives the log" "$out"
tt srv tests/test_b.py >/dev/null; expect_rc "other selectors: run" 2 "$(runs srv)"
tt srv tests/test_a.py "tests/x y.py" --fresh >/dev/null; expect_rc "--fresh: run again" 3 "$(runs srv)"
echo more >> docs/x.md; git commit -qam docs
tt srv tests/test_b.py >/dev/null; expect_rc "a commit outside the area's files: cached" 3 "$(runs srv)"
echo s2 > srv/src/s.txt
tt srv tests/test_b.py >/dev/null; expect_rc "the area's source changed: run" 4 "$(runs srv)"

touch srv/FAIL
out="$(tt srv)"; rc=$?
expect_rc "FAIL: the command's exit code" 1 "$rc"
grep -q "args=all" "$(printf '%s' "$out" | sed -n 's/^log: //p')" && ok "no selectors: test_command as written" || bad "no selectors: test_command"
printf '%s' "$out" | grep -q "^FAIL srv: exit 1" && ok "FAIL line" || bad "FAIL line" "$out"
printf '%s' "$out" | grep -q "^  1 failed, 5 passed, 1 error (pytest)" && ok "FAIL counts" || bad "FAIL counts" "$out"
printf '%s' "$out" | grep -q "^  tests/test_a.py::test_two - AssertionError: assert 1 == 2" && ok "failed test with its first error line" || bad "failed test with its error" "$out"
printf '%s' "$out" | grep -q "^  tests/test_b.py::test_three (error) - fixture 'caplog' not found" && ok "errors listed too" || bad "errors listed" "$out"
n="$(runs srv)"
out="$(tt srv)"; rc=$?
expect_rc "a FAIL is cached too: not run again, same exit" "1 $n" "$rc $(runs srv)"
printf '%s' "$out" | grep -q "^FAIL srv: .*(cached:" && ok "cached FAIL says so" || bad "cached FAIL" "$out"
tt srv --fresh >/dev/null; expect_rc "--fresh reruns a FAIL" $((n + 1)) "$(runs srv)"
rm srv/FAIL

out="$(tt plain a/b.py -k "x or y")"
grep -q "plain-args a/b.py -k 'x or y'" "$(printf '%s' "$out" | sed -n 's/^log: //p')" && ok "no test_select_command: selectors appended, quoted" || bad "selectors appended" "$out"
printf '%s' "$out" | grep -q "^last 1 lines:" && ok "unrecognised output: the tail" || bad "unrecognised output: the tail" "$out"

tt none >/dev/null; expect_rc "area without a test command: exit 2" 2 "$?"
tt nope >/dev/null; expect_rc "unknown area: exit 2" 2 "$?"
tt >/dev/null; expect_rc "no area: exit 2" 2 "$?"

# ---- parsers: the output of other runners, fed through `cat` ----
parse() { tt fx "$1" --fresh; }
cat > fx/cargo.txt <<'EOF'
running 3 tests
test a::ok_one ... ok
test a::bad_two ... FAILED
test a::bad_three ... FAILED

failures:

---- a::bad_two stdout ----
thread 'a::bad_two' panicked at src/a.rs:5:9:
assertion `left == right` failed

---- a::bad_three stdout ----
called `Result::unwrap()` on an `Err` value: Io

test result: FAILED. 1 passed; 2 failed; 0 ignored; 0 measured; 0 filtered out
test result: ok. 4 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out
EOF
out="$(parse cargo.txt)"
printf '%s' "$out" | grep -q "^  2 failed, 5 passed, 1 ignored (cargo test)" && ok "cargo: counts summed" || bad "cargo counts" "$out"
printf '%s' "$out" | grep -q "^  a::bad_two - thread 'a::bad_two' panicked at src/a.rs:5:9: assertion" && ok "cargo: failed test and panic" || bad "cargo failed" "$out"
cat > fx/flutter.txt <<'EOF'
00:01 +0: loading test/a_test.dart
00:02 +3: test/a_test.dart: parses header
00:02 +3 -1: test/a_test.dart: rejects empty [E]
  Expected: <400>
    Actual: <200>
00:03 +5 ~1 -1: Some tests failed.
EOF
out="$(parse flutter.txt)"
printf '%s' "$out" | grep -q "^  1 failed, 5 passed, 1 skipped (flutter/dart test)" && ok "flutter: counts" || bad "flutter counts" "$out"
printf '%s' "$out" | grep -q "^  test/a_test.dart: rejects empty - Expected: <400>" && ok "flutter: failed test and error" || bad "flutter failed" "$out"
cat > fx/jest.txt <<'EOF'
FAIL src/a.test.js
  ● parser › rejects empty

    expect(received).toBe(expected) // Object.is equality

Tests:       1 failed, 9 passed, 10 total
EOF
out="$(parse jest.txt)"
printf '%s' "$out" | grep -q "^  1 failed, 9 passed, 10 total (jest)" && ok "jest: counts" || bad "jest counts" "$out"
printf '%s' "$out" | grep -q "^  parser › rejects empty - expect(received)" && ok "jest: failed test and error" || bad "jest failed" "$out"
cat > fx/vitest.txt <<'EOF'
 FAIL  src/a.test.ts > parser > rejects empty
AssertionError: expected 200 to be 400

 Test Files  1 failed (1)
      Tests  1 failed | 4 passed (5)
EOF
out="$(parse vitest.txt)"
printf '%s' "$out" | grep -q "^  1 failed | 4 passed (5) (vitest)" && ok "vitest: counts" || bad "vitest counts" "$out"
printf '%s' "$out" | grep -q "^  src/a.test.ts > parser > rejects empty - AssertionError" && ok "vitest: failed test and error" || bad "vitest failed" "$out"
cat > fx/go.txt <<'EOF'
--- FAIL: TestParse (0.00s)
    parse_test.go:12: got 200, want 400
FAIL
FAIL	example.com/p	0.01s
ok  	example.com/q	0.02s
EOF
out="$(parse go.txt)"
printf '%s' "$out" | grep -q "^  1 failed, 1 packages failed, 1 packages ok (go test)" && ok "go: counts" || bad "go counts" "$out"
printf '%s' "$out" | grep -q "^  TestParse - parse_test.go:12: got 200, want 400" && ok "go: failed test and error" || bad "go failed" "$out"
i=0; : > fx/many.txt
while [ $i -lt 40 ]; do echo "FAILED tests/t.py::test_$i - boom $i" >> fx/many.txt; i=$((i+1)); done
echo "40 failed in 1.00s" >> fx/many.txt
out="$(parse many.txt)"
expect_rc "at most 30 failed tests listed" 30 "$(printf '%s\n' "$out" | grep -c "^  tests/t.py::test_")"
printf '%s' "$out" | grep -q "and 10 more (in the log)" && ok "the rest counted" || bad "the rest counted" "$out"

# ---- a throwaway copy ----
C="$TMP/copy"; git worktree add -q --detach "$C/tree" HEAD
printf 'echo copy=yes\necho 6 passed in 0.1s\n' > "$C/tree/srv/fake.sh"
out="$(tt srv --tree "$C/tree" tests/test_a.py)"; rc=$?
lg="$(printf '%s' "$out" | sed -n 's/^log: //p')"
expect_rc "--tree: runs in the copy" "0 yes" "$rc $(grep -c 'copy=yes' "$lg" | sed 's/^1$/yes/')"
case "$lg" in "$L"/*) ok "--tree: log in the project" ;; *) bad "--tree: log in the project" "$lg" ;; esac
git worktree remove --force "$C/tree"

# ---- detached run, bounded wait ----
out="$(TW_WAIT_SECONDS=0 tt slow)"; rc=$?
expect_rc "over the wait budget: exit 75" 75 "$rc"
printf '%s' "$out" | grep -q "^RUNNING: tests slow (pid [0-9]*), started .*, log .* run the same command again" && ok "RUNNING line" || bad "RUNNING line" "$out"
out="$(TW_WAIT_SECONDS=30 tt slow)"; rc=$?
expect_rc "the same command attaches and gets the result" "0 1" "$rc $(runs slow)"
printf '%s' "$out" | grep -q "attached to the running tests of slow" && ok "attached" || bad "attached" "$out"
TW_WAIT_SECONDS=0 tt slow --fresh >/dev/null
out="$(tt --stop slow)"
printf '%s' "$out" | grep -q "stopped the tests of slow" && ok "--stop ends a run" || bad "--stop" "$out"
expect_rc "--stop with nothing running" "tw-test: no running tests of slow" "$(tt --stop slow)"
finish
