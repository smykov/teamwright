#!/usr/bin/env bash
# tests/lib.sh — tiny assertion helpers shared by the hook regression tests.
# shellcheck disable=SC2034
set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$KIT/template/scripts/hooks"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export CLAUDE_CONFIG_DIR="$TMP/claude-config"   # never the developer's plugin registry
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset TEAMWRIGHT_TASK PATCH_GUARD TEAMWRIGHT_ALLOW_PUSH TEAMWRIGHT_PAUSE_FILE TEAMWRIGHT_LOG_DIR \
  TEAMWRIGHT_REVIEWER_AGENT TEAMWRIGHT_PUSH_STATUSES TEAMWRIGHT_DOC_PATHS_RE TEAMWRIGHT_CLAUDE_MD_MAX_KB CLAUDE_PROJECT_DIR \
  TEAMWRIGHT_GATE_MODE TEAMWRIGHT_OWNER CLAUDECODE

sedi() { local expr="$1" f="$2"; sed "$expr" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }  # portable sed -i
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1${2:+ -- $2}"; }

# hook_json TOOL SESSION key=value... -> hook JSON on stdout (PreToolUse by default).
# key=value goes into tool_input; @key=value goes to the top level, e.g.
# @agent_id=a1 @agent_type=code-reviewer @hook_event_name=PostToolUse.
hook_json() {
  python3 - "$@" <<'PY'
import json, sys
tool, sid, kv = sys.argv[1], sys.argv[2], sys.argv[3:]
ti, top = {}, {}
for item in kv:
    k, v = item.split("=", 1)
    if k.startswith("@"):
        top[k[1:]] = v
    else:
        ti[k] = (v == "true") if k == "replace_all" else v
out = {"tool_name": tool, "session_id": sid, "tool_input": ti}
out.update(top)
print(json.dumps(out))
PY
}

expect_deny() {  # desc output [needle]
  if printf '%s' "$2" | grep -q '"permissionDecision": "deny"'; then
    if [ -z "${3:-}" ] || printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "deny without '$3'"; fi
  else
    bad "$1" "expected deny, got: ${2:-<empty>}"
  fi
}
expect_allow() { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected allow, got: $2"; fi; }
expect_rc() {  # desc expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "exit $3, expected $2"; fi
}

new_repo() {  # new_repo DIR -> git repo with hooks installed from the template
  mkdir -p "$1" && cd "$1" || exit 1
  git init -q -b main .
  mkdir -p scripts docs/tasks
  cp -R "$HOOKS" scripts/hooks
  cp "$KIT/template/scripts/install-hooks.sh" scripts/
  bash scripts/install-hooks.sh >/dev/null
}

task_file() {  # task_file PATH ID STATUS [TYPE] [ANALYSIS: full|none|trivial|rca]
  local analysis
  case "${5:-full}" in
    full) analysis="analysis:
  root_cause: parser drops the last field
  evidence: src/parse.x:42, failing test parse_last_field
  invariant: every field in the header is emitted
  seam: the single tokenizer
  approach: iterate to end-of-input instead of last separator" ;;
    trivial) analysis="analysis: skipped:trivial" ;;
    rca) analysis="analysis:
  root_cause: every caller re-implements header parsing
  evidence: T-3, T-9 and T-12 patched the same split
  decision: one parser module, callers use it (docs/decisions/parsing.md)" ;;
    *) analysis="analysis:
  root_cause: ...
  evidence:" ;;
  esac
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
---
id: $2
title: sample
type: ${4:-bug}
status: $3
$analysis
review_rounds: 0
---
body
EOF
}

finish() {
  echo "  -- $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
