#!/usr/bin/env bash
# Regression: install-hooks.sh
. "$(dirname "$0")/lib.sh"
echo "install-hooks"
new_repo "$TMP/repo"
expect_rc "core.hooksPath points at scripts/hooks" "scripts/hooks" "$(git config core.hooksPath)"
for pat in '.teamwright/sessions/' '.teamwright/logs/' '.teamwright/current-task' 'TEAMWRIGHT_PAUSE' '*.local.json' '.env'; do
  grep -qxF -- "$pat" .gitignore && ok "gitignore has $pat" || bad "gitignore has $pat"
done
bash scripts/install-hooks.sh >/dev/null
expect_rc "re-run does not duplicate gitignore lines" 1 "$(grep -cxF 'TEAMWRIGHT_PAUSE' .gitignore)"
bash scripts/install-hooks.sh --check >/dev/null; expect_rc "--check passes when enabled" 0 "$?"
git config --unset core.hooksPath
bash scripts/install-hooks.sh --check >/dev/null 2>&1; expect_rc "--check fails when disabled" 1 "$?"
for h in pre-commit commit-msg pre-push; do
  [ -x "scripts/hooks/$h" ] && ok "$h is executable" || bad "$h is executable"
done
finish
