#!/usr/bin/env bash
# Regression: verify-gate.sh (+ journal.sh logging verify records).
# A task reaches VERIFIED / DONE only with a fresh PASS record of the running system,
# of the kind its `surface` needs; records are append-only.
. "$(dirname "$0")/lib.sh"
echo "verify-gate"
GATE="$HOOKS/verify-gate.sh"
JOURNAL="$HOOKS/journal.sh"
P="$TMP/proj"; mkdir -p "$P/docs/tasks" "$P/src" "$P/reports"
export CLAUDE_PROJECT_DIR="$P"
S=sess-1
VAL=(@agent_id=a-val @agent_type=task-validator)
DEV=(@agent_id=a-dev @agent_type=developer)
OTHER=(@agent_id=a-qa @agent_type=test-writer)
run() { hook_json "$@" | bash "$GATE"; }
tf() { echo "$P/docs/tasks/$1.md"; }
vd() { echo "$P/docs/tasks/$1.verify"; }
touch "$P/reports/junit.xml"; mkdir -p "$P/playwright-report"

git -C "$P" init -q -b main .
commit() {  # commit MSG FILE : change FILE and commit it
  echo "$RANDOM" >> "$P/$2"; git -C "$P" add "$2"; git -C "$P" commit -q -m "$1"
  git -C "$P" rev-parse HEAD
}
C0="$(commit "chore: scaffold" src/base.txt)"

# vtask ID STATUS SURFACE [DEPLOYS] [EXCEPTION]
vtask() {
  cat > "$(tf "$1")" <<EOF
---
id: $1
title: sample
type: bug
status: $2
deploys: ${4:-true}
${3:+surface: $3}
verify_exception: "${5:-}"
analysis: skipped:trivial
---
## Acceptance
- [ ] Failure branch: empty header -> 400 with a field error
EOF
}
# vtext ID N KIND RESULT COMMIT [VERIFIER] [TOOL] [EVIDENCE] [FAILURE-BRANCH-LINE]
vtext() {
  printf -- '---\ntask: %s\nround: %s\nkind: %s\n%scommand: make e2e\nenvironment: staging\ncommit: %s\nresult: %s\nevidence: %s\nverifier: %s\n---\n## Scenarios checked\n- Happy path: valid header -> 200\n%s\n' \
    "$1" "$2" "$3" "${7:+tool: $7
}" "$5" "$4" "${8:-reports/junit.xml}" "${6:-task-validator}" \
    "${9-- Failure branch: empty header -> 400, checked in the access log}"
}
# wv ID N KIND RESULT COMMIT [TOOL] WHO... : ask the gate; on allow, the tool "runs"
wv() {
  local id="$1" n="$2" kind="$3" res="$4" c="$5" tool="$6"; shift 6
  local verifier=main a
  for a in "$@"; do case "$a" in @agent_type=*) verifier="${a#@agent_type=}" ;; esac; done
  local content out
  content="$(vtext "$id" "$n" "$kind" "$res" "$c" "$verifier" "$tool")"
  out="$(run Write "$S" "file_path=$(vd "$id")/$n.md" "content=$content" "$@")"
  if [ -z "$out" ]; then mkdir -p "$(vd "$id")"; printf '%s\n' "$content" > "$(vd "$id")/$n.md"; fi
  printf '%s' "$out"
}
to() {  # to ID FROM TO
  run Edit "$S" "file_path=$(tf "$1")" "old_string=status: $2" "new_string=status: $3"
}

# ---- api surface: pass, fail ------------------------------------------------------
C1="$(commit "fix(api): T-1 reject empty header" src/api.txt)"
vtask T-1 DEPLOYED api
out="$(to T-1 DEPLOYED VERIFIED)"; expect_deny "VERIFIED without a verify record is denied" "$out" "no verify record"
out="$(to T-1 DEPLOYED DONE)"; expect_deny "DONE without a verify record is denied" "$out" "no verify record"
out="$(wv T-1 1 api PASS "$C1" "" "${VAL[@]}")"; expect_allow "api PASS record on the task's commit is accepted" "$out"
hook_json Write "$S" "file_path=$(vd T-1)/1.md" @hook_event_name=PostToolUse "${VAL[@]}" | bash "$JOURNAL"
if grep -q '"event": "verify_record".*"result": "PASS".*"task": "T-1"' "$P/.teamwright/logs/verify.jsonl" 2>/dev/null; then
  ok "journal logs the verify record creation"; else bad "journal logs the verify record creation"; fi
