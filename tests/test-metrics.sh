#!/usr/bin/env bash
# Regression: scripts/metrics/teamwright-metrics on a synthetic repository.
. "$(dirname "$0")/lib.sh"
echo "metrics"
M="$KIT/template/scripts/metrics/teamwright-metrics"
R="$TMP/repo"
mkdir -p "$R" && cd "$R" || exit 1
git init -q -b main .

# c DATE MESSAGE [FILE...] - commit at a fixed date, touching FILEs (one line each).
c() {
  local d="$1" msg="$2" f
  shift 2
  for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "$d $RANDOM" >> "$f"; git add "$f"; done
  GIT_AUTHOR_DATE="${d}T12:00:00Z" GIT_COMMITTER_DATE="${d}T12:00:00Z" \
    git commit -q --allow-empty -m "$msg"
}
CLAUDE_OPUS="Co-Authored-By: Claude Opus 4.1 <noreply@anthropic.com>"
CLAUDE_OLD="Co-Authored-By: claude-3-5-sonnet-20241022 <noreply@anthropic.com>"
CLAUDE_SONNET="Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
HUMAN_CLAUDE="Co-Authored-By: Claude Dupont <claude@example.invalid>"

# --- before 2026-03-01: agent fixes recurring in src/a
c 2026-01-05 "feat: init" src/a/x.py
c 2026-01-10 "fix: parser drops field

$CLAUDE_OPUS" src/a/x.py
c 2026-01-15 "fix(a): parser again

$CLAUDE_OLD" src/a/x.py
c 2026-01-20 "fix: third patch" src/a/y.py
c 2026-01-25 "feat: pair programming

$HUMAN_CLAUDE" src/c/w.py
c 2026-02-01 'Revert "feat: pair programming"' src/c/w.py

# --- after 2026-03-01: task lifecycle with rework, escalation, several ids
task() { mkdir -p docs/tasks; printf -- '---\nid: %s\ntitle: t\ntype: bug\nstatus: TODO\nsprint: %s\n---\n' "$1" "$2" > "docs/tasks/$1.md"; git add "docs/tasks/$1.md"; }
review() { mkdir -p "docs/tasks/$1.reviews"; printf -- '---\ntask: %s\nround: %s\nreviewer: code-reviewer\nverdict: %s\n---\n' "$1" "$2" "$3" > "docs/tasks/$1.reviews/$2.md"; git add "docs/tasks/$1.reviews/$2.md"; }
task T-1 1; task T-2 1; task T-3 2
c 2026-03-01 "chore(task): T-1 TODO→IN_PROGRESS"
c 2026-03-02 "chore(task): T-2 T-3 TODO→IN_PROGRESS"
c 2026-03-03 "chore(task): T-1 IN_PROGRESS→NEEDS_REVIEW"
review T-1 1 REQUEST_CHANGES
c 2026-03-04 "chore(task): T-1 NEEDS_REVIEW→IN_PROGRESS"
c 2026-03-04 "chore(task): T-2 IN_PROGRESS→NEEDS_REVIEW"
c 2026-03-05 "feat(b): T-1 add b

$CLAUDE_SONNET" src/b/z.py
c 2026-03-05 "chore(task): T-1 IN_PROGRESS->NEEDS_REVIEW"
c 2026-03-05 "chore(task): T-2 NEEDS_REVIEW→CODE_COMPLETE"
review T-1 2 APPROVE
c 2026-03-06 "chore(task): T-1 NEEDS_REVIEW→CODE_COMPLETE"
c 2026-03-06 "fix(b): T-2 edge case" src/b/z.py
c 2026-03-06 "chore(task): T-2 CODE_COMPLETE→DONE"
c 2026-03-07 "chore(task): T-1 CODE_COMPLETE→DONE"
c 2026-03-08 "chore(task): batch

T-3 IN_PROGRESS→NEEDS_REVIEW"
c 2026-03-09 "chore(task): T-3 NEEDS_REVIEW→BLOCKED"
c 2026-05-10 "fix(b): T-3 late fix" src/b/z.py

