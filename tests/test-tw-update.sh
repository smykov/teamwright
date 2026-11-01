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
# an update on a project installed before the new deny rules: rules are merged in, the
# project's own settings kept, and the hooks it just got do not block finishing the update
printf '{"plugins": {"teamwright@teamwright": [{"scope": "user", "installPath": "%s", "version": "9.9.9"}]}}\n' "$KIT" > "$PF.ok"
for m in gate-first enforce; do
  q="$TMP/upd-$m"; mkdir -p "$q/.teamwright"; ( cd "$q" && git init -q -b main . )
  printf 'version: 1\nmode: %s\nareas:\n  - name: core\n' "$m" > "$q/.teamwright/config.yml"
  python3 "$I" --kit "$KIT" apply --project "$q" >/dev/null 2>&1; expect_rc "$m: first install" 0 "$?"
  python3 - "$q/.claude/settings.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["permissions"]["deny"] = [r for r in d["permissions"]["deny"] if "TEAMWRIGHT" not in r and "hooksPath" not in r] + ["Read(./own/**)"]
json.dump(d, open(p, "w"), indent=2)
EOF
  ( cd "$q" && git add -A && git commit -qm "older kit" )
  out="$(cd "$q" && TW_PLUGINS_FILE="$PF.ok" python3 "$I" update --no-fetch --apply --project . 2>&1)"; rc=$?
  expect_rc "$m: update applies over the older install" 0 "$rc"
  python3 - "$q/.claude/settings.json" <<'EOF'; expect_rc "$m: update adds the deny rules and keeps the project's" 0 "$?"
import json, sys
d = json.load(open(sys.argv[1]))["permissions"]["deny"]
sys.exit(0 if {"Read(./own/**)", "Bash(TEAMWRIGHT_ALLOW_PUSH=*)", "Bash(rm TEAMWRIGHT_PAUSE*)", "Bash(git config core.hooksPath *)"} <= set(d) else 1)
EOF
  for c in "python3 /home/u/.claude/plugins/cache/teamwright/teamwright/9.9.9/scripts/tw-install.py update --no-fetch --apply" \
           "git add scripts/hooks .claude/settings.json .mcp.json .gitignore" \
           "git commit -m 'chore(process): teamwright 0.15.1 -> 0.16.0'" "bash scripts/install-hooks.sh"; do
    expect_allow "$m: the installed gates pass: $c" "$(hook_json Bash s1 "command=$c" | CLAUDE_PROJECT_DIR="$q" bash "$q/scripts/hooks/review-gate.sh")"
  done
  ( cd "$q" && git add -A && git commit -qm "chore(process): update" >/dev/null 2>&1 ); expect_rc "$m: the update commits through the git hooks" 0 "$?"
done
printf '{"plugins": {}}\n' > "$PF"
out="$(TW_PLUGINS_FILE="$PF" python3 "$I" update --no-fetch --project . 2>&1)"; rc=$?
expect_rc "no installed copy: an error, nothing run" 1 "$rc"
printf '%s' "$out" | grep -q "no installed copy" && ok "names what is missing" || bad "names what is missing" "$out"
finish