if grep -q 'make e2e' "$P/.teamwright/logs/verify.jsonl" 2>/dev/null; then
  bad "journal does not store the command"; else ok "journal does not store the command"; fi
out="$(to T-1 DEPLOYED VERIFIED)"; expect_allow "pass: DEPLOYED -> VERIFIED with a fresh api PASS" "$out"
vtask T-1 VERIFIED api
out="$(to T-1 VERIFIED DONE)"; expect_allow "pass: VERIFIED -> DONE still fresh" "$out"

C2="$(commit "fix(api): T-2 retry on timeout" src/retry.txt)"
vtask T-2 DEPLOYED api
wv T-2 1 api FAIL "$C2" "" "${VAL[@]}" >/dev/null
out="$(to T-2 DEPLOYED VERIFIED)"; expect_deny "fail: latest FAIL record denies VERIFIED" "$out" "VERIFY_FAIL"
out="$(to T-2 DEPLOYED DONE)"; expect_deny "fail: latest FAIL record denies DONE" "$out" "VERIFY_FAIL"
out="$(to T-2 DEPLOYED VERIFY_FAIL)"; expect_allow "moving to VERIFY_FAIL is allowed" "$out"
out="$(wv T-2 2 api PASS "$C2" "" "${VAL[@]}")"; expect_allow "a re-run is the next round" "$out"
out="$(to T-2 DEPLOYED VERIFIED)"; expect_allow "later PASS round supersedes the FAIL" "$out"

# ---- append-only -------------------------------------------------------------------
out="$(run Edit "$S" "file_path=$(vd T-2)/1.md" "old_string=result: FAIL" "new_string=result: PASS" "${VAL[@]}")"
expect_deny "editing an existing round is denied" "$out" "append-only"
out="$(run Write "$S" "file_path=$(vd T-2)/2.md" "content=$(vtext T-2 2 api PASS "$C2")" "${VAL[@]}")"
expect_deny "overwriting an existing round is denied" "$out" "append-only"
out="$(run Write "$S" "file_path=$(vd T-2)/5.md" "content=$(vtext T-2 5 api PASS "$C2")" "${VAL[@]}")"
expect_deny "skipping rounds is denied" "$out" "next verify round"
out="$(run Bash "$S" "command=printf 'result: PASS' > docs/tasks/T-2.verify/3.md")"
expect_deny "shell write of a verify record is denied" "$out" "Edit/Write"
out="$(run Bash "$S" "command=sed -i s/FAIL/PASS/ docs/tasks/T-2.verify/1.md")"
expect_deny "in-place shell edit of a verify record is denied" "$out" "Edit/Write"
out="$(run Bash "$S" "command=cat docs/tasks/T-2.verify/1.md")"
expect_allow "reading verify records via shell is allowed" "$out"
sedi 's/^result: FAIL/result: PASS/' "$(vd T-2)/1.md"
sedi 's/^result: PASS/result: FAIL/' "$(vd T-2)/2.md"
sedi 's/^result: FAIL/result: PASS/' "$(vd T-2)/2.md"
sedi 's/^kind: api/kind: smoke/' "$(vd T-2)/2.md"
out="$(to T-2 DEPLOYED VERIFIED)"; expect_deny "a record changed around the gate is denied" "$out" "changed after"

