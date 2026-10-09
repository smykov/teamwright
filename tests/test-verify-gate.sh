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

## Validation
EOF
}
# validate ID VERDICT WHO... : write the next acceptance verdict (validation record)
# through the gate; on allow the tool "runs". VALIDATOR_FIELD / VCOMMIT override fields.
xd() { echo "$P/docs/tasks/$1.validation"; }
validate() {
  local id="$1" v="$2" out content n; shift 2
  n=$(( $(ls "$(xd "$id")" 2>/dev/null | grep -c '^[0-9]*\.md$') + 1 ))
  content="$(printf -- '---\ntask: %s\nround: %s\nverdict: %s\ncommit: %s\nvalidator: %s\n%b---\n## Acceptance checked\n- every item against evidence\n' \
    "$id" "$n" "$v" "${VCOMMIT:-$(git -C "$P" rev-parse HEAD)}" "${VALIDATOR_FIELD:-task-validator}" "${VMETHOD:+method: $VMETHOD\n}")"
  out="$(run Write "$S" "file_path=$(xd "$id")/$n.md" "content=$content" "$@")"
  if [ -z "$out" ]; then mkdir -p "$(xd "$id")"; printf '%s\n' "$content" > "$(xd "$id")/$n.md"; fi
  printf '%s' "$out"
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
out="$(to T-1 VERIFIED DONE)"; expect_deny "VERIFIED -> DONE without an acceptance verdict is denied" "$out" "acceptance verdict PASS"
validate T-1 PASS "${VAL[@]}" >/dev/null
out="$(to T-1 VERIFIED DONE)"; expect_allow "pass: VERIFIED -> DONE still fresh, acceptance PASS" "$out"

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
out="$(to T-12 CODE_COMPLETE DONE)"; expect_deny "none + deploys false: DONE still needs the acceptance verdict" "$out" "no validation record"
out="$(validate T-12 PASS "${DEV[@]}")"; expect_deny "a developer cannot write the acceptance verdict" "$out" "written by a fresh task-validator"
out="$(validate T-12 PASS @session_id=x)"; expect_deny "the main session cannot write the acceptance verdict" "$out" "main session"
out="$(VALIDATOR_FIELD=main validate T-12 PASS "${VAL[@]}")"; expect_deny "validator field must name task-validator" "$out" "validator: task-validator"
out="$(VCOMMIT=deadbeef validate T-12 PASS "${VAL[@]}")"; expect_deny "a commit that does not resolve is denied" "$out" "does not resolve"
out="$(validate T-12 FAIL "${VAL[@]}")"; expect_allow "task-validator writes a FAIL verdict" "$out"
out="$(to T-12 CODE_COMPLETE DONE)"; expect_deny "latest verdict FAIL denies DONE" "$out" "is FAIL"
out="$(run Write "$S" "file_path=$(xd T-12)/1.md" "content=x" "${VAL[@]}")"; expect_deny "an earlier verdict cannot be rewritten" "$out" "append-only"
out="$(run Bash "$S" "command=sed -i s/FAIL/PASS/ docs/tasks/T-12.validation/1.md")"; expect_deny "shell writes to validation records are denied" "$out" "never by shell commands"
validate T-12 PASS "${VAL[@]}" >/dev/null
out="$(to T-12 CODE_COMPLETE DONE)"; expect_allow "none + deploys false: DONE with acceptance PASS, no verify record" "$out"
# two FAILs in a row: the third round is a sweep or NEEDS_OWNER (#5)
vtask T-31 CODE_COMPLETE none false
validate T-31 FAIL "${VAL[@]}" >/dev/null; validate T-31 FAIL "${VAL[@]}" >/dev/null
out="$(validate T-31 PASS "${VAL[@]}")"; expect_deny "after two FAILs a third sample is refused" "$out" "method: sweep"
out="$(VMETHOD=sample validate T-31 FAIL "${VAL[@]}")"; expect_deny "an explicit sample is refused too" "$out" "method: sweep"
out="$(VMETHOD=bogus validate T-31 PASS "${VAL[@]}")"; expect_deny "an unknown method is refused" "$out" "sample | sweep"
out="$(validate T-31 NEEDS_OWNER "${VAL[@]}")"; expect_allow "escalation to the owner is allowed" "$out"
vtask T-32 CODE_COMPLETE none false
validate T-32 FAIL "${VAL[@]}" >/dev/null; validate T-32 FAIL "${VAL[@]}" >/dev/null
out="$(VMETHOD=sweep validate T-32 PASS "${VAL[@]}")"; expect_allow "a sweep after two FAILs is accepted" "$out"
vtask T-33 CODE_COMPLETE none false
validate T-33 FAIL "${VAL[@]}" >/dev/null; validate T-33 PASS "${VAL[@]}" >/dev/null; validate T-33 FAIL "${VAL[@]}" >/dev/null
out="$(validate T-33 PASS "${VAL[@]}")"; expect_allow "FAIL, PASS, FAIL is not two in a row: a sample is fine" "$out"
vtask T-17 CODE_COMPLETE none false
mkdir -p "$(xd T-17)"; printf -- '---\ntask: T-17\nround: 1\nverdict: PASS\ncommit: %s\nvalidator: task-validator\n---\n' "$(git -C "$P" rev-parse HEAD)" > "$(xd T-17)/1.md"
out="$(to T-17 CODE_COMPLETE DONE)"; expect_deny "a PASS verdict not written through the gate does not count" "$out" "validation.jsonl"
vtask T-18 CODE_COMPLETE none false
validate T-18 PASS "${VAL[@]}" >/dev/null; validate T-18 FAIL "${VAL[@]}" >/dev/null; rm "$(xd T-18)/2.md"
out="$(to T-18 CODE_COMPLETE DONE)"; expect_deny "deleting a later FAIL does not bring back the earlier PASS" "$out" "file is gone"
vtask T-13 CODE_COMPLETE none true
out="$(to T-13 CODE_COMPLETE DONE)"; expect_deny "none + deploys true still needs a record" "$out" "no verify record"
wv T-13 1 smoke PASS "$H" "" "${VAL[@]}" >/dev/null
validate T-13 PASS "${VAL[@]}" >/dev/null
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
# every denial / warning lands in gates.jsonl (metrics: how often each gate fired)
GL="$P/.teamwright/logs/gates.jsonl"; rm -f "$GL"
vtask T-20 CODE_COMPLETE none false
to T-20 CODE_COMPLETE DONE >/dev/null
expect_rc "a denial is journaled in gates.jsonl" "verify-gate deny T-20" \
  "$(python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[-1]); print(r["gate"], r["decision"], r["reason"].split()[2])' "$GL")"
printf 'version: 1\nmode: gate-first\n' > "$P/.teamwright/config.yml"
out="$(to T-20 CODE_COMPLETE DONE)"
printf '%s' "$out" | grep -q "gate-first" && ok "gate-first: a warning, not a denial" || bad "gate-first: a warning, not a denial" "$out"
expect_rc "a warning is journaled as warn" warn \
  "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["decision"])' "$GL")"
rm -f "$P/.teamwright/config.yml"

# stale acceptance: the task's code changed after the PASS
vtask T-21 CODE_COMPLETE none false
validate T-21 PASS "${VAL[@]}" >/dev/null
commit "fix(core): T-21 rework after reopening" src/t21.txt >/dev/null
out="$(to T-21 CODE_COMPLETE DONE)"; expect_deny "an acceptance PASS older than the task's last code commit does not count" "$out" "stale"
validate T-21 PASS "${VAL[@]}" >/dev/null
out="$(to T-21 CODE_COMPLETE DONE)"; expect_allow "a new acceptance round for the current code passes" "$out"
# committing the records themselves does not make the verdict stale
vtask T-23 CODE_COMPLETE none false
validate T-23 PASS "${VAL[@]}" >/dev/null
git -C "$P" add docs/tasks >/dev/null && git -C "$P" commit -qm "docs(task): T-23 acceptance PASS"
out="$(to T-23 CODE_COMPLETE DONE)"; expect_allow "records committed after the verdict keep it fresh (no code commit names the task)" "$out"
# a decision or open question naming the task is a record, not code
vtask T-24 CODE_COMPLETE none false
validate T-24 PASS "${VAL[@]}" >/dev/null
commit "docs(decisions): #9 T-24 scope note" docs/decisions.md >/dev/null
commit "docs: OQ-3 raised by T-24" docs/open-questions.md >/dev/null
out="$(to T-24 CODE_COMPLETE DONE)"; expect_allow "a decision commit naming the task keeps the acceptance PASS fresh" "$out"
commit "docs: T-24 user guide" docs/guide.md >/dev/null
out="$(to T-24 CODE_COMPLETE DONE)"; expect_deny "other docs naming the task still count as a change" "$out" "stale"
out="$(printf '{bad' | bash "$GATE")"; expect_allow "garbage input fails open" "$out"
finish