# --- journals (format of journal.sh), inside 2026-03-04 .. 2026-03-06
L="$R/.teamwright/logs"; mkdir -p "$L"
cat > "$L/tools.jsonl" <<'EOF'
{"ts":"2026-03-04T09:00:00Z","event":"pre","session_id":"s1","agent_id":"","agent_type":"","tool":"Agent","detail":"code-reviewer","subagent_type":"code-reviewer","task_ids":["T-1"]}
{"ts":"2026-03-04T09:05:00Z","event":"post","session_id":"s1","agent_id":"","agent_type":"","tool":"Agent","detail":"code-reviewer","subagent_type":"code-reviewer","task_ids":["T-1"]}
{"ts":"2026-03-04T09:01:00Z","event":"pre","session_id":"s1","agent_id":"a1","agent_type":"code-reviewer","tool":"Read","detail":"src/b/z.py"}
{"ts":"2026-03-04T09:01:01Z","event":"post","session_id":"s1","agent_id":"a1","agent_type":"code-reviewer","tool":"Read","detail":"src/b/z.py"}
{"ts":"2026-03-04T09:10:00Z","event":"pre","session_id":"s1","agent_id":"","agent_type":"","tool":"Edit","detail":"src/b/z.py"}
{"ts":"2026-03-06T10:00:00Z","event":"pre","session_id":"s2","agent_id":"","agent_type":"","tool":"Bash","detail":"make test"}
{"ts":"2026-03-06T10:00:05Z","event":"post","session_id":"s2","agent_id":"","agent_type":"","tool":"Bash","detail":"make test"}
{"ts":"2026-03-06T10:01:00Z","event":"pre","session_id":"s2","agent_id":"","agent_type":"","tool":"Bash","detail":"git status"}
{"ts":"2026-03-06T10:01:01Z","event":"failure","session_id":"s2","agent_id":"","agent_type":"","tool":"Bash","detail":"git status"}
EOF
cat > "$L/perms.jsonl" <<'EOF'
{"ts":"2026-03-06T10:02:00Z","event":"PermissionDenied","session_id":"s2","agent_id":"","agent_type":"","tool":"Bash","detail":"git push"}
{"ts":"2026-03-06T10:03:00Z","event":"PermissionRequest","session_id":"s2","agent_id":"","agent_type":"","tool":"Bash","detail":"make deploy"}
EOF
cat > "$L/outcomes.jsonl" <<'EOF'
{"ts":"2026-03-04T09:06:00Z","event":"SubagentStop","session_id":"s1","agent_id":"a1","agent_type":"code-reviewer","outcome":"none","tool_calls":1}
{"ts":"2026-03-04T09:20:00Z","event":"Stop","session_id":"s1","agent_id":"","agent_type":"","outcome":"barrier","tool_calls":2}
{"ts":"2026-03-06T13:00:00Z","event":"Stop","session_id":"s2","agent_id":"","agent_type":"","outcome":"none","tool_calls":2}
EOF

J="$TMP/all.json"
python3 "$M" --json > "$J"; expect_rc "runs on the synthetic repo (--json)" 0 $?
# q EXPR -> value of a Python expression over the report `r`
q() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); v=eval(sys.argv[2]); print(json.dumps(v) if isinstance(v,(list,dict,bool)) or v is None else v)' "$J" "$1"; }
S='r["git"]["summary"]["all"]'

