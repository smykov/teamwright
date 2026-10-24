#!/usr/bin/env bash
# Regression: scripts/tw-parallel.py and the router's worktree rules - analysed tasks with
# disjoint seams go to their own worktrees; a seam without a path runs alone; the main
# tree skips them and offers merge when approved; a worktree session sees its own task only.
. "$(dirname "$0")/lib.sh"
echo "tw-parallel"
PAR="$KIT/scripts/tw-parallel.py"; NEXT="$KIT/scripts/tw-next.py"
mk() {  # mk ID STATUS SEAM [complete|incomplete]
  mkdir -p docs/tasks
  { printf -- '---\nid: %s\ntitle: task %s\ntype: feature\nstatus: %s\npriority: P2\ndepends_on: []\nsurface: api\n' "$1" "$1" "$2"
    if [ "${4:-complete}" = complete ]; then
      printf 'analysis:\n  root_cause: need\n  evidence: FR-01\n  invariant: holds\n  seam: "%s"\n  approach: do it\n' "$3"
    else printf 'analysis:\n  root_cause: ""\n'; fi
    printf -- '---\nbody\n'; } > "docs/tasks/$1.md"
}
p="$TMP/proj"; mkdir -p "$p/.teamwright"; cd "$p" || exit 1
git init -q -b main .
printf '.teamwright/logs/\n.teamwright/current-task\n' > .gitignore
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\nprocess:\n  batch:\n    parallel: 2\n' > .teamwright/config.yml
mk T-1 ANALYSIS "src/a/"
mk T-2 ANALYSIS "\`src/b/x.py\` (parse)"
mk T-3 ANALYSIS "src/a/y.py:12"
mk T-4 ANALYSIS "Router::route"
mk T-5 ANALYSIS "" incomplete
git add -A; git commit -qm init
pq() { python3 "$PAR" "$@" --project . | python3 -c "import json,sys; d=json.load(sys.stdin); print($Q)"; }
Q='" ".join(g["id"] for g in d["group"])'; expect_rc "disjoint analysed tasks form the group" "T-1 T-2" "$(pq plan)"
Q='"; ".join(s["task"]+": "+s["why"] for s in d["skipped"])'
pq plan | grep -q "T-3: seam overlaps T-1" && ok "nested path overlaps" || bad "nested path overlaps" "$(pq plan)"
pq plan | grep -q "T-4: seam names no path" && ok "seam without a path runs alone" || bad "seam without a path runs alone"
Q='" ".join(d["analysis_incomplete"])'; expect_rc "incomplete analysis is not grouped" "T-5" "$(pq plan)"

python3 "$PAR" start T-1 T-2 --project . > "$TMP/start.json"; expect_rc "start creates the worktrees" 0 "$?"
WT1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["path"])' "$TMP/start.json")"
[ -d "$WT1" ] && git -C "$WT1" rev-parse --abbrev-ref HEAD | grep -qx "tw/T-1" && ok "worktree on tw/T-1" || bad "worktree on tw/T-1"
grep -q '/teamwright:flow T-1' "$TMP/start.json" && ok "launch command printed" || bad "launch command printed"
python3 "$PAR" start T-3 --project . >/dev/null; expect_rc "a task outside the group is refused" 1 "$?"

nx() { python3 "$NEXT" --project "${1:-.}" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"], d["task"])'; }
alts() { python3 "$NEXT" --project . --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted({x["task"] or "" for x in [d]+d["alternatives"]})))'; }
alts | grep -qw "T-1" && bad "main tree skips tasks running in worktrees" || ok "main tree skips tasks running in worktrees"
expect_rc "worktree session sees only its own task" "continue T-1" "$(nx "$WT1")"

sedi 's/^status: .*/status: CODE_COMPLETE/' "$WT1/docs/tasks/T-1.md"
git -C "$WT1" commit -qam "chore(task): T-1 →CODE_COMPLETE"
expect_rc "approved on its branch: main tree offers merge" "merge T-1" \
  "$(python3 "$NEXT" --project . --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(("%s %s" % (x["action"], x["task"]) for x in [d]+d["alternatives"] if x["action"]=="merge"), "none"))')"
expect_rc "worktree session is done (verify follows the merge)" "idle T-1" "$(nx "$WT1")"
Q='" ".join("%s:%s:%s" % (w["task"], w["status"], w["ready_to_merge"]) for w in d["worktrees"])'
expect_rc "status reads the record on each branch" "T-1:CODE_COMPLETE:True T-2:ANALYSIS:False" "$(pq status)"

