#!/usr/bin/env bash
# Regression: scripts/tw-next.py - the /teamwright:flow router. One synthetic task set
# per branch of the decision order; the answer must be deterministic.
. "$(dirname "$0")/lib.sh"
echo "tw-next"
NEXT="$KIT/scripts/tw-next.py"

mk() {  # mk ID STATUS [key: value lines...]
  local id="$1" st="$2"; shift 2
  mkdir -p docs/tasks
  { echo "---"; echo "id: $id"; echo "title: task $id"; echo "type: feature"; echo "status: $st"
    echo "priority: P2"; echo "depends_on: []"; echo "deploys: true"; echo "surface: api"
    for l in "$@"; do echo "$l"; done; echo "---"; echo body; } > "docs/tasks/$id.md"
}
round() {  # round ID reviews|verify N key=value...  -> docs/tasks/ID.<kind>/N.md
  local d="docs/tasks/$1.$2" n="$3"; shift 3; mkdir -p "$d"
  { echo "---"; echo "round: $n"; for kv in "$@"; do echo "${kv%%=*}: ${kv#*=}"; done; echo "---"; } > "$d/$n.md"
}
fresh() {  # fresh NAME -> new git repo with one commit, cwd inside
  local p="$TMP/$1"; mkdir -p "$p/.teamwright"; cd "$p" || exit 1
  git init -q -b main .; echo "*.tmp" > .gitignore; printf '.teamwright/logs/\n.teamwright/current-task\n' >> .gitignore
  printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\n' > .teamwright/config.yml
  git add -A; git commit -qm init
}
commit_all() { git add -A; git commit -qm tasks; }
validated() {  # validated ID VERDICT [METHOD] : next validation record at HEAD
  local d="docs/tasks/$1.validation" n; mkdir -p "$d"; n=$(( $(find "$d" -maxdepth 1 -type f -name '*.md' | wc -l) + 1 ))
  printf -- '---\ntask: %s\nround: %s\nverdict: %s\ncommit: %s\nvalidator: task-validator\nmethod: %s\n---\n' "$1" "$n" "$2" "$(git rev-parse HEAD)" "${3:-sample}" > "$d/$n.md"
}
j() { python3 "$NEXT" --project . --json; }
field() { j | python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)"; }
expect() {  # expect DESC ACTION TASK
  local got; got="$(j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"], d["task"])')"
  expect_rc "$1" "$2 $3" "$got"
}

# ---- not adopted ----------------------------------------------------------------------
mkdir -p "$TMP/empty" && cd "$TMP/empty" || exit 1
expect "no docs/tasks: idle" idle None

# ---- 6. TODO by priority and readiness --------------------------------------------------
fresh todo
mk T-1 TODO "priority: P3"
mk T-2 TODO "priority: P1" "depends_on: [T-9]"
mk T-3 TODO "priority: P1"
mk T-4 DONE
mk T-5 TODO "priority: P0" "depends_on: [T-4]"
mk T-9 TODO "priority: P2"
commit_all
expect "ready P0 task first" start T-5
expect_rc "start asks the owner" True "$(field '["ask_owner"]')"
expect_rc "start role is the investigator" problem-investigator "$(field '["role"]')"
expect_rc "alternatives in effective priority order, unready skipped" "T-9 T-3 T-1" \
  "$(field '["alternatives"]' | python3 -c 'import ast,sys; print(" ".join(a["task"] for a in ast.literal_eval(sys.stdin.read())))')"
expect_rc "task list marks readiness" False \
  "$(j | python3 -c 'import json,sys; print([t for t in json.load(sys.stdin)["tasks"] if t["id"]=="T-2"][0]["ready"])')"

j | python3 -c 'import json,sys; d=json.load(sys.stdin); a=[x for x in d["alternatives"] if x["task"]=="T-9"][0]; assert "inherits P1 from T-2" in a["reason"], a' \
  && ok "prerequisite inherits the dependent's priority (reason says so)" || bad "prerequisite inherits the dependent's priority (reason says so)"

# ---- 5. BLOCKED on an owner decision outranks TODO ---------------------------------------
mk T-6 BLOCKED 'blocked_on: "owner decision: which payment provider"'
mk T-7 BLOCKED 'blocked_on: "waiting for the vendor sandbox"'
commit_all
expect "owner-blocked task: decide" decide T-6
j | grep -q '"T-7"' && j | python3 -c 'import json,sys; d=json.load(sys.stdin); assert all(a["task"]!="T-7" for a in d["alternatives"])' \
  && ok "externally blocked task is not routed" || bad "externally blocked task is not routed"

