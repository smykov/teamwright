#!/usr/bin/env bash
# Regression: scripts/tw-groom.py - facts about the open backlog before a sprint (#26, #38):
# each finding kind on its own record, plan stages the records do not cover, read-only.
. "$(dirname "$0")/lib.sh"
echo "tw-groom"
G="$KIT/scripts/tw-groom.py"
mk() {  # mk ID STATUS [key: value lines...]
  local id="$1" st="$2"; shift 2
  mkdir -p docs/tasks
  { echo "---"; echo "id: $id"; echo "title: task $id"; echo "type: feature"; echo "status: $st"
    echo "priority: P2"; echo "deploys: false"; echo "surface: none"
    for l in "$@"; do echo "$l"; done; echo "---"; echo; echo "## Context"; echo; echo body; } > "docs/tasks/$id.md"
}
kinds() { python3 "$G" --project . --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(sorted({f['kind'] for r in d['records'] if r['id']=='$1' for f in r['findings']}))"; }
stage() { python3 "$G" --project . --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(sorted(f['kind'] for s in d['stages'] if s['stage'].startswith('$1') for f in s['findings']))"; }

mkdir -p "$TMP/empty" && cd "$TMP/empty" || exit 1
python3 "$G" --project . >/dev/null 2>&1; expect_rc "no docs/tasks: exit 2" 2 "$?"

p="$TMP/proj"; mkdir -p "$p/app" "$p/docs" "$p/.teamwright"; cd "$p" || exit 1
git init -q -b main .
echo a > app/a.py; echo b > app/b.py
printf '| ID | Question | Status |\n|---|---|---|\n| OQ-01 | q | answered |\n| OQ-02 | q | open |\n' > docs/open-questions.md
mk T-1 TODO 'analysis:' '  seam: "app/a.py"'                     # possibly done
mk T-2 TODO 'analysis:' '  seam: "app/b.py"'                     # seam changed
mk T-3 TODO 'analysis:' '  seam: "app/gone.py"'                  # missing path
mk T-4 TODO                                                      # no seam
mk T-5 BLOCKED 'blocked_on: "OQ-01, T-9"' 'analysis:' '  seam: "app/c.py"'   # settled
mk T-6 TODO 'blocked_on: "OQ-02"' 'analysis:' '  seam: "app/d.py"'          # not settled
mk T-7 TODO 'priority: P3' 'analysis:' '  seam: "app/e.py"'      # inherits P1 from T-8
mk T-8 TODO 'priority: P1' 'depends_on: [T-7]' 'analysis:' '  seam: "app/f.py"'
mk T-9 DONE
mk T-10 DEFERRED 'absorbed_by: T-9'                               # absorbed-done
mk T-11 TODO 'type: chore' 'class: from-follow-up' 'analysis:' '  seam: "app/g.py"'
for i in $(seq 1 11); do echo "- [ ] item $i" >> docs/tasks/T-11.md; done  # too large
mk T-12 TODO 'class: input-parsing' 'analysis:' '  seam: "app/h.py"'
mk T-13 TODO 'class: input-parsing' 'analysis:' '  seam: "app/h.py"'    # duplicate of T-12
mk T-14 TODO 'analysis:' '  seam: "app/i.py"'
printf -- '- see `app/a.py:12` and `docs/nowhere.md#x` and `https://x.example/a/b`\n' >> docs/tasks/T-14.md
touch app/c.py app/d.py app/e.py app/f.py app/g.py app/h.py app/i.py
cat > docs/plan.md <<'MD'
# Plan

## Stages

| Stage | Scope (FR-NN) | Done when | Target date | Status |
|---|---|---|---|---|
| 0 — Skeleton | FR-01, FR-02 | runs | 2026-01-01 | not started |
| 1 — Export | FR-03 | csv works | 2026-02-01 | not started |
| 2 — Release | FR-04 | shipped, README | 2026-03-01 | not started |
MD
printf '\nFR-01\n' >> docs/tasks/T-9.md
git add -A; git commit -qm init
echo "# T-1 done here" >> app/a.py; git commit -qam "fix(T-1): the thing"
echo more >> app/b.py; git commit -qam "refactor b"
git commit -q --allow-empty -m "chore: T-10x is another id, T-12 named only in passing"

expect_rc "a commit naming the task after its record: possibly done (its seam changed too)" "['possibly-done', 'seam-changed']" "$(kinds T-1)"
expect_rc "its seam changed after the record" "['seam-changed']" "$(kinds T-2)"
expect_rc "a seam path that does not exist" "['missing-path']" "$(kinds T-3)"
expect_rc "TODO with no seam" "['no-seam']" "$(kinds T-4)"
expect_rc "BLOCKED on an answered question and a DONE task: settled" "['settled']" "$(kinds T-5)"
expect_rc "blocked_on an open question: not settled" "[]" "$(kinds T-6)"
expect_rc "a P3 prerequisite of a P1 task" "['inherits-priority']" "$(kinds T-7)"
expect_rc "DEFERRED whose absorbed_by is DONE" "['absorbed-done']" "$(kinds T-10)"
expect_rc "a from-follow-up task over the size limit" "['too-large']" "$(kinds T-11)"
expect_rc "same class and the same seam: duplicate" "['duplicate', 'possibly-done']" "$(kinds T-12)"
expect_rc "a path in Context that is gone (a line number and a URL are not paths to check)" \
  "['docs/nowhere.md']" "$(python3 "$G" --project . --json | python3 -c "import json,sys; d=json.load(sys.stdin); print([f['evidence'] for r in d['records'] if r['id']=='T-14' for f in r['findings'] if f['kind']=='missing-path'][0])")"
expect_rc "an id inside a longer id is not a mention" "[]" \
  "$(python3 "$G" --project . --json | python3 -c "import json,sys; d=json.load(sys.stdin); print([f for r in d['records'] if r['id']=='T-10' for f in r['findings'] if f['kind']=='possibly-done'])")"
expect_rc "a stage with its FR named by a DONE task, plan still 'not started'" "['frs-without-tasks', 'plan-status-stale']" "$(stage 0)"
expect_rc "a stage no task names" "['stage-empty']" "$(stage 1)"
expect_rc "a release stage no task names" "['release-stage-empty']" "$(stage 2)"
python3 "$G" --project . --json --old-days 0 | python3 -c 'import json,sys; d=json.load(sys.stdin); assert any(f["kind"]=="old" for r in d["records"] for f in r["findings"])' \
  && ok "--old-days: an unchanged record is old" || bad "--old-days: an unchanged record is old"
printf '{"milestone": {"name": "m1", "stages": ["0 — Skeleton", "Beta"]}}\n' > .teamwright/progress.json
expect_rc "a milestone stage that is not in the plan" "['milestone-stage-missing']" \
  "$(python3 "$G" --project . --json | python3 -c 'import json,sys; print([f["kind"] for f in json.load(sys.stdin)["milestone"]])')"
before="$(git status --porcelain)"
python3 "$G" --project . | grep -q "^open tasks: " && ok "human output" || bad "human output"
expect_rc "read-only: the tree is unchanged" "$before" "$(git status --porcelain)"
cd "$KIT" || exit 1

finish
