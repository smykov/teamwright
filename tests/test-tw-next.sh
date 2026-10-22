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
validated() {  # validated ID VERDICT : next validation record at HEAD
  local d="docs/tasks/$1.validation" n; mkdir -p "$d"; n=$(( $(find "$d" -maxdepth 1 -type f -name '*.md' | wc -l) + 1 ))
  printf -- '---\ntask: %s\nround: %s\nverdict: %s\ncommit: %s\nvalidator: task-validator\n---\n' "$1" "$n" "$2" "$(git rev-parse HEAD)" > "$d/$n.md"
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
expect_rc "developer role" developer "$(field '["role"]')"
j | grep -q '"action": "review"' && ok "review listed as an alternative" || bad "review listed as an alternative"

# ---- 1. resume -----------------------------------------------------------------------------
echo T-15 > .teamwright/current-task
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

finish