# ---- 4. verify / reanalyze ----------------------------------------------------------------
mk T-8 VERIFY_FAIL
commit_all
expect "VERIFY_FAIL: reanalyze" reanalyze T-8
mk T-10 CODE_COMPLETE
commit_all
expect "CODE_COMPLETE without verify: verify" verify T-10
expect_rc "verify role" task-validator "$(field '["role"]')"
round T-10 verify 1 result=FAIL; commit_all
expect "latest verify FAIL: still verify" verify T-10
round T-10 verify 2 result=PASS; commit_all
expect "PASS recorded, no acceptance verdict: verify (task-validator)" verify T-10
expect_rc "acceptance role" task-validator "$(field '["role"]')"
validated T-10 PASS; commit_all
expect "PASS recorded, acceptance PASS: continue (close)" continue T-10
mk T-10 DONE; mk T-11 CODE_COMPLETE "deploys: false" "surface: none"; commit_all
expect "deploys false, surface none, no verdict: verify (acceptance only)" verify T-11
j | grep -q "no verify record needed" && ok "acceptance-only reason" || bad "acceptance-only reason"
validated T-11 FAIL; commit_all
expect "acceptance FAIL: continue (back to IN_PROGRESS)" continue T-11
j | grep -q "back to IN_PROGRESS" && ok "FAIL reason names IN_PROGRESS" || bad "FAIL reason names IN_PROGRESS"
echo fix > fix11.txt; git add fix11.txt; git commit -qm "fix(core): T-11 address acceptance findings"
expect "after the fix the old FAIL is stale: verify again (no loop)" verify T-11
j | grep -q "method: sweep" && bad "one FAIL: no sweep demanded yet" || ok "one FAIL: no sweep demanded yet"
validated T-11 FAIL; commit_all
echo fix2 > fix11b.txt; git add fix11b.txt; git commit -qm "fix(core): T-11 second fix"
expect "after a second FAIL and fix: verify again" verify T-11
j | grep -q "failed 2 times in a row: this round is \`method: sweep\`" && ok "two FAILs in a row: the router asks for a sweep (#5)" || bad "two FAILs in a row: the router asks for a sweep (#5)" "$(j | grep reason)"
validated T-11 FAIL sweep; commit_all
echo fix3 > fix11c.txt; git add fix11c.txt; git commit -qm "fix(core): T-11 third fix"
j | grep -q "this round is \`method: sweep\`" && ok "one failing sweep: still sweep or NEEDS_OWNER" || bad "one failing sweep: still sweep or NEEDS_OWNER" "$(j | grep reason)"
validated T-11 FAIL sweep; commit_all
echo fix4 > fix11d.txt; git add fix11d.txt; git commit -qm "fix(core): T-11 fourth fix"
j | grep -q "failed in two sweep rounds: this round is NEEDS_OWNER" && ok "two failing sweeps: the router asks for NEEDS_OWNER, not a third sweep" || bad "two failing sweeps: the router asks for NEEDS_OWNER, not a third sweep" "$(j | grep reason)"
validated T-11 NEEDS_OWNER; commit_all
expect "acceptance NEEDS_OWNER: decide" decide T-11
mkdir -p docs; echo "| 1 | T-11 waits for the owner's check |" > docs/decisions.md; echo "| OQ-1 |" > docs/open-questions.md
git add docs; git commit -qm "docs(decisions): #1 T-11 waits for the owner's check"
expect "a decision naming the task is a record, not code: NEEDS_OWNER still stands" decide T-11
validated T-11 PASS; commit_all
expect "deploys false, surface none, acceptance PASS: continue (close)" continue T-11
mk T-11 DONE; mk T-20 CODE_COMPLETE "deploys: false" "surface: none"; validated T-20 PASS; commit_all
echo more > fix20.txt; git add fix20.txt; git commit -qm "feat(core): T-20 reopened and reworked"
expect "a PASS older than the task's last code commit does not close it" verify T-20
mk T-20 DONE; mk T-19 VERIFIED; commit_all
expect "VERIFIED without acceptance: verify" verify T-19
mk T-19 DONE; commit_all
mk T-11 DONE; mk T-12 DEPLOYED; commit_all
expect "DEPLOYED without verify: verify" verify T-12
mk T-12 DONE; mk T-8 DONE; commit_all

# ---- 3. review ----------------------------------------------------------------------------
mk T-13 NEEDS_REVIEW; commit_all
expect "NEEDS_REVIEW: review" review T-13
expect_rc "review role" code-reviewer "$(field '["role"]')"
round T-13 reviews 1 verdict=REQUEST_CHANGES; commit_all
expect "after REQUEST_CHANGES and resubmit: review again" review T-13
j | grep -q "review round 2" && ok "next round number in reason" || bad "next round number in reason"
round T-13 reviews 2 verdict=APPROVE; commit_all
expect "APPROVE recorded: continue to CODE_COMPLETE" continue T-13
round T-13 reviews 3 verdict=ESCALATE; commit_all
expect "ESCALATE: decide" decide T-13
round T-13 reviews 4 verdict=REJECT_RECURRENCE; commit_all
expect "REJECT_RECURRENCE: continue (defer)" continue T-13
mk T-13 DONE; commit_all

# ---- 2. active work outranks review ------------------------------------------------------
mk T-14 NEEDS_REVIEW; mk T-15 IN_PROGRESS; mk T-16 ANALYSIS "priority: P1"; commit_all
expect "ANALYSIS P1 before IN_PROGRESS P2" continue T-16
expect_rc "analysis role" problem-investigator "$(field '["role"]')"
mk T-16 DONE; commit_all
expect "IN_PROGRESS: continue" continue T-15
expect_rc "IN_PROGRESS without tests written (no stage field): red-tests, test-writer" "red-tests test-writer" \
  "$(j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["stage"], d["role"])')"
j | grep -q '"action": "review"' && ok "review listed as an alternative" || bad "review listed as an alternative"

# ---- 1. resume -----------------------------------------------------------------------------
echo T-15 > .teamwright/current-task
expect "current task on a clean tree: no resume, the stage continues" continue T-15
echo change >> docs/tasks/T-1.md
expect "current task + dirty tree: resume" resume T-15
j | grep -q "uncommitted changes" && ok "resume says why" || bad "resume says why"
rm .teamwright/current-task
expect "dirty tree, one active task: resume it" resume T-15
mk T-17 IN_PROGRESS
expect "dirty tree, two active tasks: decide" decide None
git checkout -q -- docs/tasks/T-1.md; rm docs/tasks/T-17.md
echo "scratch" > notes-from-someone-else.txt
expect "untracked files alone do not interrupt" continue T-15
rm notes-from-someone-else.txt
mkdir -p .teamwright/logs
echo '{"event":"Stop","outcome":"interrupted","current_task":"T-14"}' > .teamwright/logs/outcomes.jsonl
expect "interrupted session: resume its task" resume T-14
j | grep -q "interrupted session" && ok "interrupted reason" || bad "interrupted reason"
echo '{"event":"Stop","outcome":"idle","current_task":""}' >> .teamwright/logs/outcomes.jsonl
expect "later clean stop: no resume" continue T-15

# ---- 0. paused ---------------------------------------------------------------------------
touch TEAMWRIGHT_PAUSE
expect "TEAMWRIGHT_PAUSE: paused" paused None
j | grep -q "next would be: continue T-15" && ok "paused names what would be next" || bad "paused names what would be next"
rm TEAMWRIGHT_PAUSE