# ---- record content ----------------------------------------------------------------
vtask T-9 DEPLOYED api
out="$(run Write "$S" "file_path=$(vd T-9)/1.md" "content=$(vtext T-9 1 api PASS "$C0" task-validator "" reports/junit.xml "")" "${VAL[@]}")"
expect_deny "record without a failure-branch line is denied" "$out" "Failure branch"
out="$(run Write "$S" "file_path=$(vd T-9)/1.md" "content=$(vtext T-9 1 api PASS "$C0" task-validator "" reports/missing.xml)" "${VAL[@]}")"
expect_deny "evidence path that does not exist is denied" "$out" "does not exist"
out="$(run Write "$S" "file_path=$(vd T-9)/1.md" "content=$(vtext T-9 1 api PASS "$C0" developer)" "${VAL[@]}")"
expect_deny "verifier not matching the writer is denied" "$out" "does not match"
out="$(run Write "$S" "file_path=$(vd T-9)/1.md" "content=$(vtext T-9 1 api PASS "$C0" human:alex)" "${VAL[@]}")"
expect_deny "an agent cannot write a human verifier marker" "$out" "human"
out="$(run Write "$S" "file_path=$(vd T-9)/1.md" "content=$(vtext T-9 1 api PASS deadbeef1)" "${VAL[@]}")"
expect_deny "a commit that does not resolve is denied" "$out" "does not resolve"
out="$(run Write "$S" "file_path=$(vd T-9)/1.md" "content=$(vtext T-9 1 e2e PASS "$C0")" "${VAL[@]}")"
expect_deny "unknown kind is denied" "$out" "kind"
out="$(run Write "$S" "file_path=$(vd T-9)/1.md" "content=$(vtext T-9 1 api OK "$C0")" "${VAL[@]}")"
expect_deny "result outside PASS | FAIL is denied" "$out" "result"
out="$(run Write "$S" "file_path=$(vd T-9)/1.md" "content=$(vtext T-9 1 api PASS "$C0" task-validator "" "https://ci.example.invalid/artifacts/1")" "${VAL[@]}")"
expect_allow "a CI artifact URL is accepted as evidence" "$out"

# ---- manual ------------------------------------------------------------------------
C3="$(commit "feat: T-3 printer driver" src/printer.txt)"
vtask T-3 DEPLOYED api
out="$(wv T-3 1 manual PASS "$C3" "" "${VAL[@]}")"
expect_deny "manual record without verify_exception is denied" "$out" "verify_exception"
mkdir -p "$(vd T-3)"; vtext T-3 1 manual PASS "$C3" human:alex > "$(vd T-3)/1.md"
out="$(to T-3 DEPLOYED VERIFIED)"; expect_deny "manual-only verification without an exception is denied at the transition" "$out" "verify_exception"
rm -rf "$(vd T-3)"
vtask T-3 DEPLOYED api "" "prints on paper; no driver emulator exists"
mkdir -p "$P/.teamwright/sessions"; echo "$S:a-dev" > "$P/.teamwright/sessions/T-3.dev"
out="$(wv T-3 1 manual PASS "$C3" "" "${DEV[@]}")"; expect_allow "manual record with an exception is accepted" "$out"
out="$(to T-3 DEPLOYED VERIFIED)"; expect_deny "implementer as the only manual verifier is denied" "$out" "second pair of eyes"
out="$(wv T-3 2 manual PASS "$C3" "" "${OTHER[@]}")"; expect_allow "second manual check by another agent" "$out"
out="$(to T-3 DEPLOYED VERIFIED)"; expect_allow "manual with exception, checked by a non-implementer, passes" "$out"

# ---- freshness ----------------------------------------------------------------------
C4="$(commit "fix: T-4 trim input" src/trim.txt)"
vtask T-4 DEPLOYED api
wv T-4 1 api PASS "$C4" "" "${VAL[@]}" >/dev/null
C4b="$(commit "fix: T-4 trim unicode spaces too" src/trim.txt)"
out="$(to T-4 DEPLOYED VERIFIED)"; expect_deny "stale: code changed after the verified commit" "$out" "stale"
commit "docs: T-4 note" docs/tasks/T-4.notes.md >/dev/null
wv T-4 2 api PASS "$C4b" "" "${VAL[@]}" >/dev/null
commit "feat: T-5 unrelated" src/other.txt >/dev/null
out="$(to T-4 DEPLOYED VERIFIED)"; expect_allow "fresh: later commits of other tasks or task docs do not stale it" "$out"

