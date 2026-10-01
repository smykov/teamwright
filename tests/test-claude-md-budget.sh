#!/usr/bin/env bash
# Regression: claude-md-budget.sh (SessionStart + pre-commit warning, P-014).
. "$(dirname "$0")/lib.sh"
echo "claude-md-budget"
export TEAMWRIGHT_NO_GITLEAKS=1
new_repo "$TMP/repo"
B="scripts/hooks/claude-md-budget.sh"
export CLAUDE_PROJECT_DIR="$TMP/repo"
head -c 2000 /dev/zero | tr '\0' 'a' > CLAUDE.md
out="$(echo '{}' | bash "$B" --session-start)"
expect_allow "small CLAUDE.md: SessionStart prints nothing" "$out"
head -c 42000 /dev/zero | tr '\0' 'a' > CLAUDE.md
out="$(echo '{}' | bash "$B" --session-start)"
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "budget" in d["hookSpecificOutput"]["additionalContext"]'; then
  ok "over 40 KB: SessionStart adds a warning as additionalContext"; else bad "SessionStart warning" "$out"; fi
out="$(echo '{}' | TEAMWRIGHT_CLAUDE_MD_MAX_KB=100 bash "$B" --session-start)"
expect_allow "budget is configurable" "$out"
git add CLAUDE.md; git commit -qm "docs: big map" 2>"$TMP/err"; expect_rc "pre-commit never blocks on size" 0 "$?"
grep -q "over its 40 KB budget" "$TMP/err" && ok "pre-commit warns about the staged size" || bad "pre-commit warns about the staged size"
echo x > other.txt; git add other.txt; git commit -qm "chore: other" 2>"$TMP/err"
grep -q "budget" "$TMP/err" && bad "no warning when CLAUDE.md is not staged" || ok "no warning when CLAUDE.md is not staged"
finish