# ---- 7. push decision and idle ------------------------------------------------------------
fresh idle
mk T-1 DONE; mk T-2 TODO "depends_on: [T-3]"; mk T-3 BLOCKED 'blocked_on: "upstream release"'; commit_all
expect "nothing actionable: idle" idle None
j | grep -q "T-2, T-3 waiting" && ok "idle lists waiting tasks" || bad "idle lists waiting tasks" "$(j | grep reason)"
git init -q --bare "$TMP/remote.git"; git remote add origin "$TMP/remote.git"; git push -q -u origin main 2>/dev/null
echo x > f.txt; git add f.txt; git commit -qm "chore: f"
expect "unpushed commits: decide (push)" decide None
j | grep -q "1 unpushed commit" && ok "push reason counts commits" || bad "push reason counts commits"

# ---- output modes --------------------------------------------------------------------------
out="$(python3 "$NEXT" --project .)"
printf '%s' "$out" | grep -q "^next: decide - 1 unpushed commit(s): push?" && ok "human summary: next line" \
  || bad "human summary: next line" "$out"
printf '%s' "$out" | grep -q "mode: gate-first | branch: main" && ok "human summary: status line" \
  || bad "human summary: status line" "$out"
python3 "$KIT/scripts/tw-install.py" --project . --json next | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["action"]=="decide"' \
  && ok "tw-install.py next is the same router" || bad "tw-install.py next is the same router"
a="$(j)"; b="$(j)"; expect_rc "deterministic" "$a" "$b"
# ---- priority inheritance: transitive, and a P2 unblocker of a P1 task wins over plain P2 ---
fresh inherit
mk T-1 TODO "priority: P2"
mk T-2 TODO "priority: P2"
mk T-3 TODO "priority: P2" "depends_on: [T-2]"
mk T-4 TODO "priority: P1" "depends_on: [T-3]"
mk T-5 TODO "priority: P0" "depends_on: [T-6]"
mk T-6 DONE
commit_all
expect "P0 own priority still first" start T-5
mk T-5 DONE; commit_all
expect "transitive prerequisite of a P1 task beats a plain P2 with a lower id" start T-2
j | grep -q "inherits P1 from T-4" && ok "transitive inheritance named in the reason" || bad "transitive inheritance named in the reason" "$(j | grep reason)"
mk T-4 DONE; commit_all
expect "closed dependent: no inheritance, the task that unblocks more goes first" start T-2
j | grep -q "inherits" && bad "no inheritance from a closed dependent" || ok "no inheritance from a closed dependent"

# ---- readiness: blocked_on and open questions ---------------------------------------------
fresh oq
mkdir -p docs
printf '| ID | Question | Blocks | Options | Asked | Status |\n|---|---|---|---|---|---|\n| OQ-01 | tz source? | T-2 | A / B | 2026-01-01 | open |\n| OQ-03 | old | T-4 | A | 2026-01-01 | answered -> decisions.md #2 |\n' > docs/open-questions.md
mk T-2 TODO "priority: P0" "blocked_on: OQ-01"
mk T-3 TODO "priority: P1" 'blocked_on: "waiting for the vendor sandbox"'
mk T-4 TODO "priority: P1" "blocked_on: OQ-03"
mk T-5 TODO "priority: P2"
commit_all
expect "blocked_on an open OQ: not ready; blocked_on a resolved OQ: ready" start T-4
j | python3 -c 'import json,sys; d=json.load(sys.stdin); assert all(a["task"] not in ("T-2","T-3") for a in d["alternatives"]), d["alternatives"]' \
  && ok "TODO with blocked_on (open OQ or free text) is not started" || bad "TODO with blocked_on (open OQ or free text) is not started"
j | python3 -c 'import json,sys; d=json.load(sys.stdin); t={x["id"]:x for x in d["tasks"]}; assert t["T-2"]["ready"] is False and t["T-2"]["blockers"]==["OQ-01"], t["T-2"]' \
  && ok "task list shows the unresolved OQ as the blocker" || bad "task list shows the unresolved OQ as the blocker"
j | grep -q "T-4: blocked_on names OQ-03, already answered" && ok "warning: blocked_on names a resolved OQ" || bad "warning: blocked_on names a resolved OQ"
{ echo "---"; echo "id: T-6"; echo "title: tz hints"; echo "type: bug"; echo "status: TODO"; echo "priority: P3"
  echo 'blocked_on: ""'; echo "---"; echo "## Context"; echo "Resolve OQ-01 before analysis."; } > docs/tasks/T-6.md
commit_all
j | grep -q 'T-6 mentions unresolved OQ-01 but blocked_on is empty' && ok "warning: body mentions an open OQ, blocked_on empty" \
  || bad "warning: body mentions an open OQ, blocked_on empty" "$(j | grep -A3 warnings)"
python3 "$NEXT" --project . | grep -q "warning: T-6 mentions" && ok "human summary shows warnings" || bad "human summary shows warnings"
echo "non-blocking: OQ-01 - the default UTC is fine for release 1" >> docs/tasks/T-6.md; sed 's/^Resolve OQ-01 before analysis.$/Timezone hints./' docs/tasks/T-6.md > docs/tasks/T-6.tmp && mv docs/tasks/T-6.tmp docs/tasks/T-6.md; commit_all
j | grep -q 'T-6 mentions unresolved' && bad "a non-blocking mention is not warned about" || ok "a non-blocking mention is not warned about"

# ---- process settings: autonomy.start and the pass budget ---------------------------
fresh settings
mk T-1 TODO "priority: P1"
mk T-2 TODO "priority: P2"
mk T-3 TODO "priority: P2"
commit_all
jp() { python3 "$NEXT" --project . --json "$@"; }
expect_rc "no settings: start asks the owner" True "$(field '["ask_owner"]')"
expect_rc "no --pass: no budget" None "$(field '["budget"]')"
expect_rc "no --pass: start as before" "start T-1" "$(jp | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"], d["task"])')"
expect_rc "defaults: a pass of 1 is used after one task" "stop" \
  "$(jp --pass T-9 | python3 -c 'import json,sys; print(json.load(sys.stdin)["action"])')"
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\nprocess:\n  batch:\n    max_tasks: 3\n    by_priority:\n      P1: 2\n  autonomy:\n    start: auto\n' > .teamwright/config.yml
expect_rc "autonomy.start auto: start needs no owner answer" False "$(field '["ask_owner"]')"
expect_rc "P1 candidate caps the pass at 2: second task allowed" "start T-1" \
  "$(jp --pass T-2 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"], d["task"])')"