mkdir -p "$WT1/.teamwright/logs" .teamwright/logs
printf '{"event":"Stop","outcome":"barrier"}\n' > "$WT1/.teamwright/logs/outcomes.jsonl"
printf '{"event":"Stop","outcome":"idle"}\n' > .teamwright/logs/outcomes.jsonl
python3 "$PAR" logs T-1 --project . >/dev/null
expect_rc "worktree journal appended to the main one" 2 "$(wc -l < .teamwright/logs/outcomes.jsonl | tr -d ' ')"

# ---- prepare / launch / run: each worktree's stages run headless, one stage per session ----
WT2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[1]["path"])' "$TMP/start.json")"
FAKE="$TMP/fake-claude"
cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
# a stage session: moves the worktree's task one status forward and commits
b=$(git rev-parse --abbrev-ref HEAD); f="docs/tasks/${b#tw/}.md"; echo "$*" >> "$TW_FAKE_LOG"
case "$(sed -n 's/^status: *//p' "$f")" in
  ANALYSIS) n=IN_PROGRESS ;; IN_PROGRESS) n=NEEDS_REVIEW ;; NEEDS_REVIEW) n=CODE_COMPLETE ;; *) exit 0 ;;
esac
sed -i.bak "s/^status: .*/status: $n/" "$f" && rm -f "$f.bak"
git commit -qam "chore(task): $n" && exit 0
SH
chmod +x "$FAKE"
Q='" ".join("%s:%s" % (x["task"], x.get("index", x.get("error", ""))) for x in d)'
expect_rc "prepare without a context provider: nothing to prepare" "T-2:nothing to prepare" "$(pq prepare T-2)"
expect_rc "prepare needs the worktree" "T-9:no worktree for T-9 (start it first)" "$(pq prepare T-9)"
export TW_FAKE_LOG="$TMP/fake.log"; : > "$TW_FAKE_LOG"
TW_CLAUDE="$FAKE" TEAMWRIGHT_CLAUDE_ARGS="--x" python3 "$PAR" run T-2 --project . > "$TMP/run.json"
Q='d["outcome"] + " " + d["status"]'; expect_rc "run drives the worktree's task to CODE_COMPLETE" "done CODE_COMPLETE" "$(python3 -c "import json; d=json.load(open('$TMP/run.json')); print($Q)")"
grep -q -- "-p /teamwright:" "$TW_FAKE_LOG" && ok "each stage is a claude -p session with the router's prompt" || bad "claude -p with the router's prompt" "$(cat "$TW_FAKE_LOG")"
expect_rc "one session per stage" 3 "$(wc -l < "$TW_FAKE_LOG" | tr -d ' ')"
Q='" ".join("%s:%s" % (w["task"], (w["run"] or {}).get("outcome")) for w in d["worktrees"])'
expect_rc "status shows the run's outcome" "T-1:None T-2:done" "$(pq status)"
# a stage that moves nothing twice stops the run
NOOP="$TMP/noop-claude"; printf '#!/bin/sh\nexit 0\n' > "$NOOP"; chmod +x "$NOOP"
sedi 's/^status: .*/status: ANALYSIS/' "$WT2/docs/tasks/T-2.md"; git -C "$WT2" commit -qam "back"
TW_CLAUDE="$NOOP" python3 "$PAR" run T-2 --project . > "$TMP/run2.json"
expect_rc "two stages that move nothing: stuck" "stuck" "$(python3 -c "import json; print(json.load(open('$TMP/run2.json'))['outcome'])")"
touch TEAMWRIGHT_PAUSE
TW_CLAUDE="$FAKE" python3 "$PAR" run T-2 --project . > "$TMP/run3.json"
expect_rc "TEAMWRIGHT_PAUSE stops the run" "paused" "$(python3 -c "import json; print(json.load(open('$TMP/run3.json'))['outcome'])")"
rm -f TEAMWRIGHT_PAUSE
# launch: background, capped by process.batch.parallel (2 here)
TW_CLAUDE="$FAKE" python3 "$PAR" launch T-2 --project . > "$TMP/launch.json"
grep -q '"launched": true' "$TMP/launch.json" && ok "launch starts the run in the background" || bad "launch" "$(cat "$TMP/launch.json")"
for i in $(seq 1 50); do o=$(python3 -c "import json; print(json.load(open('.teamwright/parallel/T-2.json')).get('outcome',''))"); [ -n "$o" ] && break; sleep 0.2; done
expect_rc "the background run finishes" "done" "$o"
finish