vtask T-6 DEPLOYED api
wv T-6 1 api PASS "$C0" "" "${VAL[@]}" >/dev/null
out="$(to T-6 DEPLOYED VERIFIED)"; expect_deny "no commit names the task: an old commit is not enough" "$out" "not HEAD"
wv T-6 2 api PASS "$(git -C "$P" rev-parse HEAD)" "" "${VAL[@]}" >/dev/null
out="$(to T-6 DEPLOYED VERIFIED)"; expect_allow "no commit names the task: a HEAD record passes" "$out"

git -C "$P" checkout -q -b side "$C0"; CS="$(commit "fix: T-7 side branch" src/side.txt)"; git -C "$P" checkout -q main
vtask T-7 DEPLOYED api
wv T-7 1 api PASS "$CS" "" "${VAL[@]}" >/dev/null
out="$(to T-7 DEPLOYED VERIFIED)"; expect_deny "verified commit outside the current history is denied" "$out" "not in the current history"

# ---- surfaces -------------------------------------------------------------------------
H="$(git -C "$P" rev-parse HEAD)"
vtask T-10 DEPLOYED ui
wv T-10 1 api PASS "$H" "" "${VAL[@]}" >/dev/null
out="$(to T-10 DEPLOYED VERIFIED)"; expect_deny "ui surface: an api record is not enough" "$out" "kind ui"
out="$(wv T-10 2 ui PASS "$H" "" "${VAL[@]}")"; expect_deny "ui record without tool is denied" "$out" "tool"
out="$(wv T-10 2 ui PASS "$H" maestro "${VAL[@]}")"; expect_allow "ui record with a mobile tool is accepted" "$out"
out="$(to T-10 DEPLOYED VERIFIED)"; expect_allow "ui surface passes with a ui record" "$out"

vtask T-11 DEPLOYED both
wv T-11 1 ui PASS "$H" playwright "${VAL[@]}" >/dev/null
out="$(to T-11 DEPLOYED VERIFIED)"; expect_deny "both: a ui record alone is not enough" "$out" "kind api"
wv T-11 2 api PASS "$H" "" "${VAL[@]}" >/dev/null
out="$(to T-11 DEPLOYED VERIFIED)"; expect_allow "both: one api and one ui record pass" "$out"
wv T-11 3 ui FAIL "$H" playwright "${VAL[@]}" >/dev/null
out="$(to T-11 DEPLOYED VERIFIED)"; expect_deny "both: a later ui FAIL denies" "$out" "VERIFY_FAIL"

vtask T-12 CODE_COMPLETE none false
out="$(to T-12 CODE_COMPLETE DONE)"; expect_allow "none + deploys false: DONE without a verify record" "$out"
vtask T-13 CODE_COMPLETE none true
out="$(to T-13 CODE_COMPLETE DONE)"; expect_deny "none + deploys true still needs a record" "$out" "no verify record"
wv T-13 1 smoke PASS "$H" "" "${VAL[@]}" >/dev/null
out="$(to T-13 CODE_COMPLETE DONE)"; expect_allow "none + deploys true: a smoke record passes" "$out"
vtask T-14 CODE_COMPLETE api false
out="$(to T-14 CODE_COMPLETE DONE)"; expect_deny "deploys false with an api surface still needs a record" "$out" "no verify record"
vtask T-15 DEPLOYED
out="$(to T-15 DEPLOYED VERIFIED)"; expect_deny "task without surface is denied" "$out" "surface"

# ---- a person's record, other events ----------------------------------------------------
vtask T-16 DEPLOYED api
mkdir -p "$(vd T-16)"; vtext T-16 1 api PASS "$H" human:alex > "$(vd T-16)/1.md"
out="$(to T-16 DEPLOYED VERIFIED)"; expect_allow "a person's committed record (verifier: human:<name>) counts" "$out"
out="$(to T-16 DEPLOYED CODE_COMPLETE)"; expect_allow "other transitions are not this gate's business" "$out"
out="$(hook_json Edit "$S" "file_path=$(tf T-16)" @hook_event_name=PostToolUse | bash "$GATE")"
expect_allow "PostToolUse events are ignored" "$out"
out="$(printf '{bad' | bash "$GATE")"; expect_allow "garbage input fails open" "$out"
finish