expect_rc "budget reports the P1 cap" "1 2 1" \
  "$(jp --pass T-1 | python3 -c 'import json,sys; b=json.load(sys.stdin)["budget"]; print(b["taken"], b["limit"], b["left"])')"
expect_rc "a P1 already in the pass caps it at 2: stop after two" "stop" \
  "$(jp --pass T-1,T-2 | python3 -c 'import json,sys; print(json.load(sys.stdin)["action"])')"
expect_rc "P2-only pass goes to max_tasks 3" "start" \
  "$(jp --pass T-2,T-9 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"] if d["task"]=="T-3" else "x"+str(d["task"]))')" 
expect_rc "settings are reported" "medium?low 3" \
  "$(field '["settings"]' | python3 -c 'import ast,sys; d=ast.literal_eval(sys.stdin.read()); print("medium?"+d["review"]["blocking"], d["batch"]["max_tasks"])')"

expect_rc "recommended settings carry a model per stage" "opus sonnet opus opus opus" \
  "$(j | python3 -c 'import json,sys; m=json.load(sys.stdin)["recommended"]["models"]; print(*[m[s] for s in ("analyze","red-tests","implement","review","verify")])')"
expect_rc "recommended settings carry the stage thresholds" "1 1 0" \
  "$(j | python3 -c 'import json,sys; s=json.load(sys.stdin)["recommended"]["stages"]["review"]; print(s["batch"], s["min"], s["max_wait_hours"])')"