# --- git
expect_rc "commit count" 21 "$(q "${S}['commits']['value']")"
expect_rc "agent co-authored: 3 trailers, human named Claude excluded" 3 "$(q "${S}['agent_coauthored_share']['num']")"
expect_rc "agent families normalized into one" '{"claude": 3}' "$(q 'r["git"]["agent_families"]')"
expect_rc "model variants normalized (opus / sonnet)" '{"claude sonnet": 2, "claude opus": 1}' "$(q 'dict(sorted(r["git"]["agent_models"].items(), key=lambda kv: -kv[1]))')"
expect_rc "fix commits (revert not counted as fix)" 5 "$(q "${S}['fix_share']['num']")"
expect_rc "revert detected" 1 "$(q "${S}['revert_share']['num']")"
expect_rc "file area (default): only the 2nd fix of src/a/x.py recurs" 1 "$(q "${S}['recurrence_rate']['num']")"
expect_rc "recurrence rate denominator = fix commits with files" 5 "$(q "${S}['recurrence_rate']['n']")"
expect_rc "file area: no file has 3 fixes in 30 days" 0 "$(q 'len(r["git"]["recurring_areas"])')"
expect_rc "ledger commits counted and kept out of the shares" "[12, 9]" "$(q "[${S}['ledger_commits']['value'], ${S}['fix_share']['n']]")"
expect_rc "tasks fixed again: T-2 and T-3 fixed once each" "[0, 2]" "$(q "[${S}['tasks_fixed_again']['num'], ${S}['tasks_fixed_again']['n']]")"
expect_rc "no trailer-coverage break on a small history" "[]" "$(q 'r["git"]["trailer_breaks"]')"
expect_rc "parse coverage: every ledger commit parsed" "[12, 12]" "$(q '[r["tasks"]["parse_coverage"][k] for k in ("ledger_with_transition","ledger_commits")]')"
J="$TMP/dir.json"
python3 "$M" --json --area dir > "$J"
expect_rc "dir area: recurrence 2nd+3rd fix in src/a" "[2, 5]" "$(q "[${S}['recurrence_rate']['num'], ${S}['recurrence_rate']['n']]")"
expect_rc "dir area: recurring area found (3 fixes in 30 days)" '["src/a", 3]' "$(q '[r["git"]["recurring_areas"][0]["area"], r["git"]["recurring_areas"][0]["fixes_in_window"]]')"
expect_rc "dir area: only one recurring area (src/b fixes are 65 days apart)" 1 "$(q 'len(r["git"]["recurring_areas"])')"
J="$TMP/all.json"
expect_rc "task records are not an area (excluded)" false "$(q 'any(h["area"].startswith("docs/tasks") for h in r["git"]["hotspots"])')"
expect_rc "hotspot score = churn x fixes" true "$(q 'all(h["score"] == h["churn"] * h["fixes"] for h in r["git"]["hotspots"])')"
expect_rc "monthly rows present" '["2026-01", "2026-02", "2026-03", "2026-05"]' "$(q '[m["month"] for m in r["git"]["monthly"]]')"

# --- tasks
T='r["tasks"]["summary"]["all"]'
expect_rc "tasks seen (several ids in one line, ids in body)" 3 "$(q "${T}['tasks_seen']['value']")"
expect_rc "tasks done" 2 "$(q "${T}['tasks_done']['value']")"
expect_rc "cycle time median (6 d and 4 d)" 5.0 "$(q "${T}['cycle_days_median']['value']")"
expect_rc "cycle time p75" 5.5 "$(q "${T}['cycle_days_p75']['value']")"
expect_rc "rework rate: 1 of 3 reviewed tasks sent back" "[1, 3]" "$(q "[${T}['rework_rate']['num'], ${T}['rework_rate']['n']]")"
expect_rc "review rounds counted from committed review records" 0.67 "$(q "${T}['review_rounds_mean']['value']")"
expect_rc "approval without a review record detected (T-2)" "[1, 2]" "$(q "[${T}['approved_without_review_record']['num'], ${T}['approved_without_review_record']['n']]")"
expect_rc "escalation (NEEDS_REVIEW -> BLOCKED)" 1 "$(q "${T}['escalations']['value']")"
expect_rc "verify failures present as a real zero" 0 "$(q "${T}['verify_failures']['value']")"
expect_rc "sprints from task records" '[["1", 2], ["2", 1]]' "$(q '[[x["sprint"], x["tasks"]] for x in r["tasks"]["sprints"]["rows"]]')"

