#!/usr/bin/env bash
# Regression: docs/security/threat-model.md names files, code and tests that exist, and
# claims no control without saying how it is checked (scripts/check-threat-model.py).
. "$(dirname "$0")/lib.sh"
echo "threat model"
C="$KIT/scripts/check-threat-model.py"
DOC="$KIT/docs/security/threat-model.md"
out="$(python3 "$C" 2>&1)"; rc=$?
expect_rc "the document matches the repository${out:+ ($out)}" 0 "$rc"

# broken BEFORE AFTER DESCRIPTION NEEDLE: the checker must catch one changed word
broken() {
  python3 -c 'import sys; s=open(sys.argv[1],encoding="utf-8").read(); assert sys.argv[2] in s, sys.argv[2]; open(sys.argv[4],"w",encoding="utf-8").write(s.replace(sys.argv[2],sys.argv[3],1))' \
    "$DOC" "$1" "$2" "$TMP/doc.md" || { bad "$3" "fixture text not found: $1"; return; }
  out="$(python3 "$C" --doc "$TMP/doc.md" 2>&1)"; rc=$?
  expect_rc "$3" 1 "$rc"
  case "$out" in *"$4"*) ok "$3: says so" ;; *) bad "$3: says so" "$out" ;; esac
}
broken '`tests/test-pre-commit.sh::finding' '`tests/test-gone.sh::finding' "a missing test file is caught" "no such file"
broken 'pre-commit::scan_diff' 'pre-commit::no_such_symbol' "a missing symbol is caught" "does not contain"
broken '| TM-06 |' '| TM-05 |' "a duplicate id is caught" "duplicate id"
broken '`tests/test-review-gate.sh::developer subagent cannot write the review`; `tests/test-review-gate.sh::an implementing agent id stays denied even with reviewer type`' 'no test' "mitigated without a test is caught" "mitigated without a test"
broken ' | partial | Regexes' ' | safe | Regexes' "an unknown status is caught" "unknown status"
broken '| B5 | T, E | Agents' '| B99 | T, E | Agents' "an unknown boundary is caught" "unknown boundary"
broken '(TM-21)' '(TM-99)' "a tree leaf without a row is caught" "TM-99"
finish
