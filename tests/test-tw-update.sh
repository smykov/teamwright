#!/usr/bin/env bash
# Regression: tw-install.py update - updates the plugin through the claude CLI, finds the copy
# Claude Code installed for this project, and runs plan (or apply) from that copy.
. "$(dirname "$0")/lib.sh"
echo "tw-install update"
I="$KIT/scripts/tw-install.py"
p="$TMP/proj"; mkdir -p "$p/.teamwright" "$p/.claude"; cd "$p" || exit 1
git init -q -b main .
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\n' > .teamwright/config.yml
printf '{"enabledPlugins": {"teamwright@teamwright-next": true}}\n' > .claude/settings.local.json
git add -A; git commit -qm init
PF="$TMP/installed_plugins.json"
printf '{"plugins": {"teamwright@teamwright-next": [{"scope": "user", "installPath": "%s", "version": "9.9.9"}]}}\n' "$KIT" > "$PF"
CL="$TMP/claude"; printf '#!/bin/sh\necho "$*" >> "%s/claude.log"\n' "$TMP" > "$CL"; chmod +x "$CL"
out="$(TW_PLUGINS_FILE="$PF" TW_CLAUDE="$CL" python3 "$I" update --project . 2>&1)"; rc=$?
expect_rc "update: plan from the installed copy" 0 "$rc"
printf '%s' "$out" | grep -q "plugin teamwright@teamwright-next 9.9.9" && ok "the project's plugin and channel are found" || bad "plugin and channel" "$out"
printf '%s' "$out" | grep -q "^plan:" && ok "plan runs (nothing applied)" || bad "plan runs" "$out"
expect_rc "marketplace, then plugin update for the project's channel" \
  "plugin marketplace update teamwright-next|plugin update teamwright@teamwright-next" "$(tr '\n' '|' < "$TMP/claude.log" | sed 's/|$//')"
[ -f .teamwright/installed.json ] && bad "plan writes nothing" || ok "plan writes nothing"
out="$(TW_PLUGINS_FILE="$PF" python3 "$I" update --no-fetch --apply --project . 2>&1)"; rc=$?
expect_rc "update --apply installs the kit" 0 "$rc"
[ -f .teamwright/installed.json ] && ok "apply wrote the kit files" || bad "apply wrote the kit files" "$out"
printf '%s' "$out" | grep -q "restart Claude Code" && ok "says to restart for the new commands" || bad "restart note" "$out"
printf '{"plugins": {}}\n' > "$PF"
out="$(TW_PLUGINS_FILE="$PF" python3 "$I" update --no-fetch --project . 2>&1)"; rc=$?
expect_rc "no installed copy: an error, nothing run" 1 "$rc"
printf '%s' "$out" | grep -q "no installed copy" && ok "names what is missing" || bad "names what is missing" "$out"
finish
