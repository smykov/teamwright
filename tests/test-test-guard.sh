#!/usr/bin/env bash
# Regression: test-guard.sh refuses direct test and gate runs and cut test output, and
# points at scripts/tw-test / scripts/tw-gate.
. "$(dirname "$0")/lib.sh"
echo "test-guard"
GATE="$HOOKS/test-guard.sh"
P="$TMP/proj"; mkdir -p "$P/.teamwright" "$P/tool" "$P/server/tests"
export CLAUDE_PROJECT_DIR="$P"
touch "$P/tool/gate.sh" "$P/tool/wrap.sh"
cat > "$P/.teamwright/config.yml" <<'YML'
version: 1
mode: gate-first
areas:
  - name: server
    workdir: server
    test_dirs: [server/tests]
    test_command: "pytest -q"
    test_select_command: "pytest -q -n ${PYTEST_WORKERS:-4} {tests}"
    gate_command: "tool/gate.sh"
    lint_command: "ruff check ."
    api_test_command: "pytest tests/api --base-url http://localhost:8000"
  - name: app
    workdir: app
    test_command: "flutter test"
  - name: infra
    workdir: tool
    gate_command: "tool/wrap.sh sh -c 'cd tool && ruff check . && pytest -q'"
gate_command: "make check"
test_runner_patterns: ["^bin/run-specs( |$)"]
YML
run() { hook_json Bash s1 "command=$1" | bash "$GATE"; }
warned() {  # desc output needle
  if printf '%s' "$2" | grep -q '"permissionDecision"'; then bad "$1" "expected a warning, got a decision: $2"
  elif printf '%s' "$2" | grep -q "additionalContext" && printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"
  else bad "$1" "expected a warning with '$3', got: ${2:-<empty>}"; fi
}

out="$(run 'cd server && pytest -q tests/pipeline -k foo')"
expect_deny "direct pytest is refused (gate-first mode does not soften it)" "$out" "scripts/tw-test server tests/pipeline -k foo"
expect_deny "the refusal says to read the log" "$out" "Read that log"
expect_deny "python -m pytest" "$(run 'python3 -m pytest server/tests/test_a.py')" "scripts/tw-test server tests/test_a.py"
expect_deny "behind uv run" "$(run 'uv run pytest -x')" "TEST GUARD"
expect_deny "inside sh -c" "$(run "sh -c 'cd server && pytest'")" "TEST GUARD"
expect_deny "inside docker run" "$(run 'docker run --rm img pytest -q')" "TEST GUARD"
expect_deny "cargo test" "$(run 'cargo test -p core')" "TEST GUARD"
expect_deny "npm run test:unit" "$(run 'npm run test:unit')" "TEST GUARD"
expect_deny "make test" "$(run 'make -C server test')" "TEST GUARD"
expect_deny "an area's test_command names its area" "$(run 'cd app && flutter test test/a_test.dart')" "scripts/tw-test app test/a_test.dart"
expect_deny "the config's gate_command script (tool/gate.sh)" "$(run './tool/gate.sh')" "scripts/tw-gate server"
expect_deny "the gate script run by bash, output to a file" "$(run 'bash tool/gate.sh > gate.log 2>&1')" "scripts/tw-gate server"
expect_deny "the top-level gate_command" "$(run 'make check')" "scripts/tw-gate --top"
expect_deny "test_runner_patterns" "$(run 'bin/run-specs --all')" "test_runner_patterns"
expect_deny "a test command inside tw-run" "$(run "scripts/tw-run server -- 'pytest -q tests/x.py'")" "scripts/tw-test server tests/x.py"
out="$(run "scripts/tw-run server -- \"tool/gate.sh sh -c 'cd server && pytest -q -n 1 tests/pipeline 2>&1 | grep -E \\\"passed|failed\\\" | tail -15'\"")"
expect_deny "the field case: gate script + pytest + grep + tail through tw-run" "$out" "scripts/tw-gate server"
expect_deny "the field case also names the pipe" "$out" "Never pipe test output into"