# ---- process.ready.after: a CODE_COMPLETE dependency -----------------------------------
fresh ready-after
mk T-1 CODE_COMPLETE; mk T-2 TODO "depends_on: [T-1]"; commit_all
rdy() { j | python3 -c 'import json,sys; print([t["ready"] for t in json.load(sys.stdin)["tasks"] if t["id"]=="T-2"][0])'; }
cfg_ready() { printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\nprocess:\n  ready:\n    after: %s\n' "$1" > .teamwright/config.yml; }
expect_rc "default (verified): a CODE_COMPLETE dependency keeps the task not ready" False "$(rdy)"
cfg_ready code_complete
expect_rc "ready.after code_complete: the task is ready" True "$(rdy)"
expect_rc "ready.after code_complete: start offered" True \
  "$(j | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d["action"], d["task"]) == ("start", "T-2") or any(a["action"] == "start" and a["task"] == "T-2" for a in d["alternatives"]))')"
expect_rc "settings report ready.after" code_complete "$(field '["settings"]["ready"]["after"]')"
mk T-1 ANALYSIS; commit_all
expect_rc "ready.after code_complete: a dependency still in ANALYSIS blocks" False "$(rdy)"
cfg_ready deployed
expect_rc "an invalid ready.after falls back to verified" verified "$(field '["settings"]["ready"]["after"]')"

# ---- stages (0.12): the stage field against the evidence ----------------------------------
tests_md() { printf '\n## Tests\n\n- guarantee 1: test_one (red: AssertionError)\n'; }
fresh stages
mk T-1 IN_PROGRESS "stage: red-tests"
commit_all
st_of() { j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["stage"], d["role"], len([w for w in d["warnings"] if "stage" in w]))'; }
expect_rc "stage: red-tests, no tests yet: red-tests, test-writer, no warning" "red-tests test-writer 0" "$(st_of)"
expect_rc "command names the stage and the batch" "/teamwright:red-tests T-1" "$(field '["command"]')"
expect_rc "work available" True "$(field '["work_available"]')"
expect_rc "no model configured: the role files decide" None "$(field '["model"]')"
expect_rc "selection by the script by default" script "$(field '["select"]')"
tests_md >> docs/tasks/T-1.md; commit_all
expect_rc "stage: red-tests with ## Tests filled: the field is behind the evidence, a legal step back (red-tests, no warning)" "red-tests test-writer 0" "$(st_of)"
expect_rc "a stage request for red-tests on it is ok (sent back to its tests)" "True" \
  "$(python3 "$NEXT" --project . --json --stage red-tests --task T-1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["request"]["ok"])')"
mk T-1 IN_PROGRESS "stage: implement"; commit_all
expect_rc "stage: implement without tests: the field is ahead, the evidence wins (red-tests), with a warning" "red-tests test-writer 1" "$(st_of)"
j | grep -q "evidence says red-tests" && ok "the warning names the evidence" || bad "the warning names the evidence"
mk T-1 IN_PROGRESS "stage: implement"; tests_md >> docs/tasks/T-1.md; commit_all
expect_rc "stage: implement with tests: implement, developer, no warning" "implement developer 0" "$(st_of)"
mk T-1 IN_PROGRESS; tests_md >> docs/tasks/T-1.md; commit_all
expect_rc "legacy task (no stage field) with tests: implement from the evidence, no warning" "implement developer 0" "$(st_of)"
j | grep -q "no stage field: from the evidence" && ok "legacy reason says the stage came from the evidence" || bad "legacy reason says the stage came from the evidence"
mk T-1 IN_PROGRESS "stage: check"; commit_all
j | grep -q "stage: check. is not a stage" && ok "an unknown stage value is warned about" || bad "an unknown stage value is warned about" "$(j | grep -A2 warnings)"
mk T-1 IN_PROGRESS "stage: implement"; tests_md >> docs/tasks/T-1.md; commit_all

# resume: dirty tree or an interrupted outcome, never the current task alone
echo T-1 > .teamwright/current-task
expect "current task, clean tree, stage recorded: continue" continue T-1
mkdir -p src; echo x > src/a.txt; git add src/a.txt
expect "current task, dirty tree: resume" resume T-1
expect_rc "resume carries the task's stage" implement "$(field '["stage"]')"
git reset -q; rm -rf src
mkdir -p .teamwright/logs; echo '{"event":"Stop","outcome":"interrupted","current_task":"T-1"}' > .teamwright/logs/outcomes.jsonl
expect "interrupted outcome, clean tree: resume" resume T-1
echo '{"event":"Stop","outcome":"barrier","current_task":"T-1","stage":"implement"}' >> .teamwright/logs/outcomes.jsonl
expect "after a barrier: continue" continue T-1
rm -f .teamwright/current-task

# ---- stage requests (--stage, --task): stage commands ask first --------------------------
req() { python3 "$NEXT" --project . --json --stage "$@" | python3 -c 'import json,sys; r=json.load(sys.stdin)["request"]; print(r["ok"], " ".join(r["batch"]) or "-", r["hint"])'; }
mk T-2 IN_PROGRESS "stage: red-tests"; commit_all
expect_rc "implement on a task at red-tests: refused with the command to run" "False - T-2 is IN_PROGRESS, stage red-tests: /teamwright:red-tests T-2" "$(req implement --task T-2)"
expect_rc "red-tests on that task: ok" "True T-2 " "$(req red-tests --task T-2)"
expect_rc "a stage without a task: its waiting tasks" "True T-1 " "$(req implement)"
req review | grep -q "^False - nothing waits at review; the router says: /teamwright:implement T-1" && ok "nothing at the stage: the router's command" || bad "nothing at the stage: the router's command" "$(req review)"
mkdir -p src; echo x > src/a.txt; git add src/a.txt; echo T-2 > .teamwright/current-task
req implement | grep -q "^False - .*finish it first: /teamwright:red-tests T-2" && ok "uncommitted work on another task: refused, finish it first" || bad "uncommitted work on another task: refused, finish it first" "$(req implement)"
expect_rc "the resumed task's own stage runs" "True T-2 " "$(req red-tests --task T-2)"
git reset -q; rm -rf src .teamwright/current-task
python3 "$NEXT" --project . --task T-1 >/dev/null 2>&1; expect_rc "--task without --stage is an error" 2 "$?"
mk T-1 DONE; mk T-2 DONE; commit_all

# ---- batches and thresholds per stage ------------------------------------------------------
fresh batches
mk T-1 NEEDS_REVIEW; mk T-2 NEEDS_REVIEW; mk T-3 TODO; mk T-4 TODO; mk T-5 TODO
commit_all
cfg_st() { printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\nprocess:\n  stages:\n%b' "$1" > .teamwright/config.yml; }
expect "defaults (min 1): review runs at once, as before stages" review T-1
expect_rc "default batch 1" "T-1" "$(field '["batch"]' | python3 -c 'import ast,sys; print(" ".join(ast.literal_eval(sys.stdin.read())))')"
cfg_st '    review:\n      batch: 3\n      min: 3\n    analyze:\n      batch: 2\n'
expect "review min 3, two waiting: held, analysis starts" start T-3
expect_rc "analyze batch 2" "T-3 T-4" "$(field '["batch"]' | python3 -c 'import ast,sys; print(" ".join(ast.literal_eval(sys.stdin.read())))')"
expect_rc "stages report the held review" "False 2" "$(j | python3 -c 'import json,sys; s=json.load(sys.stdin)["stages"]["review"]; print(s["due"], len(s["waiting"]))')"
j | grep -q "held: review stage waits - 2 waiting, min 3" && ok "held candidates say why" || bad "held candidates say why"
expect_rc "with --pass the analyze batch keeps to the pass budget" "T-3" \
  "$(python3 "$NEXT" --project . --json --pass "" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["batch"]))')"
mk T-6 NEEDS_REVIEW; commit_all
expect "three waiting: review is due" review T-1
expect_rc "review batch 3 in router order" "T-1 T-2 T-6" "$(field '["batch"]' | python3 -c 'import ast,sys; print(" ".join(ast.literal_eval(sys.stdin.read())))')"
mk T-6 DONE; mk T-2 NEEDS_REVIEW "priority: P1"; commit_all
expect "a P1 task waiting: review runs below min" review T-2
j | grep -q "P1 waiting (P0/P1 run at once)" && ok "urgent reason" || bad "urgent reason"
mk T-2 NEEDS_REVIEW; mk T-3 DONE; mk T-4 DONE; mk T-5 DONE; commit_all
expect "nothing else to do: the held stage runs" review T-1
j | grep -q "nothing else to do" && ok "reason: nothing else to do" || bad "reason: nothing else to do"
mk T-5 TODO; commit_all
cfg_st '    review:\n      min: 3\n      max_wait_hours: 2\n'
expect "review min 3, records fresh: analysis first" start T-5
mk T-1 NEEDS_REVIEW "title: old one"; git add -A; GIT_COMMITTER_DATE="2001-01-01T00:00:00" git commit -qm old
expect "the oldest waiting task is past max_wait_hours: review runs" review T-1
j | grep -q "max_wait_hours 2" && ok "age reason" || bad "age reason" "$(j | grep why)"

# ---- candidates: facts for the session's batch choice ------------------------------------
fresh cands
printf 'version: 1\nmode: gate-first\nareas:\n  - name: server\n    source_dirs: [server/src]\n  - name: app\n    source_dirs: [app/lib]\nprocess:\n  stages:\n    review:\n      batch: 3\n' > .teamwright/config.yml
mk T-1 NEEDS_REVIEW "analysis:" "  seam: server/src/billing.py"
mk T-2 NEEDS_REVIEW "analysis:" "  seam: server/src/billing.py:40 and server/src/ledger.py"
mk T-3 NEEDS_REVIEW "analysis:" "  seam: app/lib/cart.dart" "depends_on: [T-1]"
mk T-4 NEEDS_REVIEW "analysis:" "  seam: the retry policy"
mk T-5 TODO "depends_on: [T-3]" "priority: P1"
commit_all
cand() { j | python3 -c 'import json,sys; c={x["id"]:x for x in json.load(sys.stdin)["candidates"]}; print(eval(sys.argv[1]))' "$1"; }
expect_rc "candidates: every task waiting at the chosen stage, in router order" "['T-1', 'T-2', 'T-3', 'T-4']" "$(cand 'list(c)')"
expect_rc "batch cap reported" 3 "$(field '["batch_cap"]')"
expect_rc "seam paths and areas from the config" "['server/src/billing.py'] ['server']" "$(cand 'c["T-1"]["seam_paths"], c["T-1"]["areas"]' | tr -d '(),' | sed 's/] \[/] [/')"
expect_rc "overlapping seams named (tw-parallel rule)" "['T-2', 'T-4']" "$(cand 'c["T-1"]["overlaps"]')"
expect_rc "a disjoint seam overlaps only the seam without a path" "['T-4']" "$(cand 'c["T-3"]["overlaps"]')"
expect_rc "a dependency between candidates is named" "['T-1']" "$(cand 'c["T-3"]["depends_on_candidates"]')"
expect_rc "unblocks and inherited priority" "1 P1" "$(cand 'str(c["T-3"]["unblocks"]) + " " + c["T-3"]["effective_priority"]')"
expect_rc "a stage request carries the candidates too" "T-1 T-2 T-3 T-4" \
  "$(python3 "$NEXT" --project . --json --stage review | python3 -c 'import json,sys; print(" ".join(x["id"] for x in json.load(sys.stdin)["request"]["candidates"]))')"

# ---- work_available, models, headless, selection mode --------------------------------------
fresh models
mk T-1 DONE; commit_all
expect_rc "idle: no work available" "idle False" "$(j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"], d["work_available"])')"
expect_rc "idle: no headless job" False "$(field '["headless"]["run"]')"
mk T-2 NEEDS_REVIEW; commit_all
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\nprocess:\n  models:\n    review: sonnet\n  router:\n    select: agent\n' > .teamwright/config.yml
expect_rc "the stage's model is reported" sonnet "$(field '["model"]')"
expect_rc "headless prompt for one stage per job, without ids (the session picks)" "True /teamwright:review sonnet" \
  "$(j | python3 -c 'import json,sys; h=json.load(sys.stdin)["headless"]; print(h["run"], h["prompt"], h["model"])')"
