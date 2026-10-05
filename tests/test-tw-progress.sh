#!/usr/bin/env bash
# Regression: scripts/tw-progress.py - the /teamwright:progress report. Counts come from the
# records, the plan and the adaptation file; areas never guessed; the router decides "next".
. "$(dirname "$0")/lib.sh"
echo "tw-progress"
PROG="$KIT/scripts/tw-progress.py"

mk() {  # mk ID STATUS [key: value lines...]
  local id="$1" st="$2"; shift 2
  mkdir -p docs/tasks
  { echo "---"; echo "id: $id"; echo "title: task $id"; echo "type: feature"; echo "status: $st"
    echo "sprint: 1"; echo "priority: P2"; echo "depends_on: []"; echo "deploys: true"; echo "surface: api"
    for l in "$@"; do echo "$l"; done; echo "---"; echo body; } > "docs/tasks/$id.md"
}
j() { python3 "$PROG" --project . --json; }
q() { j | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# ---- not adopted ----------------------------------------------------------------------
mkdir -p "$TMP/empty" && cd "$TMP/empty" || exit 1
expect_rc "no docs/tasks: not installed" False "$(q 'd["installed"]')"

# ---- a project ---------------------------------------------------------------------------
p="$TMP/proj"; mkdir -p "$p/.teamwright" "$p/docs/sprints"; cd "$p" || exit 1
git init -q -b main .
cat > .teamwright/config.yml <<'EOF'
version: 1
mode: gate-first
areas:
  - name: ui
    source_dirs: [src]
  - name: core
    source_dirs: [src-tauri/src]
EOF
cat > docs/plan.md <<'EOF'
# Plan

## Stages

| Stage | Scope (FR-NN) | Done when | Target date | Status |
|---|---|---|---|---|
| 0 — Skeleton | FR-01 | it starts | 2026-11-01 | started |
| 1 — Core | FR-02, FR-03 | it works | <date> | not started |

## Out of scope (for now)
EOF
printf '# Sprint 1 — start\n\n## Goal\n\nShip the skeleton.\n\n## Forks (owner decisions needed)\n\n| Question | Options | Decided | decisions.md # |\n|---|---|---|---|\n| Which DB? | A / B | pending | — |\n' > docs/sprints/1.md
mk T-1 DONE "design_ref: FR-01" "analysis:" '  seam: "src/app.ts"'
mk T-2 TODO "design_ref: FR-02" "analysis:" '  seam: "src-tauri/src/main.rs"'
mk T-3 DEFERRED "design_ref: FR-02"
mk T-4 BLOCKED "blocked_on: owner decision on the DB" "design_ref: FR-02"
mk T-5 TODO
git add -A; git commit -qm init

expect_rc "done counts DONE, DEFERRED left out" "1 4 1 25" \
  "$(q '" ".join(str(d["total"][k]) for k in ("done","total","deferred","pct"))')"
expect_rc "longest directory wins: src-tauri/src is core, not ui" "ui:1 core:1 unassigned:2" \
  "$(q '" ".join("%s:%d" % (a["area"], a["total"]) for a in d["by_area"])')"
expect_rc "unanalysed tasks stay unassigned, flagged" "T-4:False T-5:False" \
  "$(q '" ".join("%s:%s" % (u["task"], u["analysed"]) for u in d["unassigned"])')"
expect_rc "stage counts by FR named in the task" "1/1 0/2" \
  "$(q '" ".join("%d/%d" % (s["done"], s["total"]) for s in d["by_stage"])')"
expect_rc "an FR with no task is reported" "FR-03" "$(q '" ".join(d["by_stage"][1]["frs_without_tasks"])')"
expect_rc "current stage is the first unfinished" "1 — Core" "$(q 'd["current_stage"]')"
expect_rc "sprint goal and pending fork" "Ship the skeleton. Which DB?" \
  "$(q 'd["by_sprint"][0]["goal"] + " " + d["owner"]["pending_forks"][0]["fork"]')"
expect_rc "owner decisions come from the router" "decide T-4" \
  "$(q '" ".join("%s %s" % (x["action"], x["task"]) for x in d["owner"]["decisions"])')"
expect_rc "next equals tw-next's decision" \
  "$(python3 "$KIT/scripts/tw-next.py" --project . --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["action"], d["task"])')" \
  "$(q 'd["next"]["action"] + " " + str(d["next"]["task"])')"
expect_rc "no adaptation: adapted false, no milestone" "False None" "$(q 'str(d["adapted"]) + " " + str(d["milestone"])')"

# ---- adaptation ----------------------------------------------------------------------------
cat > .teamwright/progress.json <<'EOF'
{"areas": {"T-5": "docs"},
 "area_rules": [{"area": "ui", "pattern": "task T-4$"}],
 "milestone": {"name": "MVP", "stages": ["0 — Skeleton", "1 — Core", "9 — Missing"]},
 "extra_command": "printf '{\"spec_tasks\": 7}'"}
EOF
expect_rc "per-task override and rule: ui 2, core 1, docs 1, nothing unassigned" "ui:2 core:1 docs:1 unassigned:0" \
  "$(q '" ".join("%s:%d" % (a["area"], a["total"]) for a in d["by_area"])')"
expect_rc "milestone over its stages" "MVP 1/3 9 — Missing" \
  "$(q '"%s %d/%d %s" % (d["milestone"]["name"], d["milestone"]["done"], d["milestone"]["total"], d["milestone"]["missing_stages"][0])')"
expect_rc "extra command output reported apart from the counts" "7 4" "$(q 'str(d["extra"]["spec_tasks"]) + " " + str(d["total"]["total"])')"

echo '{"extra_command": "exit 3"}' > .teamwright/progress.json
q '"\n".join(d["errors"])' | grep -q "exited 3" && ok "a failing extra command is an error, not a crash" \
  || bad "a failing extra command is an error, not a crash"
echo '{broken' > .teamwright/progress.json
q '"\n".join(d["errors"])' | grep -q "progress.json" && ok "a broken progress.json is reported" \
  || bad "a broken progress.json is reported"
python3 "$PROG" --project . | grep -q "^teamwright progress" && ok "human output" || bad "human output"

finish
