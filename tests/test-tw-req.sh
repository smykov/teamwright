#!/usr/bin/env bash
# Regression: template/scripts/tw-req - one requirement by id: its definition, the spec
# sections and the tasks that name it; nothing that only shares a prefix (FR-1 vs FR-10).
. "$(dirname "$0")/lib.sh"
echo "tw-req"
REQ="$KIT/template/scripts/tw-req"
p="$TMP/proj"; mkdir -p "$p/docs/tasks" "$p/specs/001-x" "$p/docs/process"; cd "$p" || exit 1
git init -q -b main .
cat > docs/requirements.md <<'MD'
# Requirements

| ID | Requirement |
|---|---|
| FR-1 | The system shall start. |
| FR-10 | The system shall stop. |
MD
cat > specs/001-x/spec.md <<'MD'
# Spec

## Start

Covers FR-1: the app starts in the tray.
More detail.

## Stop

Covers FR-10 only.
MD
printf 'FR-1 is also mentioned in a process doc\n' > docs/process/lifecycle.md
printf -- '---\nid: T-1\ntitle: Start in the tray\nstatus: TODO\ndesign_ref: specs/001-x/spec.md#start\n---\nImplements FR-1.\n' > docs/tasks/T-1.md
printf -- '---\nid: T-2\ntitle: Stop\nstatus: DONE\n---\nImplements FR-10.\n' > docs/tasks/T-2.md
printf '| ID | Question | Status |\n|---|---|---|\n| OQ-01 | Which tray? | open |\n' > docs/open-questions.md
q() { python3 "$REQ" --json "$@" | python3 -c "import json,sys; d=json.load(sys.stdin); print($Q)"; }
Q='d[0]["definition"]'; expect_rc "definition row of FR-1, not FR-10" "| FR-1 | The system shall start. |" "$(q FR-1)"
Q='" ".join(s["section"] for s in d[0]["sections"])'; expect_rc "only the section that names FR-1; process docs skipped" "Spec › Start" "$(q FR-1)"
Q='" ".join(t["task"]+":"+t["status"] for t in d[0]["tasks"])'; expect_rc "tasks naming FR-1 only" "T-1:TODO" "$(q FR-1)"
Q='d[0]["open_question"]'; expect_rc "open question row" "| OQ-01 | Which tray? | open |" "$(q oq-01)"
python3 "$REQ" FR-99 >/dev/null; expect_rc "unknown id exits 1" 1 "$?"
python3 "$REQ" FR-10 | grep -q "Covers FR-10 only" && ok "human output includes the section text" || bad "human output includes the section text"
finish