# --- journal
G='r["journal"]["summary"]["all"]'
expect_rc "sessions" 2 "$(q "${G}['sessions']['value']")"
expect_rc "tool calls = pre events" 5 "$(q "${G}['tool_calls']['value']")"
expect_rc "sessions without outcome (Stop only)" "[1, 2]" "$(q "[${G}['sessions_without_outcome']['num'], ${G}['sessions_without_outcome']['n']]")"
expect_rc "sessions with reviewer evidence" "[1, 2]" "$(q "[${G}['sessions_with_reviewer_evidence']['num'], ${G}['sessions_with_reviewer_evidence']['n']]")"
expect_rc "approvals with a journaled reviewer spawn (T-1 yes, T-2 no)" "[1, 2]" "$(q "[${G}['approvals_with_reviewer_spawn']['num'], ${G}['approvals_with_reviewer_spawn']['n']]")"
expect_rc "permission denials by tool" '{"Bash": 1}' "$(q 'r["journal"]["breakdown"]["all"]["denials_by_tool"]')"
expect_rc "pre without post flagged (heuristic)" '{"Edit": 1}' "$(q 'r["journal"]["breakdown"]["all"]["unmatched_pre_by_tool"]')"
expect_rc "no claim field -> claimed review is no data, not 0" null "$(q "${G}['claimed_review_with_evidence']['value']")"

# --- split date
J="$TMP/split.json"
python3 "$M" --json --split-date 2026-03-01 --area dir > "$J"
expect_rc "split: before has 6 commits" 6 "$(q 'r["git"]["summary"]["before"]["commits"]["value"]')"
expect_rc "split: recurrence before 2/3" "[2, 3]" "$(q '[r["git"]["summary"]["before"]["recurrence_rate"][k] for k in ("num","n")]')"
expect_rc "split: recurrence after 0/2" "[0, 2]" "$(q '[r["git"]["summary"]["after"]["recurrence_rate"][k] for k in ("num","n")]')"
expect_rc "split: no tasks before -> no data (null)" null "$(q 'r["tasks"]["summary"]["before"]["tasks_seen"]["value"]')"
md="$(python3 "$M" --split-date 2026-03-01 --area dir)"
if printf '%s' "$md" | grep -q -- "-66.7 pp"; then ok "markdown shows the delta in pp"; else bad "markdown shows the delta in pp"; fi
if printf '%s' "$md" | grep -q "with a journaled reviewer spawn | no data | 50.0% (1/2) | no data | -> CODE_COMPLETE transitions inside"; then
  ok "source column comes from the period that has data"; else bad "source column comes from the period that has data"; fi
if printf '%s' "$md" | grep -q "| before | after | Δ"; then ok "markdown has before/after/delta columns"; else bad "markdown has before/after/delta columns"; fi

# --- since / until
J="$TMP/range.json"
python3 "$M" --json --since 2026-01-10 --until 2026-01-20 > "$J"
expect_rc "--since/--until are inclusive days" 3 "$(q 'r["git"]["summary"]["all"]["commits"]["value"]')"

# --- alternative journal path: concatenated pretty-printed JSON with a claim field
A="$TMP/altlogs"; mkdir -p "$A"
cat > "$A/history.json" <<'EOF'
{
  "timestamp": 1772791200,
  "sessionId": "x1",
  "reviewed": true
}
{
  "timestamp": "2026-03-06 11:00:00",
  "sessionId": "x2",
  "reviewed": "yes",
  "agentType": "code-reviewer"
}
not json at all
[{"timestamp": "2026-03-06T12:00:00Z", "sessionId": "x3", "tool_name": "Bash"}]
EOF
J="$TMP/alt.json"
python3 "$M" --json --logs "$A" > "$J"
expect_rc "alt logs: pretty-printed objects and arrays parsed" 3 "$(q 'r["journal"]["n_records"]')"
expect_rc "alt logs: garbage fragment skipped and counted" 1 "$(q 'r["journal"]["unparsed_fragments"]')"
expect_rc "declared vs actual: 1 of 2 claimed reviews has evidence" "[1, 2]" "$(q '[r["journal"]["summary"]["all"]["claimed_review_with_evidence"][k] for k in ("num","n")]')"
expect_rc "alt logs without pre events: records with a tool count as calls" 1 "$(q 'r["journal"]["summary"]["all"]["tool_calls"]["value"]')"

