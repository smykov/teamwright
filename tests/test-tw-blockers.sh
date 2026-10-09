#!/usr/bin/env bash
# Regression: scripts/tw-blockers.py - everything waiting for a person, with what each
# answer unblocks: open questions (named in blocked_on or only mentioned), escalated
# reviews, NEEDS_OWNER acceptance, BLOCKED and held tasks, stale blocked_on, the tree.
. "$(dirname "$0")/lib.sh"
echo "tw-blockers"
BL="$KIT/scripts/tw-blockers.py"
mk() {  # mk ID STATUS PRIORITY [key: value lines...]
  local id="$1" st="$2" pr="$3"; shift 3
  mkdir -p docs/tasks
  { echo "---"; echo "id: $id"; echo "title: task $id"; echo "type: feature"; echo "status: $st"
    echo "priority: $pr"; echo "deploys: true"; echo "surface: api"
    for l in "$@"; do echo "$l"; done; echo "---"; echo body; } > "docs/tasks/$id.md"
}
rec() {  # rec ID KIND(reviews|validation) VERDICT
  local d="docs/tasks/$1.$2"; mkdir -p "$d"
  printf -- '---\ntask: %s\nround: 1\nverdict: %s\ncommit: %s\n---\n%s\n' "$1" "$3" "$(git rev-parse HEAD)" "${4:-}" > "$d/1.md"
}
q() { python3 "$BL" --project . --json | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

mkdir -p "$TMP/empty" && cd "$TMP/empty" || exit 1
expect_rc "no docs/tasks: not installed" False "$(q 'd["installed"]')"

p="$TMP/proj"; mkdir -p "$p/docs"; cd "$p" || exit 1
git init -q -b main .
cat > docs/open-questions.md <<'MD'
# Open questions

| ID | Question | Blocks | Options | Asked | Status |
|---|---|---|---|---|---|
| OQ-01 | Which payment provider? | T-1 | A / B | 2026-10-01 | open |
| OQ-02 | Dark mode in v1? | — | yes / no | 2026-10-01 | answered → decisions.md #3 |
| OQ-03 | Export format? | — | csv / xlsx | 2026-10-02 | open |
MD
mk T-1 TODO P1 "blocked_on: OQ-01" "depends_on: []"
mk T-2 TODO P2 "depends_on: [T-1]"
mk T-3 TODO P3 "blocked_on: OQ-02" "depends_on: []"
mk T-4 BLOCKED P2 "blocked_on: production API key from the provider" "depends_on: []"
mk T-5 TODO P3 "blocked_on: test on a real phone" "depends_on: []"
mk T-6 NEEDS_REVIEW P2 "depends_on: []"
mk T-7 CODE_COMPLETE P2 "depends_on: []" "deploys: false"
mk T-8 DONE P2 "blocked_on: OQ-03" "depends_on: []"
printf 'see OQ-03 for the format\n' >> docs/tasks/T-5.md
git add -A; git commit -qm init
rec T-6 reviews ESCALATE; rec T-7 validation NEEDS_OWNER "needs a signed-in account on the device"
git add -A; git commit -qm records

expect_rc "question OQ-01 holds T-1 and, through depends_on, T-2" "['T-1', 'T-2']" \
  "$(q '[i for i in d["items"] if i["id"]=="OQ-01"][0]["unblocks"]')"
expect_rc "the P1 question comes first" "OQ-01" "$(q 'd["items"][0]["id"]')"
expect_rc "an answered question is not listed" "[]" "$(q '[i["id"] for i in d["items"] if i["id"]=="OQ-02"]')"
expect_rc "an open question only mentioned is listed with who mentions it" "['T-5']" \
  "$(q '[i for i in d["items"] if i["id"]=="OQ-03"][0]["mentioned_by"]')"
expect_rc "a DONE task blocked_on does not count" "[]" "$(q '[i for i in d["items"] if i["id"]=="OQ-03"][0]["tasks"]')"
expect_rc "stale blocked_on (answered question) is reported" "1" "$(q 'len([w for w in d["stale"] if w.startswith("T-3")])')"
expect_rc "BLOCKED on a key: class credentials" "blocked credentials" \
  "$(q '" ".join([(i["kind"], i["cls"]) for i in d["items"] if i["id"]=="T-4"][0])')"
expect_rc "TODO held on a phone test: class device" "held device" \
  "$(q '" ".join([(i["kind"], i["cls"]) for i in d["items"] if i["id"]=="T-5"][0])')"
expect_rc "ESCALATE review is a decision with its record to read" "escalated docs/tasks/T-6.reviews/1.md" \
  "$(q '" ".join([(i["kind"], i["evidence"][0]) for i in d["items"] if i["id"]=="T-6"][0])')"
expect_rc "NEEDS_OWNER acceptance, class from the record" "acceptance credentials" \
  "$(q '" ".join([(i["kind"], i["cls"]) for i in d["items"] if i["id"]=="T-7"][0])')"
expect_rc "no tree item on a clean committed repo" "[]" "$(q '[i for i in d["items"] if i["kind"]=="tree"]')"
echo x > dirty.txt; git add dirty.txt
expect_rc "staged changes become a tree item" "1" "$(q 'len([i for i in d["items"] if i["kind"]=="tree"])')"
python3 "$BL" --project . | grep -q "^Waiting for a person: " && ok "human output" || bad "human output"
finish