j | grep -q 'claude -p \\"/teamwright:review\\" --model sonnet' && ok "headless note has the command line" || bad "headless note has the command line"
expect_rc "selection mode agent is reported" agent "$(field '["select"]')"
out="$(python3 "$NEXT" --project .)"
printf '%s' "$out" | grep -q "stage: review | batch: - | model: sonnet | run: /teamwright:review$" && ok "human summary: stage line (select: agent - no batch)" \
  || bad "human summary: stage line" "$out"
git init -q --bare "$TMP/remote2.git"; git remote add origin "$TMP/remote2.git"; git push -q -u origin main 2>/dev/null
mk T-2 DONE; echo y > g.txt; git add -A; git commit -qm "chore: g"
expect_rc "only a push decision: no work available, no job" "decide False False" \
  "$(j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"], d["work_available"], d["headless"]["run"])')"

# ---- headless: an owner decision does not stop the chain while work is available (B1) ----
fresh headless
mk T-1 BLOCKED 'blocked_on: "owner decision: which provider"'
mk T-2 TODO; mk T-3 ANALYSIS; commit_all
hl() { j | python3 -c 'import json,sys; d=json.load(sys.stdin); h=d["headless"]; print(d["action"], d["task"], h["run"], h["stage"], h["task"], ",".join(x["task"] or "-" for x in h["decisions"]), ",".join(x["task"] or "-" for x in d["decisions"]))'; }
expect_rc "ANALYSIS before the decision: both agree" "continue T-3 True analyze T-3 T-1 T-1" "$(hl)"
mk T-3 DONE; mk T-4 NEEDS_REVIEW; mk T-5 BLOCKED 'blocked_on: "owner decision: scope"'; commit_all
expect_rc "decide first interactively; headless takes the first work and lists the decisions" "review T-4 True review T-4 T-1,T-5 T-1,T-5" "$(hl)"
mk T-4 DONE; commit_all
expect_rc "only a start left, autonomy.start ask: interactive decide, no job (no one to ask)" "decide T-1 False None None T-1,T-5 T-1,T-5" "$(hl)"
j | python3 -c 'import json,sys; h=json.load(sys.stdin)["headless"]; assert "autonomy.start" in h["note"], h' \
  && ok "the headless note names autonomy.start" || bad "the headless note names autonomy.start"
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\nprocess:\n  autonomy:\n    start: auto\n' > .teamwright/config.yml
expect_rc "autonomy.start auto: the job starts the ready task past the decisions" "decide T-1 True analyze T-2 T-1,T-5 T-1,T-5" "$(hl)"
touch TEAMWRIGHT_PAUSE
expect_rc "paused: no job" "paused None False" "$(j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"], d["task"], d["headless"]["run"])')"
rm TEAMWRIGHT_PAUSE
mk T-2 DONE; commit_all
expect_rc "decisions only: no work available, no job" "decide False False" \
  "$(j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"], d["work_available"], d["headless"]["run"])')"

# ---- the main checkout on a task branch is not a per-task worktree (autonomous run) ----
mk T-2 CODE_COMPLETE; mk T-3 CODE_COMPLETE; git add -A; git commit -qm "chore: two tasks to verify"
git checkout -q -b task/T-2-run18
expect_rc "main checkout on task/T-2-run18: verify sees both tasks" "True T-2,T-3" \
  "$(python3 "$NEXT" --project . --json --stage verify --task T-2,T-3 | python3 -c 'import json,sys; r=json.load(sys.stdin)["request"]; print(r["ok"], ",".join(c.get("id") or c.get("task") for c in r["candidates"]))')"
git checkout -q main