# --- custom transition convention + status aliases
R2="$TMP/legacy"; mkdir -p "$R2" && cd "$R2" || exit 1
git init -q -b main .
printf 'wip=IN_PROGRESS\nreview = NEEDS_REVIEW\ndone=DONE\n' > "$TMP/aliases.txt"
c 2026-04-01 "status: TASK-7 new -> wip"
c 2026-04-02 "status: TASK-7 wip -> review"
c 2026-04-03 "status: TASK-7 review -> wip"
c 2026-04-04 "status: TASK-7 wip -> done
status: TASK-8 new -> wip"
J="$TMP/legacy.json"
python3 "$M" --json --task-id-regex 'TASK-[0-9]+' --status-aliases "$TMP/aliases.txt" \
  --transition-regex '^status: (?P<id><ID>) (?P<from>\w+) -> (?P<to>\w+)' > "$J"
T='r["tasks"]["summary"]["all"]'
expect_rc "custom regex: tasks parsed" 2 "$(q "${T}['tasks_seen']['value']")"
expect_rc "aliases: lowercase statuses mapped (done)" 1 "$(q "${T}['tasks_done']['value']")"
expect_rc "aliases: review -> wip counts as rework" "[1, 1]" "$(q "[${T}['rework_rate']['num'], ${T}['rework_rate']['n']]")"
expect_rc "no review records -> rounds from transitions" 1.0 "$(q "${T}['review_rounds_mean']['value']")"
expect_rc "no task records -> sprint is no data" '"no data"' "$(q 'json.dumps(r["tasks"]["sprints"].get("status"))')"
expect_rc "no journal -> no data, not 0" '"no data"' "$(q 'json.dumps(r["journal"].get("status"))')"
J="$TMP/legacy-default.json"
python3 "$M" --json --task-id-regex 'TASK-[0-9]+' > "$J"
expect_rc "tolerant default on a foreign repo: only known statuses parse (wip -> done)" 1 "$(q 'r["tasks"]["n_events"]')"
md="$(python3 "$M" --task-id-regex 'TASK-[0-9]+' --transition-regex '^chore\(task\): (?P<ids><ID>) (?P<from>[A-Z_]+)→(?P<to>[A-Z_]+)')"
if printf '%s' "$md" | grep -q "## 2. Task lifecycle" && printf '%s' "$md" | grep -q "no data - no task-transition lines matched"; then
  ok "strict convention on a foreign repo: tasks section says no data"
else bad "strict convention on a foreign repo: tasks section says no data"; fi
if printf '%s' "$md" | grep -q "## 3. Hook journals" && printf '%s' "$md" | grep -q "no data - no journal files"; then
  ok "missing journal prints no data in markdown"
else bad "missing journal prints no data in markdown"; fi

# --- heuristics for foreign histories: trailer breaks, file areas, version bumps,
#     tolerant ledger parsing, sprint from id, re-fixed tasks, time-joined claims
R3="$TMP/heur"; mkdir -p "$R3" && cd "$R3" || exit 1
git init -q -b main .
AG="Co-Authored-By: Claude Opus 4.1 <noreply@anthropic.com>"
# two work commits per ISO week (Mondays): weeks 1-4 signed, week 5 unsigned (a dip),
# weeks 6-7 signed, weeks 8-10 unsigned (the settings change)
wk=0
for d in 2026-01-05 2026-01-12 2026-01-19 2026-01-26 2026-02-02 2026-02-09 2026-02-16 2026-02-23 2026-03-02 2026-03-09; do
  wk=$((wk + 1))
  if [ "$wk" -eq 5 ] || [ "$wk" -ge 8 ]; then t=""; else t="

$AG"; fi
  c "$d" "feat: work $wk a$t" "src/w$wk.py"
  c "$d" "feat: work $wk b$t" "src/w$wk.py"
