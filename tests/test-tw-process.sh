#!/usr/bin/env bash
# Regression: scripts/tw-process.py - the cost facts /teamwright:improve reads: findings by
# severity and category under the threshold in force, settings history, ratified tails,
# bookkeeping share, record sizes, open follow-ups.
. "$(dirname "$0")/lib.sh"
echo "tw-process"
PR="$KIT/scripts/tw-process.py"
q() { python3 "$PR" --project . --json | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
p="$TMP/proj"; mkdir -p "$p/.teamwright" "$p/docs/tasks/T-1.reviews"; cd "$p" || exit 1
git init -q -b main .
printf 'version: 1\nareas:\n  - name: core\n' > .teamwright/config.yml
task_file docs/tasks/T-1.md T-1 IN_PROGRESS bug full
rv() {  # rv N VERDICT rows...
  local n="$1" v="$2"; shift 2
  { printf -- '---\ntask: T-1\nround: %s\nreviewer: code-reviewer\nverdict: %s\n---\n\n## Findings\n\n| # | Severity | Category | Where | Finding | Required change |\n|---|---|---|---|---|---|\n' "$n" "$v"
    local r; for r in "$@"; do printf '| 1 | %s | %s | a:1 | x | y |\n' "${r%%|*}" "${r##*|}"; done; } > "docs/tasks/T-1.reviews/$n.md"
}
rv 1 REQUEST_CHANGES "Low|docs-drift" "Low|toothless-test"
git add -A; git commit -qm "chore(task): T-1 review 1"
printf 'process:\n  review:\n    blocking: medium\n' >> .teamwright/config.yml
git add -A; git commit -qm "chore: settings"
rv 2 REQUEST_CHANGES "Medium|correctness" "Low|docs-drift"
printf 'tail_code: ratified\n' >> docs/tasks/T-1.md
git add -A; git commit -qm "chore(task): T-1 review 2"
printf -- '---\nid: T-9\ntitle: Review follow-ups - sprint 1\ntype: chore\nstatus: TODO\nclass: review-follow-up\n---\n\n## Acceptance\n\n- [ ] T-1 r2#2 Low docs-drift\n- [x] old\n- [ ] T-1 r1#1 Low docs-drift\n' > docs/tasks/T-9.md
git add -A; git commit -qm "chore(task): T-9 follow-ups"

expect_rc "verdicts and send-back share" "2 1.0" "$(q '"%d %s" % (d["verdicts"]["REQUEST_CHANGES"], d["send_back_share"])')"
expect_rc "findings by severity" "low:3 medium:1" "$(q '" ".join("%s:%d" % kv for kv in sorted(d["findings"]["by_severity"].items()))')"
expect_rc "returned by category uses the threshold in force (low, then medium)" "correctness:1 docs-drift:1 toothless-test:1" \
  "$(q '" ".join("%s:%d" % kv for kv in sorted(d["findings"]["returned_by_category"].items()))')"
expect_rc "settings history: default, then medium" "low medium" "$(q '" ".join(h["settings"]["review"]["blocking"] for h in d["settings_history"])')"
expect_rc "ratified tails counted" "1" "$(q 'd["ratified"]["count"]')"
expect_rc "bookkeeping share" "3 of 4" "$(q '"%d of %d" % (d["bookkeeping"]["chore_task"], d["bookkeeping"]["commits"])')"
expect_rc "open follow-up items" "2" "$(q 'd["follow_ups"]["open_items"]')"
finish