# ---- M3: a task that deploys is verified after DRAIN; unpushed is counted against the delivery branch ----
fresh drain
git init -q --bare "$TMP/drain.git"; git remote add origin "$TMP/drain.git"; git push -q -u origin main 2>/dev/null
mk T-1 CODE_COMPLETE; mk T-2 CODE_COMPLETE "deploys: false" "surface: none"; git add -A; git commit -qm "chore(task): tasks"
echo code > a.txt; git add a.txt; git commit -qm "feat(core): T-1 the change"
dr() { j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"], d["task"], " ".join("%s:%s" % (a["action"], a["task"]) for a in d["alternatives"]))'; }
expect_rc "deploys: true, code not pushed: no verify yet; deploys: false verifies locally; the push names T-1" "verify T-2 decide:None" "$(dr)"
j | grep -q "T-1 deploys and is verified after the push (DRAIN)" && ok "the push decision says T-1 waits for DRAIN" || bad "the push decision says T-1 waits for DRAIN" "$(j | grep unpushed)"
git push -q origin main 2>/dev/null
expect_rc "after the push: T-1 is verified" "verify T-1 verify:T-2" "$(dr)"
git checkout -q -b wip/teamwright; echo more > b.txt; git add b.txt; git commit -qm "feat(core): T-3 more"
git push -q -u origin wip/teamwright 2>/dev/null
expect_rc "on a wip branch pushed to its own upstream: unpushed counts against origin/main" "1 origin/main" \
  "$(field '["state"]["unpushed"], d["state"]["delivery_ref"]' | tr -d "(),'")"
j | grep -q "1 unpushed commit(s) (not on origin/main): push?" && ok "the push reason names the delivery branch" || bad "the push reason names the delivery branch" "$(j | grep unpushed)"
git checkout -q main

# ---- M4: --brief, closed tasks never listed, request first --------------------------------
fresh big
i=1; while [ $i -le 100 ]; do mk "T-$i" TODO "title: a fairly long title for task number $i of the backlog"; i=$((i + 1)); done
while [ $i -le 112 ]; do mk "T-$i" DONE; i=$((i + 1)); done
while [ $i -le 116 ]; do mk "T-$i" NEEDS_REVIEW; i=$((i + 1)); done
while [ $i -le 120 ]; do mk "T-$i" IN_PROGRESS "stage: red-tests"; i=$((i + 1)); done
commit_all
full="$(python3 "$NEXT" --project . --json --stage analyze | wc -c | tr -d ' ')"
br="$(python3 "$NEXT" --project . --brief --stage analyze | wc -c | tr -d ' ')"
[ "$br" -lt 6000 ] && ok "--brief for 120 tasks stays under 6 KB ($br bytes; full JSON $full)" || bad "--brief for 120 tasks stays under 6 KB" "$br bytes"
python3 "$NEXT" --project . --brief --stage analyze | python3 -c 'import json,sys; d=json.load(sys.stdin); assert list(d)[0]=="request" and "tasks" not in d, list(d); r=d["request"]; assert r["ok"] and r["candidates_total"]==100 and len(r["candidates"])==8, r; assert d["stages"]["review"]["waiting"]==4 and d["counts"]["DONE"]==12, d["stages"]' \
  && ok "--brief: request first, compact candidates with the total, stage and status counts, no task list" || bad "--brief: request first, compact candidates with the total, stage and status counts, no task list"
python3 "$NEXT" --project . --json --stage analyze | python3 -c 'import json,sys; d=json.load(sys.stdin); assert list(d)[0]=="request", list(d)[:3]; assert all(t["status"] not in ("DONE","DEFERRED") for t in d["tasks"]) and len(d["tasks"])==108, len(d["tasks"]); assert d["counts"]["DONE"]==12' \
  && ok "full JSON: request first; DONE tasks counted, not listed" || bad "full JSON: request first; DONE tasks counted, not listed"
python3 "$NEXT" --project . | grep -q "DONE 12" && ok "human summary still counts closed tasks" || bad "human summary still counts closed tasks"
wc -c < "$KIT/docs/process/stage-protocol.md" | python3 -c 'import sys; n=int(sys.stdin.read()); sys.exit(0 if n < 4096 else 1)' \
  && ok "the stage protocol stage sessions read is under 4 KB" || bad "the stage protocol stage sessions read is under 4 KB"
for s in analyze red-tests implement review verify router flow; do
  grep -q -- "--brief" "$KIT/skills/$s/SKILL.md" || bad "skill $s asks the router with --brief"
  grep -q "stage-protocol.md" "$KIT/skills/$s/SKILL.md" || bad "skill $s points at the short stage protocol"
done
ok "stage skills and flow use --brief and the short stage protocol"

# ---- M5: a project's _task.py older than the plugin (updated without apply) -------------
fresh olddrift
mkdir -p scripts/hooks; cp "$HOOKS/_config.py" scripts/hooks/
python3 - "$HOOKS/_task.py" scripts/hooks/_task.py <<'PY'
import re, sys
src = open(sys.argv[1]).read()
for name in ("tests_written", "failure_branches", "task_stage", "code_changed", "section", "_without_placeholders"):
    src = re.sub(r"(?ms)^def %s\(.*?(?=^def |^[A-Z_]+ = |\Z)" % name, "", src)
open(sys.argv[2], "w").write(src)
PY
python3 -c 'import sys; sys.path.insert(0, "scripts/hooks"); import _task; assert not hasattr(_task, "tests_written") and not hasattr(_task, "task_stage")' \
  && ok "fixture: an installed _task.py without the stage helpers" || bad "fixture: an installed _task.py without the stage helpers"
mk T-1 IN_PROGRESS "stage: implement"; tests_md >> docs/tasks/T-1.md; commit_all
expect_rc "old installed _task.py: the stage still comes from the kit's helpers (implement, not red-tests)" "implement developer" \
  "$(j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["stage"], d["role"])')"
j | grep -q "install drift: scripts/hooks/_task.py predates the plugin (missing: .*task_stage.*tests_written.*tw-install.py apply" \
  && ok "the drift is a warning naming the missing helpers and tw-install.py apply" || bad "the drift is a warning naming the missing helpers and tw-install.py apply" "$(j | grep -A3 warnings)"
cp "$HOOKS/_task.py" scripts/hooks/_task.py; commit_all
j | grep -q "install drift: scripts/hooks/_task.py" && bad "an up-to-date _task.py: no drift warning" || ok "an up-to-date _task.py: no drift warning"

# ---- M6: explicit --task ids: capped by the stage's batch, dependencies first, overlaps named ----
fresh explicit
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\nprocess:\n  stages:\n    review:\n      batch: 2\n' > .teamwright/config.yml
mk T-1 NEEDS_REVIEW "analysis:" "  seam: src/a.py"; mk T-2 NEEDS_REVIEW "depends_on: [T-3]" "analysis:" "  seam: src/a.py"
mk T-3 NEEDS_REVIEW "analysis:" "  seam: src/b.py"; commit_all
rq() { python3 "$NEXT" --project . --brief --stage review --task "$1" | python3 -c 'import json,sys; r=json.load(sys.stdin)["request"]; print(r["ok"], " ".join(r["batch"]), "|", "; ".join(r["warnings"]))'; }
got="$(rq T-2,T-3,T-1)"
expect_rc "three named, cap 2: the dependency first, the rest dropped" "True T-3 T-2" "$(printf '%s' "$got" | cut -d'|' -f1 | sed 's/ $//')"
case "$got" in *"T-2 depends on T-3: T-3 goes first"*"3 tasks named, the stage takes at most 2"*"T-1 left for the next session"*) ok "warnings: the dependency and the cap" ;; *) bad "warnings: the dependency and the cap" "$got" ;; esac
case "$(rq T-1,T-2)" in *"T-1 and T-2 touch the same code"*) ok "overlapping seams among named tasks are named" ;; *) bad "overlapping seams among named tasks are named" "$(rq T-1,T-2)" ;; esac