done
# fixes: same file twice (recurs at file level), sibling files (recur only at dir level),
# planning files and a lockfile only (no area), a version bump riding along each fix
bump() { mkdir -p svc; printf '{"version": "1.0.%s"}\n' "$1" > svc/package.json; git add svc/package.json; }
bump 0; c 2026-03-10 "feat: svc" svc/a.py
bump 1; c 2026-03-11 "fix: S1-1 first" svc/a.py
bump 2; c 2026-03-14 "fix: S1-1 again" svc/a.py
bump 3; c 2026-03-15 "fix: S1-2 sibling" svc/b.py
bump 4; c 2026-03-15 "fix: S1-2 same day" svc/c.py
c 2026-03-16 "fix: S1-3 S1-4 plan only" SPRINT_1.md TODO.md pnpm-lock.yaml
c 2026-03-19 "fix: S1-3 code" svc/d.py
# hand-written ledger subjects
c 2026-03-20 "chore(sprint): S1-1 TODO→IN_PROGRESS"
c 2026-03-20 "chore(sprint): REVIEW S1-1 IN_PROGRESS -> NEEDS_REVIEW · S1-2 TODO→IN_PROGRESS"
c 2026-03-21 "chore(sprint): S1-1 → IN_PROGRESS (changes requested)"
c 2026-03-21 "docs(sprint2): S2-1, S2-2 todo -> done"
c 2026-03-22 "chore(sprint): S1-2 analysis + root found → NEEDS_REVIEW"
c 2026-03-22 "chore(sprint): S1-2 foo -> bar"
c 2026-03-22 "chore(sprint): S1-3 P2→P1"
c 2026-03-23 "chore(sprint): groom backlog"

J="$TMP/heur.json"
python3 "$M" --json --debug --trailer-min-commits 2 --task-id-regex 'S\d+-\d+' --sprint-from-id '^S(\d+)-' > "$J"
expect_rc "heuristics repo: runs" 0 $?
expect_rc "trailer break found at week 8, not at the one-week dip" '["2026-02-23", null]' "$(q '[r["git"]["trailer_breaks"][0]["from"], r["git"]["trailer_breaks"][0]["to"]]')"
expect_rc "only one trailer break" 1 "$(q 'len(r["git"]["trailer_breaks"])')"
expect_rc "agent share over a break is unreliable, not a number" '[null, true]' "$(q '[r["git"]["summary"]["all"]["agent_coauthored_share"][k] for k in ("value","unreliable")]')"
expect_rc "agent share over covered weeks only" "[12, 14]" "$(q '[r["git"]["summary"]["all"]["agent_coauthored_share_covered"][k] for k in ("num","n")]')"
expect_rc "months in the break are marked" '["2026-02", "2026-03"]' "$(q '[m["month"] for m in r["git"]["monthly"] if m["trailer_break"]]')"
S3='r["git"]["summary"]["all"]'
expect_rc "file area: only svc/a.py recurs; plan-only fix has no area" "[1, 5]" "$(q "[${S3}['recurrence_rate']['num'], ${S3}['recurrence_rate']['n']]")"
expect_rc "version bumps are not an area" false "$(q 'any(h["area"].endswith("package.json") for h in r["git"]["hotspots"])')"
expect_rc "planning files and lockfiles are not an area" false "$(q 'any(h["area"].endswith((".md", ".yaml")) for h in r["git"]["hotspots"])')"
expect_rc "tasks fixed again: S1-1 and S1-3 (3 days apart each)" "[2, 4]" "$(q "[${S3}['tasks_fixed_again']['num'], ${S3}['tasks_fixed_again']['n']]")"
expect_rc "ledger commits are not fixes and not in the share" "[6, 27]" "$(q "[${S3}['fix_share']['num'], ${S3}['fix_share']['n']]")"
T3='r["tasks"]["summary"]["all"]'
expect_rc "tolerant parser: prefix words, middle dot, no from, lowercase, clause" 7 "$(q 'r["tasks"]["n_events"]')"
expect_rc "prose and priorities are not transitions (S1-3 unseen)" 4 "$(q "${T3}['tasks_seen']['value']")"
expect_rc "missing from inferred: S1-1 NEEDS_REVIEW -> IN_PROGRESS is rework" "[1, 2]" "$(q "[${T3}['rework_rate']['num'], ${T3}['rework_rate']['n']]")"
expect_rc "lowercase known statuses parse (S2-* done)" 2 "$(q "${T3}['tasks_done']['value']")"
expect_rc "sprint from task id" '[["1", 2], ["2", 2]]' "$(q '[[x["sprint"], x["tasks"]] for x in r["tasks"]["sprints"]["rows"]]')"
expect_rc "parse coverage: 5 of 8 ledger commits parsed" "[5, 8]" "$(q '[r["tasks"]["parse_coverage"][k] for k in ("ledger_with_transition","ledger_commits")]')"
expect_rc "--debug: unmatched sample, arrow subjects first" '["chore(sprint): S1-2 foo -> bar", "chore(sprint): S1-3 P2->P1", "chore(sprint): groom backlog"]' "$(q '[u["subject"].replace("\u2192", "->") for u in r["tasks"]["parse_coverage"]["unmatched_sample"]]')"
J="$TMP/heur-single.json"
python3 "$M" --json --task-id-regex 'S\d+-\d+' --refix-ids single > "$J"
expect_rc "--refix-ids single: multi-id fix commits ignored" "[1, 3]" "$(q "[${S3}['tasks_fixed_again']['num'], ${S3}['tasks_fixed_again']['n']]")"
J="$TMP/heur-start.json"
python3 "$M" --json --task-id-regex 'S\d+-\d+' --split-date 2026-03-21 --task-period start > "$J"
expect_rc "--task-period start: tasks belong to the period they started in" "[2, 2]" "$(q '[r["tasks"]["summary"][p]["tasks_seen"]["value"] for p in ("before","after")]')"
md="$(python3 "$M" --trailer-min-commits 2 --task-id-regex 'S\d+-\d+')"
if printf '%s' "$md" | grep -q "Warning - trailer-coverage break from 2026-02-23" && printf '%s' "$md" | grep -q "| unreliable (raw "; then
  ok "markdown warns about the break and prints unreliable"; else bad "markdown warns about the break and prints unreliable"; fi
