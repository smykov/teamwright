#!/usr/bin/env bash
# Regression: session-check.sh (SessionStart: plugin installed at the recorded version, git hooks on).
. "$(dirname "$0")/lib.sh"
echo "session-check"
new_repo "$TMP/repo"
S="scripts/hooks/session-check.sh"
export CLAUDE_PROJECT_DIR="$TMP/repo"
REG="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
mkdir -p "$CLAUDE_CONFIG_DIR/plugins" .teamwright .claude
run() { echo '{}' | bash "$S"; }
msg() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["additionalContext"]; print(d["systemMessage"])'; }
reg() {  # reg SCOPE VERSION [projectPath]
  python3 - "$REG" "$1" "$2" "${3:-}" <<'PY'
import json, sys
e = {"scope": sys.argv[2], "version": sys.argv[3]}
if sys.argv[4]:
    e["projectPath"] = sys.argv[4]
json.dump({"version": 2, "plugins": {"teamwright@teamwright": [e]}}, open(sys.argv[1], "w"))
PY
}

out="$(run)"
expect_allow "no installed.json: not a teamwright project yet, silent" "$out"

printf '{"@kit": {"plugin": "teamwright@teamwright", "version": "0.4.5"}}\n' > .teamwright/installed.json
cat > .claude/settings.json <<'J'
{"extraKnownMarketplaces": {"teamwright": {"source": {"source": "github", "repo": "acme/teamwright", "ref": "next"}}}}
J
git config core.hooksPath scripts/hooks
out="$(run)"; m="$(msg "$out")"
case "$m" in *"not installed"*"/plugin marketplace add acme/teamwright"*"branch next"*"/plugin install teamwright@teamwright"*) ok "no registry: plugin reported missing with the install commands" ;; *) bad "missing plugin" "$out" ;; esac
case "$m" in *"git hooks"*) bad "hooks on: not reported" "$m" ;; *) ok "hooks on: not reported" ;; esac

reg user 0.4.5
expect_allow "user-scope plugin at the recorded version: silent" "$(run)"

reg project 0.4.5 /somewhere/else
case "$(msg "$(run)")" in *"not installed"*) ok "project-scope install of another project does not count" ;; *) bad "other project scope" ;; esac
reg project 0.4.5 "$TMP/repo"
expect_allow "project-scope install of this project counts" "$(run)"

reg user 0.4.3
case "$(msg "$(run)")" in *"0.4.3, older than the 0.4.5"*"/plugin marketplace update teamwright"*) ok "older plugin: update commands" ;; *) bad "older plugin" ;; esac
reg user 0.10.0
case "$(msg "$(run)")" in *"newer than the project files"*"/teamwright:reconfigure"*) ok "newer plugin (numeric compare): reconfigure" ;; *) bad "newer plugin" ;; esac

reg user 0.4.5
git config --unset core.hooksPath
case "$(msg "$(run)")" in *"git hooks are off"*"install-hooks.sh"*) ok "fresh clone without core.hooksPath: install-hooks hint" ;; *) bad "hooks off" ;; esac
git config core.hooksPath scripts/hooks

echo 'not json' > "$REG"
expect_allow "unreadable registry: skipped, not reported" "$(run)"
echo '{"plugins": []}' > "$REG"
expect_allow "registry in an unknown shape: skipped" "$(run)"

rm -f "$REG"
printf '{".claude/agents/x.md": "abc"}\n' > .teamwright/installed.json
case "$(msg "$(run)")" in *"teamwright@teamwright plugin is not installed"*) ok "manifest without @kit (older install): presence still checked" ;; *) bad "no @kit" ;; esac
# a plugin loaded from a directory (--plugin-dir, the Agent SDK in an autonomous run)
mkdir -p "$TMP/plugdir/.claude-plugin"; echo '{"name": "teamwright"}' > "$TMP/plugdir/.claude-plugin/plugin.json"
expect_allow "TEAMWRIGHT_PLUGIN_DIR with the plugin: not reported missing" "$(echo '{}' | TEAMWRIGHT_PLUGIN_DIR="$TMP/plugdir" bash "$S")"
echo '{"name": "other"}' > "$TMP/plugdir/.claude-plugin/plugin.json"
case "$(msg "$(echo '{}' | TEAMWRIGHT_PLUGIN_DIR="$TMP/plugdir" bash "$S")")" in *"not installed"*) ok "TEAMWRIGHT_PLUGIN_DIR with another plugin: still reported" ;; *) bad "other plugin dir" ;; esac
echo '{"name": "teamwright", "version": "0.4.3"}' > "$TMP/plugdir/.claude-plugin/plugin.json"
printf '{"@kit": {"plugin": "teamwright@teamwright", "version": "0.4.5"}}\n' > .teamwright/installed.json
case "$(msg "$(echo '{}' | TEAMWRIGHT_PLUGIN_DIR="$TMP/plugdir" bash "$S")")" in *"loaded from TEAMWRIGHT_PLUGIN_DIR"*"0.4.3, older than the 0.4.5"*) ok "TEAMWRIGHT_PLUGIN_DIR: an older plugin.json version is reported" ;; *) bad "dir version drift" ;; esac
echo '{"name": "teamwright", "version": "0.4.5"}' > "$TMP/plugdir/.claude-plugin/plugin.json"
expect_allow "TEAMWRIGHT_PLUGIN_DIR at the recorded version: silent" "$(echo '{}' | TEAMWRIGHT_PLUGIN_DIR="$TMP/plugdir" bash "$S")"
echo '{"name": "teamwright"}' > "$TMP/plugdir/.claude-plugin/plugin.json"
git -C "$TMP/plugdir" init -q -b next . && git -C "$TMP/plugdir" add -A && git -C "$TMP/plugdir" commit -qm channel
sha="$(git -C "$TMP/plugdir" rev-parse HEAD | cut -c1-12)"
printf '{"@kit": {"plugin": "teamwright@teamwright", "version": "%s"}}\n' "$sha" > .teamwright/installed.json
expect_allow "TEAMWRIGHT_PLUGIN_DIR, a channel checkout at the recorded commit: silent" "$(echo '{}' | TEAMWRIGHT_PLUGIN_DIR="$TMP/plugdir" bash "$S")"
printf '{"@kit": {"plugin": "teamwright@teamwright", "version": "0123456789ab"}}\n' > .teamwright/installed.json
case "$(msg "$(echo '{}' | TEAMWRIGHT_PLUGIN_DIR="$TMP/plugdir" bash "$S")")" in *"is $sha, the project was set up with 0123456789ab"*) ok "TEAMWRIGHT_PLUGIN_DIR, a channel checkout at another commit: reported" ;; *) bad "dir sha drift" ;; esac
expect_allow "TEAMWRIGHT_SESSION_CHECK=0 turns it off" "$(echo '{}' | TEAMWRIGHT_SESSION_CHECK=0 bash "$S")"
finish