expect_deny "pytest | tail" "$(run 'pytest -q 2>&1 | tail -20')" "TEST GUARD"
out="$(run 'scripts/tw-test server tests/pipeline | tail -5')"
expect_deny "a wrapper piped into tail" "$out" "do not cut test or gate output"
expect_deny "the cut refusal gives the command without the pipe" "$out" "scripts/tw-test server tests/pipeline"
expect_deny "tw-gate piped into grep" "$(run 'scripts/tw-gate server 2>&1 | grep FAIL')" "| grep"

expect_allow "tw-test" "$(run 'scripts/tw-test server tests/pipeline -k foo')"
expect_allow "tw-gate" "$(run 'scripts/tw-gate --for-task T-7')"
expect_allow "tw-mutants" "$(run 'scripts/tw-mutants server T-7 --tree "$copy/tree"')"
expect_allow "tw-test output to a file" "$(run 'scripts/tw-test server > out.txt 2>&1; cat out.txt')"
expect_allow "tw-run with lint" "$(run "scripts/tw-run server -- 'ruff check .'")"
expect_allow "tw-run with a build command" "$(run "scripts/tw-run server -- 'python -m build'")"
expect_allow "tw-run with the area's api_test_command" "$(run "scripts/tw-run server -- 'pytest tests/api --base-url http://localhost:8000'")"
expect_allow "grep on a log" "$(run 'grep -n FAILED .teamwright/logs/test/server-1.log | head')"
expect_allow "a commit message naming pytest" "$(run 'git commit -m "fix: pytest flake"')"
expect_allow "echo" "$(run 'echo pytest')"
# a gate script that only wraps another command is not itself a signature (ai-resume tool/gate.sh)
expect_allow "a wrapper gate script running a formatter" "$(run "tool/wrap.sh sh -c 'cd tool && ruff format x.py'")"
expect_allow "a wrapper gate script running a migration" "$(run "scripts/tw-run infra -- \"tool/wrap.sh sh -c 'alembic upgrade head'\"")"
expect_deny "a wrapper gate script running pytest" "$(run "tool/wrap.sh sh -c 'cd tool && pytest -q tests'")" "TEST GUARD"
expect_allow "make build" "$(run 'make build')"
expect_allow "an assignment in the command is not an escape, but plain commands pass" "$(run 'TW_TEST_GUARD=off ls')"
expect_deny "an agent's TW_TEST_GUARD=off does not switch the guard off" "$(run 'TW_TEST_GUARD=off pytest')" "TEST GUARD"

out="$(hook_json Bash s1 'command=pytest' | TW_TEST_GUARD=off bash "$GATE")"
expect_allow "TW_TEST_GUARD=off (the owner's environment) switches it off" "$out"
out="$(hook_json Bash s1 'command=pytest' | TW_TEST_GUARD=warn bash "$GATE")"
warned "TW_TEST_GUARD=warn only warns" "$out" "test guard (warn only"
printf 'process:\n  test_guard: warn\n' >> "$P/.teamwright/config.yml"
warned "process.test_guard: warn" "$(run 'pytest')" "scripts/tw-test"
out="$(hook_json Bash s1 'command=pytest' | TW_TEST_GUARD=block bash "$GATE")"
expect_deny "TW_TEST_GUARD=block wins over the config" "$out" "TEST GUARD"
sedi 's/test_guard: warn/test_guard: off/' "$P/.teamwright/config.yml"
expect_allow "process.test_guard: off" "$(run 'pytest')"
expect_allow "not Bash: ignored" "$(hook_json Edit s1 file_path=x.py old_string=a new_string=b | bash "$GATE")"
rm "$P/.teamwright/config.yml"
expect_deny "no config: built-in patterns, blocking" "$(run 'pytest')" "scripts/tw-test"
finish