if printf '%s' "$md" | grep -q "Parse coverage (default (tolerant) regex): 62.5% (5/8)"; then
  ok "markdown shows parse coverage"; else bad "markdown shows parse coverage"; fi

# journal without a shared session key: outcomes carry a fixed label, joined by time;
# the subagent type is journaled only from the second session on
A3="$TMP/timelogs"; mkdir -p "$A3"
cat > "$A3/tools.jsonl" <<'EOF'
{"ts":"2026-03-20T07:50:00Z","tool":"Agent","session":"u0"}
{"ts":"2026-03-20T08:00:00Z","tool":"Bash","session":"u0"}
{"ts":"2026-03-20T09:50:00Z","tool":"Agent","session":"u1","detail":"code-reviewer"}
{"ts":"2026-03-20T10:00:00Z","tool":"Bash","session":"u1"}
{"ts":"2026-03-20T11:50:00Z","tool":"Agent","session":"u2","detail":"Explore"}
{"ts":"2026-03-20T12:00:00Z","tool":"Bash","session":"u2"}
EOF
cat > "$A3/outcomes.jsonl" <<'EOF'
{"ts":"2026-03-20T08:02:00Z","session":"label","outcome":"barrier","reviewed":"yes"}
{"ts":"2026-03-20T10:05:00Z","session":"label","outcome":"barrier","reviewed":"Agent(code-reviewer)"}
{"ts":"2026-03-20T11:57:00Z","session":"label","outcome":"barrier","reviewed":true}
{"ts":"2026-03-20T15:00:00Z","session":"label","outcome":"barrier","reviewed":true}
{"ts":"2026-03-20T15:30:00Z","session":"label","outcome":"barrier","reviewed":"inline-self-review"}
EOF
J="$TMP/timelogs.json"
python3 "$M" --json --task-id-regex 'S\d+-\d+' --logs "$A3" > "$J"
G3='r["journal"]["summary"]["all"]'
expect_rc "claims joined by time (fixed session label)" true "$(q 'r["journal"]["claim_join"].startswith("time")')"
expect_rc "untyped subagent era left out of evidence: 1 of 2 typed claims reviewed" "[1, 2]" "$(q "[${G3}['claimed_review_with_evidence']['num'], ${G3}['claimed_review_with_evidence']['n']]")"
expect_rc "upper bound: any subagent in all 3 joined claims" "[3, 3]" "$(q "[${G3}['claimed_review_with_any_subagent']['num'], ${G3}['claimed_review_with_any_subagent']['n']]")"
expect_rc "sessions: the fixed label is not a session" 3 "$(q "${G3}['sessions']['value']")"
expect_rc "journal without task ids: approvals match is no data" null "$(q "${G3}['approvals_with_reviewer_spawn']['value']")"