# ---- m1: one task IN_PROGRESS per tree; analyze batches analyses, not WIP ----------------
fresh wip
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\nprocess:\n  stages:\n    analyze:\n      batch: 3\n' > .teamwright/config.yml
mk T-1 IN_PROGRESS "stage: implement"; tests_md >> docs/tasks/T-1.md
mk T-2 ANALYSIS "analysis:" "  root_cause: a" "  evidence: b" "  invariant: c" "  seam: d" "  approach: e"
mk T-3 ANALYSIS; commit_all
expect_rc "an analysed task waits while another is IN_PROGRESS; an unfinished analysis is still analyze work" "T-3" \
  "$(python3 "$NEXT" --project . --brief --stage analyze | python3 -c 'import json,sys; print(" ".join(c["id"] for c in json.load(sys.stdin)["request"]["candidates"]))')"
expect_rc "the state says what it waits for" "{'T-2': 'T-1'}" "$(field '["state"]["wip_waiting"]')"
python3 "$NEXT" --project . --brief --stage analyze --task T-2 | grep -q "enters IN_PROGRESS when T-1 leaves it" \
  && ok "naming it explicitly: refused with the reason" || bad "naming it explicitly: refused with the reason"
mk T-1 NEEDS_REVIEW "stage: implement"; tests_md >> docs/tasks/T-1.md; commit_all
expect_rc "once T-1 left IN_PROGRESS the analysed task moves on" "T-2 T-3" \
  "$(python3 "$NEXT" --project . --brief --stage analyze | python3 -c 'import json,sys; print(" ".join(c["id"] for c in json.load(sys.stdin)["request"]["candidates"]))')"

# ---- m2: an uncommitted record ages by its file time --------------------------------------
fresh ages
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\nprocess:\n  stages:\n    review:\n      min: 3\n      max_wait_hours: 2\n' > .teamwright/config.yml
mk T-1 TODO; commit_all
mk T-2 NEEDS_REVIEW; touch -t 200101010000 docs/tasks/T-2.md
expect "an uncommitted record older than max_wait_hours (file time): review is due" review T-2
j | grep -q "T-2 waiting .* h (max_wait_hours 2)" && ok "the age reason, from the file time" || bad "the age reason, from the file time" "$(j | grep why)"
touch docs/tasks/T-2.md
expect "a fresh uncommitted record: review held, analysis first" start T-1

# ---- m5: only <ID>.md is a task record ----------------------------------------------------
fresh sidefiles
mk T-89 TODO; printf -- '---\nid: T-89.history\nstatus: IN_PROGRESS\n---\nold notes\n' > docs/tasks/T-89.history.md
printf -- '---\nstatus: NEEDS_REVIEW\n---\n' > docs/tasks/T-89.notes.md; commit_all
expect_rc "side files next to a record are not tasks" "start T-89 1" \
  "$(j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"], d["task"], sum(d["counts"].values()))')"
python3 "$KIT/scripts/tw-progress.py" --project . --json | python3 -c 'import json,sys; d=json.dumps(json.load(sys.stdin)); assert "T-89.history" not in d and "T-89.notes" not in d' \
  && ok "tw-progress ignores side files too" || bad "tw-progress ignores side files too"
python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import _hookio as io; assert not io.TASK_FILE_RE.search("docs/tasks/T-89.history.md") and io.TASK_FILE_RE.search("docs/tasks/T-89.md") and not io.TASK_FILE_RE.search("docs/tasks/_task-template.md")' "$HOOKS" \
  && ok "the gates' task-record pattern matches <ID>.md only" || bad "the gates' task-record pattern matches <ID>.md only"

# ---- m8: process.router.select changes the output -----------------------------------------
fresh select
mk T-1 NEEDS_REVIEW; mk T-2 NEEDS_REVIEW; commit_all
sel() { python3 "$NEXT" --project . --json --stage review | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["request"]; print(d["select"], len(d["candidates"]), " ".join(d["batch"]) or "-", d["command"], r["ok"], len(r["candidates"]), " ".join(r["batch"]) or "-")'; }
expect_rc "select: script - candidates and a batch" "script 2 T-1 /teamwright:review T-1 True 2 T-1" "$(sel)"
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\nprocess:\n  router:\n    select: agent\n' > .teamwright/config.yml
expect_rc "select: agent - the stage and ok, but no candidates, no batch, a bare command" "agent 0 - /teamwright:review True 0 -" "$(sel)"
expect_rc "select: agent - named tasks are still checked and kept" "True T-2" \
  "$(python3 "$NEXT" --project . --brief --stage review --task T-2 | python3 -c 'import json,sys; r=json.load(sys.stdin)["request"]; print(r["ok"], " ".join(r["batch"]))')"

finish