# echo-me-shaped session: background roles end turns with `waiting`, runtime helper
# SubagentStops (no type, 0 calls) every half minute, the last Stop carries the outcome
A4="$TMP/waitlogs"; mkdir -p "$A4"
cat > "$A4/tools.jsonl" <<'EOF'
{"ts":"2026-03-21T09:00:00Z","event":"pre","session_id":"w1","agent_id":"","agent_type":"","tool":"Bash","detail":"git status"}
EOF
cat > "$A4/outcomes.jsonl" <<'EOF'
{"ts":"2026-03-21T09:01:00Z","event":"Stop","session_id":"w1","agent_id":"","agent_type":"","outcome":"waiting","tool_calls":1}
{"ts":"2026-03-21T09:01:30Z","event":"SubagentStop","session_id":"w1","agent_id":"x1","agent_type":"","outcome":"none","tool_calls":0}
{"ts":"2026-03-21T09:02:00Z","event":"SubagentStop","session_id":"w1","agent_id":"x2","agent_type":"","outcome":"none","tool_calls":0}
{"ts":"2026-03-21T09:03:00Z","event":"SubagentStop","session_id":"w1","agent_id":"a1","agent_type":"developer","outcome":"none","tool_calls":12}
{"ts":"2026-03-21T09:04:00Z","event":"Stop","session_id":"w1","agent_id":"","agent_type":"","outcome":"barrier","tool_calls":3}
{"ts":"2026-03-21T10:00:00Z","event":"Stop","session_id":"w2","agent_id":"","agent_type":"","outcome":"waiting","tool_calls":1}
EOF
cat > "$A4/gates.jsonl" <<'EOF'
{"ts":"2026-03-21T09:02:30Z","event":"gate","gate":"analysis-gate","decision":"warn","session_id":"w1","agent_id":"","agent_type":"","tool":"Edit","reason":"ANALYSIS GATE: T-1"}
{"ts":"2026-03-21T09:02:40Z","event":"gate","gate":"verify-gate","decision":"deny","session_id":"w1","agent_id":"","agent_type":"","tool":"Edit","reason":"VERIFY GATE: T-1"}
EOF
J="$TMP/waitlogs.json"
python3 "$M" --json --logs "$A4" > "$J"
G4='r["journal"]["summary"]["all"]'
B4='r["journal"]["breakdown"]["all"]'
expect_rc "sessions without outcome: by the last Stop (w1 barrier, w2 still waiting)" "[1, 2]" "$(q "[${G4}['sessions_without_outcome']['num'], ${G4}['sessions_without_outcome']['n']]")"
expect_rc "runtime helper SubagentStops are left out of subagent outcomes" "[1, 2]" "$(q "[${B4}['n_subagent_stop_records'], ${B4}['n_runtime_subagent_stops']]")"
expect_rc "gate warnings and denials counted" "[1, 1]" "$(q "[${G4}['gate_warnings']['value'], ${G4}['gate_denials']['value']]")"
expect_rc "gate denials are not permission denials" '{}' "$(q "${B4}['denials_by_tool']")"
python3 "$M" --logs "$A4" | grep -q "Gate decisions: " && ok "markdown shows gate decisions" || bad "markdown shows gate decisions"

# --- config file
python3 "$M" --config "$KIT/template/scripts/metrics/metrics.example.json" >/dev/null; rc=$?
expect_rc "example config is accepted" 0 "$rc"
echo '{"fix_regexp": "x"}' > "$TMP/bad.json"
python3 "$M" --config "$TMP/bad.json" >/dev/null 2>&1; rc=$?
expect_rc "unknown config key is rejected (typos do not silently fall back)" 2 "$rc"

# --- errors
python3 "$M" --repo "$TMP/nope" >/dev/null 2>&1; rc=$?
expect_rc "non-repository is an error, not an empty report" 2 "$rc"
python3 "$M" --transition-regex '(?P<to>\w+)' >/dev/null 2>&1; rc=$?
expect_rc "transition regex without an id group is rejected" 2 "$rc"
python3 "$M" --split-date 2026/03/01 >/dev/null 2>&1; rc=$?
expect_rc "bad date is rejected" 2 "$rc"
finish
