#!/usr/bin/env bash
# Regression: scripts/tw-install.py (inventory / plan / apply / enforce / scan).
. "$(dirname "$0")/lib.sh"
echo "tw-install"

FIX="$KIT/tests/fixtures/providers"
# A private copy of the kit: tests may edit its template (update path) and must see
# tools markers even while the role templates are still being wired.
K="$TMP/kit"
mkdir -p "$K"
cp -R "$KIT/template" "$KIT/docs" "$KIT/scripts" "$KIT/.claude-plugin" "$K/"
for f in "$K/template/AGENTS.md" "$K/template/.claude/agents/code-reviewer.md"; do
  grep -q 'teamwright:tools:begin' "$f" ||
    printf '\n<!-- teamwright:tools:begin -->\n<!-- teamwright:tools:end -->\n' >> "$f"
done
tw() { python3 "$K/scripts/tw-install.py" --kit "$K" --providers "$FIX" "$@"; }
snap() {  # digest of every file (path, mode, content) outside .git + core.hooksPath
  python3 - "$1" "$(git -C "$1" config --get core.hooksPath 2>/dev/null)" <<'PY'
import hashlib, os, sys
h = hashlib.sha256(sys.argv[2].encode())
for root, dirs, files in os.walk(sys.argv[1]):
    dirs[:] = sorted(d for d in dirs if d != ".git")
    for f in sorted(files):
        p = os.path.join(root, f)
        h.update(("%s %o\n" % (os.path.relpath(p, sys.argv[1]), os.stat(p).st_mode)).encode())
        h.update(open(p, "rb").read())
print(h.hexdigest())
PY
}
has()  { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1" "'$3' not in $2"; fi; }
hasnt() { if grep -qF -- "$3" "$2"; then bad "$1" "'$3' found in $2"; else ok "$1"; fi; }

write_cfg() {  # write_cfg FILE [spec-provider] [areas: one|two]
  {
    echo "version: 1"
    echo "process_version: 1.0.0"
    echo "mode: gate-first   # warn first"
    echo "areas:"
    echo "  - name: backend"
    echo "    source_dirs: [src]"
    echo "    test_command: \"make test\""
    echo "    lint_command: 'make lint'"
    echo "    api_test_command: \"make api\""
    echo "    e2e_ui_command: \"\""
    echo "    stack: Python"
    if [ "${3:-one}" = two ]; then
      echo "  - name: app"
      echo "    source_dirs: [app/lib, app/test]"
      echo "    test_command: \"flutter test\""
      echo "    e2e_ui_command: \"patrol test\""
    fi
    echo "gate_command: \"make check\""
    echo "tools:"
    echo "  spec: ${2:-fake-spec}"
    echo "  context: fake-nav"
    echo "  docs: none"
    echo "  ui_verify: fake-ui"
    echo "language: en"
  } > "$1"
}

# ---- greenfield -------------------------------------------------------------
G="$TMP/green"; mkdir -p "$G"; git -C "$G" init -q -b main
write_cfg "$TMP/green.yml" fake-spec two
before="$(snap "$G")"
tw plan --project "$G" --config "$TMP/green.yml" > "$TMP/out" 2>&1
expect_rc "plan exits 0" 0 "$?"
expect_rc "plan writes nothing" "$before" "$(snap "$G")"
has "plan lists creates" "$TMP/out" "create          AGENTS.md"
tw --dry-run apply --project "$G" --config "$TMP/green.yml" > "$TMP/out" 2>&1
expect_rc "apply --dry-run writes nothing" "$before" "$(snap "$G")"
has "dry-run says would change" "$TMP/out" "would change"

tw apply --project "$G" --config "$TMP/green.yml" > "$TMP/out" 2>&1
expect_rc "apply exits 0" 0 "$?"
has "apply reports 0 conflicts" "$TMP/out" "0 conflict(s)"
[ -f "$G/.teamwright/config.yml" ] && ok "config.yml written" || bad "config.yml written"
[ -f "$G/.teamwright/installed.json" ] && ok "manifest written" || bad "manifest written"
[ -f "$G/docs/process/lifecycle.md" ] && ok "docs/process copied" || bad "docs/process copied"
[ ! -e "$G/docs/process/plugin.md" ] && ok "kit-only plugin.md not copied" || bad "kit-only plugin.md not copied"
[ -x "$G/scripts/hooks/pre-commit" ] && ok "hooks copied executable" || bad "hooks copied executable"
[ ! -e "$G/.teamwright/config.example.yml" ] && ok "example config not copied" || bad "example config not copied"
[ ! -e "$G/scripts/metrics/__pycache__" ] && ok "no __pycache__ copied" || bad "no __pycache__ copied"
expect_rc "core.hooksPath set" "scripts/hooks" "$(git -C "$G" config core.hooksPath)"
has ".gitignore has local state" "$G/.gitignore" ".teamwright/logs/"
[ -f "$G/.claude/agents/developer-backend.md" ] && [ -f "$G/.claude/agents/test-writer-app.md" ] \
  && [ ! -e "$G/.claude/agents/developer.md" ] && ok "per-area role files" || bad "per-area role files"
has "per-area name in front matter" "$G/.claude/agents/developer-app.md" "name: developer-app"
has "area placeholder rendered" "$G/.claude/agents/developer-backend.md" "| Stack | Python |"
has "list placeholder joined" "$G/.claude/agents/developer-app.md" "app/lib, app/test"
has "multi-area value in global file" "$G/.claude/agents/task-validator.md" "backend: scripts/tw-run backend -- make api"
has "area command wrapped with tw-run" "$G/.claude/agents/test-writer-app.md" "scripts/tw-run app -- patrol test"
has "test-writer runs tests through tw-test" "$G/.claude/agents/test-writer-app.md" "scripts/tw-test app"
hasnt "no tw-run test command in the role file (the test guard refuses it)" "$G/.claude/agents/test-writer-app.md" "scripts/tw-run app -- flutter test"
has "requirements-reviewer role installed" "$G/.claude/agents/requirements-reviewer.md" "name: requirements-reviewer"
python3 - "$G/docs/requirements.md" <<'PY2' && ok "requirements template has the ten sections" || bad "requirements template has the ten sections"
import re, sys
heads = re.findall(r"(?m)^## (\d+)\. ", open(sys.argv[1]).read())
assert heads == [str(i) for i in range(1, 11)], heads
assert "| UI verification |" in open(sys.argv[1]).read()
PY2
has "top-level gate_command not wrapped" "$G/AGENTS.md" "make check"
hasnt "top-level gate_command: no tw-run" "$G/AGENTS.md" "tw-run backend -- make check"
[ -x "$G/scripts/tw-run" ] && ok "tw-run installed executable" || bad "tw-run installed executable"
[ -x "$G/scripts/tw-gate" ] && ok "tw-gate installed executable" || bad "tw-gate installed executable"
[ -x "$G/scripts/tw-mutants" ] && ok "tw-mutants installed executable" || bad "tw-mutants installed executable"
[ -x "$G/scripts/hooks/_job.sh" ] && ok "hooks/_job.sh installed executable (tw-gate, tw-mutants, tw-test)" || bad "hooks/_job.sh installed executable"
[ -x "$G/scripts/tw-test" ] && ok "tw-test installed executable" || bad "tw-test installed executable"
[ -x "$G/scripts/hooks/test-guard.sh" ] && ok "test-guard.sh installed executable" || bad "test-guard.sh installed executable"
expect_rc "the kit's scripts are committed with the mode the installer gives them (no mode change in projects)" "" \
  "$(git -C "$KIT" ls-files -s template/scripts | awk '$1 == "100644" && $4 ~ /(\.sh|\/tw-[a-z-]+|\/(pre-commit|commit-msg|pre-push))$/ {print $4}')"
has ".gitignore has runner cache" "$G/.gitignore" ".teamwright/cache/"
hasnt "GATE_COMMAND resolved" "$G/AGENTS.md" "{{GATE_COMMAND}}"
has "unresolved placeholders reported" "$TMP/out" "unresolved      .claude/agents/developer-backend.md {{CONVENTIONS}}"
# per-area role files use only their own area's values, never another area's
hasnt "per-area: no other area's lint command" "$G/.claude/agents/developer-app.md" "make lint"
hasnt "per-area: no joined values in a role file" "$G/.claude/agents/test-writer-app.md" "backend:"
has "per-area: missing value stays a placeholder" "$G/.claude/agents/test-writer-app.md" "{{API_TEST_COMMAND}}"
has "per-area: missing value reported" "$TMP/out" "unresolved      .claude/agents/test-writer-app.md {{API_TEST_COMMAND}}"
has "per-area: own value rendered" "$G/.claude/agents/test-writer-backend.md" "make api"
has "apply states the effective mode" "$TMP/out" "mode: gate-first"
has "tools block: spec rules" "$G/AGENTS.md" "FAKE-SPEC-RULE"
has "tools block: context rules" "$G/.claude/agents/code-reviewer.md" "FAKE-NAV-RULE"
has "tools block: heading per capability" "$G/AGENTS.md" "### ui_verify: fake-ui"
hasnt "no block for docs: none" "$G/AGENTS.md" "### docs:"
python3 - "$G" <<'PY' && ok "settings.json has gates and deny list" || bad "settings.json has gates and deny list"
import json, sys
s = json.load(open(sys.argv[1] + "/.claude/settings.json"))
cmds = [h["command"] for g in s["hooks"]["PreToolUse"] for h in g["hooks"]]
assert any("analysis-gate.sh" in c for c in cmds) and any("verify-gate.sh" in c for c in cmds)
assert any("test-guard.sh" in h["command"] for g in s["hooks"]["PreToolUse"] if g.get("matcher") == "Bash" for h in g["hooks"])
assert "Bash(git stash *)" in s["permissions"]["deny"]
PY
python3 - "$G" <<'PY' && ok ".mcp.json gets both adapter servers" || bad ".mcp.json gets both adapter servers"
import json, sys
m = json.load(open(sys.argv[1] + "/.mcp.json"))["mcpServers"]
assert m["fake-nav"]["command"] == "fake-nav-server"      # front-matter JSON config
assert m["fake-ui"]["args"] == ["fake-ui-mcp"]              # ```json block in ## Install
PY

# ---- idempotency --------------------------------------------------------------
before="$(snap "$G")"
tw apply --project "$G" > "$TMP/out" 2>&1
has "second apply: no changes" "$TMP/out" "apply: 0 changed"
expect_rc "second apply leaves tree identical" "$before" "$(snap "$G")"

# ---- gate-first vs enforce ---------------------------------------------------
mkdir -p "$G/src"
IN="$(hook_json Write s1 file_path=src/a.py content=x)"
out="$(cd "$G" && printf '%s' "$IN" | TEAMWRIGHT_TASK=T-1 CLAUDE_PROJECT_DIR="$G" bash scripts/hooks/analysis-gate.sh)"
if printf '%s' "$out" | grep -q '"systemMessage"' && ! printf '%s' "$out" | grep -q permissionDecision; then
  ok "gate-first: gate warns, does not deny"; else bad "gate-first: gate warns, does not deny" "$out"; fi
tw --dry-run enforce --project "$G" >/dev/null
has "enforce --dry-run keeps gate-first" "$G/.teamwright/config.yml" "mode: gate-first"
tw enforce --project "$G" > "$TMP/out"
has "enforce flips mode" "$G/.teamwright/config.yml" "mode: enforce"
has "enforce keeps trailing comment" "$G/.teamwright/config.yml" "# warn first"
out="$(cd "$G" && printf '%s' "$IN" | TEAMWRIGHT_TASK=T-1 CLAUDE_PROJECT_DIR="$G" bash scripts/hooks/analysis-gate.sh)"
expect_deny "enforce: gate denies" "$out" "ANALYSIS GATE"
out="$(cd "$G" && printf '%s' "$IN" | TEAMWRIGHT_GATE_MODE=warn TEAMWRIGHT_TASK=T-1 CLAUDE_PROJECT_DIR="$G" bash scripts/hooks/analysis-gate.sh)"
printf '%s' "$out" | grep -q '"systemMessage"' && ok "TEAMWRIGHT_GATE_MODE overrides config" || bad "TEAMWRIGHT_GATE_MODE overrides config" "$out"
tw enforce --project "$G" > "$TMP/out"
has "enforce is idempotent" "$TMP/out" "already enforce"
tw apply --project "$G" > "$TMP/out" 2>&1
has "apply after enforce: no changes" "$TMP/out" "apply: 0 changed"

# ---- reconfigure: tools block re-rendered, edits outside markers kept ---------
printf '\nLOCAL NOTE outside markers\n' >> "$G/AGENTS.md"
sedi 's/^  spec: fake-spec/  spec: none/' "$G/.teamwright/config.yml"
tw apply --project "$G" > "$TMP/out" 2>&1
has "reconfigure reports tools op" "$TMP/out" "tools           AGENTS.md"
hasnt "reconfigure drops old provider rules" "$G/AGENTS.md" "FAKE-SPEC-RULE"
has "reconfigure keeps other providers" "$G/AGENTS.md" "FAKE-NAV-RULE"
has "reconfigure keeps local edit" "$G/AGENTS.md" "LOCAL NOTE outside markers"
tw apply --project "$G" > "$TMP/out" 2>&1
has "reconfigure is idempotent" "$TMP/out" "apply: 0 changed"

# ---- template update: untouched file updated, locally edited file kept -------
echo "kit v2 line" >> "$K/template/docs/failures.md"
echo "kit v2 line" >> "$K/template/docs/plan.md"
echo "my project plan" >> "$G/docs/plan.md"
tw apply --project "$G" > "$TMP/out" 2>&1
has "untouched installed file is updated" "$G/docs/failures.md" "kit v2 line"
has "update reported" "$TMP/out" "update          docs/failures.md"
hasnt "locally edited file not overwritten" "$G/docs/plan.md" "kit v2 line"
has "locally edited file reported kept-local" "$TMP/out" "kept-local      docs/plan.md"
cp -R "$KIT/template/docs/." "$K/template/docs/"     # restore the kit copy

# ---- existing project ---------------------------------------------------------
E="$TMP/existing"; mkdir -p "$E/.claude/agents" "$E/.git/hooks"; git -C "$E" init -q -b main
echo "# My project rules" > "$E/CLAUDE.md"
printf -- '---\nname: developer\n---\nmy own developer\n' > "$E/.claude/agents/developer.md"
printf -- '---\nname: security\n---\nmine\n' > "$E/.claude/agents/security.md"
cat > "$E/.mcp.json" <<'EOF'
{"mcpServers": {"mine": {"command": "my-server"}, "fake-nav": {"command": "custom-nav"}}}
EOF
cat > "$E/.claude/settings.json" <<'EOF'
{
  "env": {"TEAMWRIGHT_CLAUDE_MD_MAX_KB": "80", "MY_VAR": "1"},
  "permissions": {"allow": ["Bash(make *)"], "deny": ["Bash(rm -rf *)", "Read(./secrets/**)"]},
  "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "my-hook.sh"}]}]}
}
EOF
mkdir -p "$E/.teamwright"; write_cfg "$E/.teamwright/config.yml"
tw inventory --project "$E" > "$TMP/inv.json"
python3 - "$TMP/inv.json" <<'PY' && ok "inventory sees existing files" || bad "inventory sees existing files"
import json, sys
i = json.load(open(sys.argv[1]))
assert i["CLAUDE.md"]["exists"] and "developer.md" in i["claude_agents"]
assert i["mcp_servers"] == ["fake-nav", "mine"] and i["settings_json"]["hook_events"] == ["PreToolUse"]
assert i["teamwright"]["mode"] == "gate-first" and i["git"]["repo"]
PY
tw apply --project "$E" > "$TMP/out" 2>&1
has "own CLAUDE.md is a conflict" "$TMP/out" "conflict        CLAUDE.md"
has "own developer.md is a conflict" "$TMP/out" "conflict        .claude/agents/developer.md"
expect_rc "own CLAUDE.md untouched" "# My project rules" "$(cat "$E/CLAUDE.md")"
has "own developer.md untouched" "$E/.claude/agents/developer.md" "my own developer"
has "unrelated agent kept" "$E/.claude/agents/security.md" "mine"
python3 - "$E" <<'PY' && ok "settings.json merged without losing anything" || bad "settings.json merged without losing anything"
import json, sys
s = json.load(open(sys.argv[1] + "/.claude/settings.json"))
assert s["env"]["TEAMWRIGHT_CLAUDE_MD_MAX_KB"] == "80" and s["env"]["MY_VAR"] == "1"
assert s["permissions"]["allow"] == ["Bash(make *)"]
d = s["permissions"]["deny"]
assert "Read(./secrets/**)" in d and d.count("Bash(rm -rf *)") == 1 and "Bash(git stash *)" in d
cmds = [h["command"] for g in s["hooks"]["PreToolUse"] for h in g["hooks"]]
assert "my-hook.sh" in cmds and any("review-gate.sh" in c for c in cmds)
assert len(cmds) == len(set(cmds))
assert "Stop" in s["hooks"]
PY
python3 - "$E" <<'PY' && ok ".mcp.json merged, existing entries kept as-is" || bad ".mcp.json merged, existing entries kept as-is"
import json, sys
m = json.load(open(sys.argv[1] + "/.mcp.json"))["mcpServers"]
assert m["mine"] == {"command": "my-server"} and m["fake-nav"] == {"command": "custom-nav"}
assert "fake-ui" in m
PY
has "differing existing MCP server reported" "$TMP/out" "server 'fake-nav' exists with a different config - kept"
before="$(snap "$E")"
tw apply --project "$E" > "$TMP/out" 2>&1
has "existing project: second apply no changes" "$TMP/out" "apply: 0 changed"
has "existing project: conflicts still listed" "$TMP/out" "2 conflict(s)"
expect_rc "existing project: tree identical" "$before" "$(snap "$E")"

# ---- another hook manager owns core.hooksPath ---------------------------------
H="$TMP/husky"; mkdir -p "$H"; git -C "$H" init -q -b main; git -C "$H" config core.hooksPath .husky
write_cfg "$TMP/h.yml"
tw apply --project "$H" --config "$TMP/h.yml" > "$TMP/out" 2>&1
has "foreign core.hooksPath is a conflict" "$TMP/out" "conflict        core.hooksPath"
expect_rc "foreign core.hooksPath kept" ".husky" "$(git -C "$H" config core.hooksPath)"

# ---- config formats and validation --------------------------------------------
J="$TMP/json"; mkdir -p "$J"; git -C "$J" init -q -b main
cat > "$TMP/c.json" <<'EOF'
{"version": 1, "mode": "enforce", "areas": [{"name": "core", "source_dirs": ["lib"], "test_command": "t"}],
 "gate_command": "make gate", "tools": {"spec": "none"}}
EOF
tw apply --project "$J" --config "$TMP/c.json" > "$TMP/out" 2>&1
expect_rc "JSON config accepted" 0 "$?"
has "JSON config rendered" "$J/AGENTS.md" "make gate"
[ -f "$J/.claude/agents/developer.md" ] && ok "one area: plain developer.md" || bad "one area: plain developer.md"
printf 'version: 1\nmode: sometimes\ntools:\n  spec: x\n  paint: y\n' > "$TMP/bad.yml"
tw plan --project "$J" --config "$TMP/bad.yml" > "$TMP/out" 2>&1
expect_rc "invalid config exits non-zero" 1 "$?"
has "invalid config: areas required" "$TMP/out" "at least one area"
has "invalid config: unknown capability" "$TMP/out" "tools.paint"
has "invalid config: bad mode" "$TMP/out" "mode must be"
tw plan --project "$J" --config "$TMP/missing.yml" > "$TMP/out" 2>&1
expect_rc "missing config exits non-zero" 1 "$?"
sed 's/^mode: gate-first/mode: enforce/' "$TMP/green.yml" > "$TMP/green-enforce.yml"   # $J is in enforce
tw plan --project "$J" --config "$TMP/green-enforce.yml" > "$TMP/out" 2>&1
has "missing adapter is a note, not a failure" "$TMP/out" "note: tools.docs: none - no adapter block"

# ---- secret scan ----------------------------------------------------------------
S="$TMP/scan"; mkdir -p "$S/sub"; git -C "$S" init -q -b main
echo "print('hello')" > "$S/app.py"
git -C "$S" add app.py && git -C "$S" commit -qm init
tw scan --project "$S" > "$TMP/out" 2>&1
expect_rc "clean tree: scan exits 0" 0 "$?"
has "clean tree: reports clean" "$TMP/out" "clean"
P="Zx9!hunter2"   # secrets are assembled at runtime so the kit's own scan stays clean
echo "db_password = \"${P}hunter2\"" > "$S/sub/notes.txt"      # untracked
tw scan --project "$S" > "$TMP/out" 2>&1
expect_rc "untracked secret: scan exits 1" 1 "$?"
has "untracked secret: file and line named" "$TMP/out" "sub/notes.txt:1"
tw --json scan --project "$S" > "$TMP/out" 2>&1
has "scan --json lists findings" "$TMP/out" '"rule": "secret-assignment"'
echo "db_password = \"${P}hunter2\"  # teamwright:allow-secret" > "$S/sub/notes.txt"
tw scan --project "$S" > /dev/null 2>&1
expect_rc "allow marker honoured" 0 "$?"
echo "API_KEY=${P}1234" > "$S/.env"; echo ".env" > "$S/.gitignore"
tw inventory --project "$S" > "$TMP/inv.json"
has "inventory lists ignored .env as secret-looking" "$TMP/inv.json" '"path": ".env"'
N="$TMP/nogit"; mkdir -p "$N"; echo "token: 'ghp_$(printf 'a%.0s' $(seq 1 36))'" > "$N/cfg.yml"
tw scan --project "$N" > "$TMP/out" 2>&1
expect_rc "non-git dir: scan walks the tree" 1 "$?"

# ---- scan: a '++ ' line is content, not a diff header ---------------------------
rm -f "$S/sub/notes.txt" "$S/.env"
printf '++ not a header\nkey = %s\n' "AKIA""QWERTYUIOPASDFGH" > "$S/plus.txt"
tw scan --project "$S" > "$TMP/out" 2>&1
has "scan after a '++ ' line: right path and line" "$TMP/out" "plus.txt:2"

# ---- mode: one parsing rule for installer and hooks ----------------------------
M="$TMP/mode"; mkdir -p "$M/src"; git -C "$M" init -q -b main
cat > "$TMP/m.json" <<'EOF'
{"version": 1, "mode": "gate-first", "areas": [{"name": "core", "source_dirs": ["src"]}],
 "gate_command": "make gate"}
EOF
tw apply --project "$M" --config "$TMP/m.json" > "$TMP/out" 2>&1
has "JSON config: effective mode reported" "$TMP/out" "mode: gate-first"
out="$(cd "$M" && printf '%s' "$IN" | TEAMWRIGHT_TASK=T-1 CLAUDE_PROJECT_DIR="$M" bash scripts/hooks/analysis-gate.sh)"
if printf '%s' "$out" | grep -q '"systemMessage"' && ! printf '%s' "$out" | grep -q permissionDecision; then
  ok "JSON config gate-first: hooks warn"; else bad "JSON config gate-first: hooks warn" "$out"; fi
tw enforce --project "$M" > /dev/null 2>&1
if python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["mode"] == "enforce"' "$M/.teamwright/config.yml" 2>/dev/null; then
  ok "enforce rewrites the JSON key, file stays JSON"
else bad "enforce rewrites the JSON key, file stays JSON" "$(cat "$M/.teamwright/config.yml")"; fi
out="$(cd "$M" && printf '%s' "$IN" | TEAMWRIGHT_TASK=T-1 CLAUDE_PROJECT_DIR="$M" bash scripts/hooks/analysis-gate.sh)"
expect_deny "JSON config enforce: hooks deny" "$out" "ANALYSIS GATE"

M2="$TMP/mode2"; mkdir -p "$M2/src"; git -C "$M2" init -q -b main
printf 'version: 1\nareas:\n  - name: core\n    source_dirs: [src]\ngate_command: "make gate"\n' > "$TMP/nomode.yml"
tw plan --project "$M2" --config "$TMP/nomode.yml" > "$TMP/out" 2>&1
has "missing mode: installer says enforce" "$TMP/out" "mode: enforce"
hasnt "missing mode: no gate-first note" "$TMP/out" "gate-first"
tw apply --project "$M2" --config "$TMP/nomode.yml" > /dev/null 2>&1
out="$(cd "$M2" && printf '%s' "$IN" | TEAMWRIGHT_TASK=T-1 CLAUDE_PROJECT_DIR="$M2" bash scripts/hooks/analysis-gate.sh)"
expect_deny "missing mode: hooks deny" "$out" "ANALYSIS GATE"
printf 'version: 1\nareas:\n  - name: core\ntools:\n  spec: none\n' > "$M2/.teamwright/config.yml"
tw enforce --project "$M2" > /dev/null 2>&1
if python3 - "$KIT" "$M2/.teamwright/config.yml" <<'PY' 2>/dev/null
import sys
sys.path.insert(0, sys.argv[1] + "/template/scripts/hooks")
import _config
c = _config.parse_yaml(open(sys.argv[2]).read())
assert c["mode"] == "enforce" and c["tools"] == {"spec": "none"}, c
PY
then ok "enforce on YAML without mode: key inserted at top level"
else bad "enforce on YAML without mode: key inserted at top level" "$(cat "$M2/.teamwright/config.yml")"; fi
printf 'version: 1\nmode: "gate-first"  # keep\nareas:\n  - name: core\n' > "$M2/.teamwright/config.yml"
tw enforce --project "$M2" > /dev/null 2>&1
has "enforce on quoted YAML mode: replaced, comment kept" "$M2/.teamwright/config.yml" "mode: enforce  # keep"

# ---- enforce -> gate-first is the owner's decision --------------------------------
write_cfg "$TMP/down.yml"
CLAUDECODE=1 tw apply --project "$M2" --config "$TMP/down.yml" > "$TMP/out" 2>&1
expect_rc "downgrade from inside Claude Code exits 1" 1 "$?"
has "downgrade refused, owner named" "$TMP/out" "owner"
has "downgrade: config untouched" "$M2/.teamwright/config.yml" "mode: enforce"
CLAUDECODE=1 TEAMWRIGHT_OWNER=1 tw apply --project "$M2" --config "$TMP/down.yml" > "$TMP/out" 2>&1
expect_rc "TEAMWRIGHT_OWNER ignored inside Claude Code" 1 "$?"
TEAMWRIGHT_OWNER=1 tw apply --project "$M2" --config "$TMP/down.yml" > "$TMP/out" 2>&1
expect_rc "owner outside Claude Code may downgrade" 0 "$?"
has "owner downgrade written" "$M2/.teamwright/config.yml" "mode: gate-first"

# ---- malformed markers are a conflict, never overwritten ------------------------
B="$TMP/badmark"; mkdir -p "$B"; git -C "$B" init -q -b main
printf '# Mine\n<!-- teamwright:tools:end -->\nmiddle\n<!-- teamwright:tools:begin -->\nmine\n' > "$B/AGENTS.md"
cp "$B/AGENTS.md" "$TMP/badmark.orig"
write_cfg "$TMP/b.yml"
tw apply --project "$B" --config "$TMP/b.yml" > "$TMP/out" 2>&1
cmp -s "$B/AGENTS.md" "$TMP/badmark.orig" && ok "malformed markers: file untouched" || bad "malformed markers: file untouched"
has "malformed markers: reported as conflict" "$TMP/out" "conflict        AGENTS.md"

# ---- stale installer-owned files after an area change ---------------------------
T="$TMP/stale"; mkdir -p "$T"; git -C "$T" init -q -b main
write_cfg "$TMP/s2.yml" fake-spec two
tw apply --project "$T" --config "$TMP/s2.yml" > /dev/null 2>&1
echo "my local note" >> "$T/.claude/agents/test-writer-app.md"
write_cfg "$TMP/s1.yml" fake-spec one
tw plan --project "$T" --config "$TMP/s1.yml" > "$TMP/out" 2>&1
has "plan lists a stale role file" "$TMP/out" "stale           .claude/agents/developer-app.md"
has "plan: edited stale file is a conflict" "$TMP/out" "conflict        .claude/agents/test-writer-app.md"
tw apply --project "$T" --config "$TMP/s1.yml" > "$TMP/out" 2>&1
[ ! -e "$T/.claude/agents/developer-app.md" ] && [ ! -e "$T/.claude/agents/developer-backend.md" ] \
  && ok "unchanged stale files removed" || bad "unchanged stale files removed"
[ -f "$T/.claude/agents/developer.md" ] && ok "single-area role file created" || bad "single-area role file created"
has "edited stale file kept" "$T/.claude/agents/test-writer-app.md" "my local note"
hasnt "removed file dropped from the manifest" "$T/.teamwright/installed.json" "developer-app.md"
tw apply --project "$T" --config "$TMP/s1.yml" > "$TMP/out" 2>&1
has "after stale cleanup: no changes" "$TMP/out" "apply: 0 changed"

# ---- runner config: validation and command wrapping -----------------------------
R="$TMP/runner"; mkdir -p "$R"; git -C "$R" init -q -b main
cat > "$TMP/r.yml" <<'YML'
version: 1
mode: enforce
areas:
  - name: app
    runner: docker
    image: "example.invalid/toolchain:1.0"
    cache: [".pub-cache"]
    workdir: app
    test_command: "flutter test"
    api_test_command: "flutter test integration_test"
    lint_command: "dart format --set-exit-if-changed . && flutter analyze"
    generate_command: "flutter gen-l10n"
gate_command: "make check"
YML
tw apply --project "$R" --config "$TMP/r.yml" > "$TMP/out" 2>&1
expect_rc "docker area accepted" 0 "$?"
has "plain command wrapped" "$R/.claude/agents/test-writer.md" "scripts/tw-run app -- flutter test integration_test"
has "shell chain passed as one quoted string" "$R/.claude/agents/developer.md" \
  "scripts/tw-run app -- 'dart format --set-exit-if-changed . && flutter analyze'"
printf 'version: 1\nareas:\n  - name: a\n    runner: docker\n  - name: b\n    runner: vm\n  - name: c\n    workdir: ../x\n    cache: x\n  - name: d\n    test_command: "scripts/tw-run d -- make test"\n' > "$TMP/rbad.yml"
tw plan --project "$R" --config "$TMP/rbad.yml" > "$TMP/out" 2>&1
expect_rc "bad runner config exits 1" 1 "$?"
has "docker needs image" "$TMP/out" "areas[a].image is required"
has "unknown runner" "$TMP/out" "areas[b].runner must be host or docker"
has "workdir must stay inside" "$TMP/out" "areas[c].workdir"
has "cache must be a list" "$TMP/out" "areas[c].cache"
has "pre-wrapped command refused" "$TMP/out" "areas[d].test_command: write the bare command"

# ---- config.next.yml: diff, apply, proposal removed -----------------------------
sed 's/flutter test/flutter test --coverage/' "$R/.teamwright/config.yml" > "$R/.teamwright/config.next.yml"
tw plan --project "$R" --config "$R/.teamwright/config.next.yml" > "$TMP/out" 2>&1
has "plan shows the config diff" "$TMP/out" '+    test_command: "flutter test --coverage"'
[ -f "$R/.teamwright/config.next.yml" ] && ok "plan keeps the proposal" || bad "plan keeps the proposal"
(cd "$R" && tw apply --config .teamwright/config.next.yml > "$TMP/out" 2>&1)
expect_rc "apply of the proposal exits 0" 0 "$?"
has "apply shows the diff" "$TMP/out" '-    test_command: "flutter test"'
has "config updated" "$R/.teamwright/config.yml" "flutter test --coverage"
[ ! -e "$R/.teamwright/config.next.yml" ] && ok "proposal removed after apply" || bad "proposal removed after apply"
has "removal reported" "$TMP/out" "removed .teamwright/config.next.yml"
has "re-rendered with new command" "$R/.claude/agents/test-writer.md" "scripts/tw-run app -- flutter test --coverage integration_test"
sed 's/^mode: enforce/mode: gate-first/' "$R/.teamwright/config.yml" > "$R/.teamwright/config.next.yml"
(cd "$R" && CLAUDECODE=1 tw apply --config .teamwright/config.next.yml > "$TMP/out" 2>&1)
expect_rc "proposal lowering the mode refused" 1 "$?"
[ -f "$R/.teamwright/config.next.yml" ] && ok "refused proposal kept" || bad "refused proposal kept"
rm -f "$R/.teamwright/config.next.yml"

# ---- apply --accept: a hand-merged file stops being a conflict -------------------
echo "# my rules, merged with the template by hand" > "$TMP/mine.md"
A="$TMP/accept"; mkdir -p "$A"; git -C "$A" init -q -b main; cp "$TMP/mine.md" "$A/CLAUDE.md"
write_cfg "$TMP/a.yml"
tw apply --project "$A" --config "$TMP/a.yml" > "$TMP/out" 2>&1
has "own CLAUDE.md is a conflict before accept" "$TMP/out" "conflict        CLAUDE.md"
tw apply --project "$A" --accept CLAUDE.md > "$TMP/out" 2>&1
expect_rc "accept exits 0" 0 "$?"
has "accept reported" "$TMP/out" "accepted        CLAUDE.md"
tw plan --project "$A" > "$TMP/out" 2>&1
hasnt "accepted file no longer a conflict" "$TMP/out" "conflict        CLAUDE.md"
has "accepted file listed as accepted" "$TMP/out" "accepted        CLAUDE.md"
cmp -s "$A/CLAUDE.md" "$TMP/mine.md" && ok "accept does not touch the file" || bad "accept does not touch the file"
echo "later edit" >> "$A/CLAUDE.md"
tw plan --project "$A" > "$TMP/out" 2>&1
has "edited after accept: conflict again" "$TMP/out" "conflict        CLAUDE.md"
tw apply --project "$A" --accept CLAUDE.md > /dev/null 2>&1
echo "kit change" >> "$K/template/CLAUDE.md"
tw plan --project "$A" > "$TMP/out" 2>&1
has "template changed after accept: conflict with reason" "$TMP/out" "template changed since"
cp "$KIT/template/CLAUDE.md" "$K/template/CLAUDE.md"
tw apply --project "$A" --accept docs/nope.md > "$TMP/out" 2>&1
expect_rc "accept of a missing file exits 1" 1 "$?"
tw apply --project "$A" --accept AGENTS.md > "$TMP/out" 2>&1
expect_rc "accept of a non-conflict exits 1" 1 "$?"
has "manifest keeps accepted entries apart" "$A/.teamwright/installed.json" '"@accepted"'
tw apply --project "$A" > "$TMP/out" 2>&1
has "apply after accept: no changes" "$TMP/out" "apply: 0 changed"

# ---- inventory: versions from manifests, unfilled template docs ------------------
V="$TMP/versions"; mkdir -p "$V/backend" "$V/app"; git -C "$V" init -q -b main
cat > "$V/backend/package.json" <<'JSON'
{"name": "b", "engines": {"node": ">=20"}, "dependencies": {"prisma": "^6.19.2"}, "devDependencies": {"jest": "^29.7.0"}}
JSON
cat > "$V/backend/package-lock.json" <<'JSON'
{"lockfileVersion": 3, "packages": {"": {"dependencies": {"prisma": "^6.19.2"}, "devDependencies": {"jest": "^29.7.0"}},
 "node_modules/prisma": {"version": "6.19.2"}, "node_modules/jest": {"version": "29.7.0"}, "node_modules/left-pad": {"version": "1.0.0"}}}
JSON
cat > "$V/app/pubspec.yaml" <<'YML'
name: app
environment:
  sdk: ">=3.5.0 <4.0.0"
  flutter: ">=3.24.0"
dependencies:
  flutter:
    sdk: flutter
  http: ^1.2.0 # comment
flutter:
  assets:
    - assets/
YML
cat > "$V/app/pubspec.lock" <<'YML'
packages:
  http:
    dependency: "direct main"
    description:
      name: http
    source: hosted
    version: "1.2.2"
  meta:
    dependency: transitive
    version: "1.15.0"
sdks:
  dart: ">=3.5.0 <4.0.0"
  flutter: ">=3.24.0"
YML
tw apply --project "$V" --config "$TMP/a.yml" > /dev/null 2>&1
echo "# Our plan" > "$V/docs/plan.md"
tw inventory --project "$V" > "$TMP/inv.json"
python3 - "$TMP/inv.json" <<'PY' && ok "inventory: versions read from manifests and lock files" || bad "inventory: versions read from manifests and lock files" "$(cat "$TMP/inv.json")"
import json, sys
v = json.load(open(sys.argv[1]))["versions"]
assert v["backend/package.json"]["dependencies"]["prisma"] == "^6.19.2"
assert v["backend/package.json"]["engines"]["node"] == ">=20"
assert v["backend/package-lock.json"]["direct"] == {"jest": "29.7.0", "prisma": "6.19.2"}
assert v["app/pubspec.yaml"]["environment"]["flutter"] == ">=3.24.0"
assert v["app/pubspec.yaml"]["dependencies"]["http"] == "^1.2.0"
assert v["app/pubspec.lock"]["direct"] == {"http": "1.2.2"}
assert v["app/pubspec.lock"]["sdks"]["flutter"] == ">=3.24.0"
PY
python3 - "$TMP/inv.json" <<'PY' && ok "inventory: unfilled template docs listed, filled ones not" || bad "inventory: unfilled template docs listed, filled ones not"
import json, sys
u = json.load(open(sys.argv[1]))["unfilled_docs"]
assert "docs/requirements.md" in u and "docs/open-questions.md" in u and "docs/plan.md" not in u, u
PY

# ---- inventory: repository kind decides init vs adopt -------------------------------
kind_of() { tw inventory --project "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["kind"], ",".join(d["requirement_docs"]))'; }
KE="$TMP/kind-empty"; mkdir -p "$KE/.claude"; git -C "$KE" init -q -b main
printf 'MIT\n' > "$KE/LICENSE"; printf 'node_modules/\n' > "$KE/.gitignore"; printf '{}\n' > "$KE/.claude/settings.json"
expect_rc "kind: LICENSE, .gitignore and .claude/ only -> empty" "empty " "$(kind_of "$KE")"
KD="$TMP/kind-docs"; mkdir -p "$KD/docs/brief"; git -C "$KD" init -q -b main
REQDOC="docs/brief/ТЗ_мобильное_приложение.docx"
printf '# Idea\n' > "$KD/README.md"; printf 'x\n' > "$KD/$REQDOC"
printf 'x\n' > "$KD/docs/notes.md"; printf 'x\n' > "$KD/docs/mockup.png"
expect_rc "kind: documents only -> docs-only, requirement docs found (non-ASCII names too)" \
  "docs-only $REQDOC,README.md" "$(kind_of "$KD")"
printf 'node_modules/\n' > "$KD/.gitignore"; mkdir -p "$KD/node_modules"; printf 'x\n' > "$KD/node_modules/a.js"
expect_rc "kind: ignored files do not count" "docs-only $REQDOC,README.md" "$(kind_of "$KD")"
printf '{}\n' > "$KD/package.json"
expect_rc "kind: a build manifest -> code" "code $REQDOC,README.md" "$(kind_of "$KD")"
KN="$TMP/kind-nogit"; mkdir -p "$KN"; printf 'print(1)\n' > "$KN/main.py"
expect_rc "kind: works without git" "code " "$(kind_of "$KN")"
KF="$TMP/kind-names"; mkdir -p "$KF/docs" "$KF/vendor/lib"; git -C "$KF" init -q -b main
for f in "отзывы_клиентов.md" "inspection-notes.md" "revision-history.md" "docs/product-brief.md" \
  "docs/Техническое_задание.pdf" "vendor/lib/README.md" "docs/README.md"; do printf 'x\n' > "$KF/$f"; done
expect_rc "kind: whole words only, nested READMEs left out, named documents first" \
  "docs-only docs/product-brief.md,docs/Техническое_задание.pdf,docs/README.md" "$(kind_of "$KF")"
KB="$TMP/kind-badgit"; mkdir -p "$KB"; git -C "$KB" init -q -b main; printf 'print(1)\n' > "$KB/main.py"
printf 'garbage' > "$KB/.git/index"
expect_rc "kind: a failing git listing falls back to the tree, not to empty" "code " "$(kind_of "$KB")"
KI="$TMP/kind-installed"; mkdir -p "$KI/scripts/hooks" "$KI/.teamwright"; git -C "$KI" init -q -b main
printf '#!/bin/sh\n' > "$KI/scripts/hooks/pre-commit"; printf '# Requirements\n' > "$KI/README.md"
printf '{"scripts/hooks/pre-commit": "x"}\n' > "$KI/.teamwright/installed.json"
expect_rc "kind: files teamwright installed do not make it code (interrupted init)" "docs-only README.md" "$(kind_of "$KI")"

# ---- scan: classified findings, only secret-like ones fail -----------------------
C="$TMP/classes"; mkdir -p "$C/tests" "$C/docs"; git -C "$C" init -q -b main
PW="Zx9!hunter2hunter2"
echo "db_password = \"$PW\"" > "$C/tests/conftest.py"
echo "Set API_KEY=$PW in your shell" > "$C/docs/setup.md"
echo "DATABASE_URL: postgres://postgres:postgres@localhost:5432/app" > "$C/docker-compose.yml"
tw --json scan --project "$C" > "$TMP/out" 2>&1
expect_rc "only non-blocking classes: scan exits 0" 0 "$?"
python3 - "$TMP/out" <<'PY' && ok "scan summary per class" || bad "scan summary per class" "$(cat "$TMP/out")"
import json, sys
j = json.load(open(sys.argv[1]))
assert j["summary"] == {"secret-like": 0, "config-placeholder": 1, "test-fixture": 1, "docs-example": 1}, j["summary"]
assert j["blocking"] == 0
PY
echo "token = \"$PW\"" > "$C/app.py"
tw scan --project "$C" > "$TMP/out" 2>&1
expect_rc "secret-like finding: scan exits 1" 1 "$?"
has "text output names the blocking finding" "$TMP/out" "SECRET?"
has "text output has a summary" "$TMP/out" "summary: secret-like 1, config-placeholder 1, test-fixture 1, docs-example 1"

# ---- check-commands: pass / fail / not-runnable / modifies tracked files ---------
X="$TMP/check"; mkdir -p "$X/pkg"; git -C "$X" init -q -b main
echo "v1" > "$X/pkg/tracked.txt"; git -C "$X" add -A; git -C "$X" commit -qm init
cat > "$TMP/x.yml" <<'YML'
version: 1
mode: enforce
areas:
  - name: core
    workdir: pkg
    generate_command: "echo generated > tracked.txt"
    test_command: "test -f tracked.txt && pwd"
    lint_command: "exit 3"
    api_test_command: "no-such-tool-xyz --run"
  - name: other
    test_command: "echo changed >> pkg/tracked.txt"
gate_command: "make check"
YML
tw check-commands --project "$X" --config "$TMP/x.yml" > "$TMP/out" 2>&1
expect_rc "check-commands exits 1 when something fails" 1 "$?"
has "pass reported" "$TMP/out" "pass          core       test_command"
has "fail reported" "$TMP/out" "fail          core       lint_command"
has "missing tool is not runnable" "$TMP/out" "not-runnable  core       api_test_command"
has "generate runs first, separately" "$TMP/out" "pass          core       generate_command"
has "gate modifying tracked files flagged" "$TMP/out" "gate modifies tracked files: pkg/tracked.txt"
has "summary line" "$TMP/out" "check-commands: 5 command(s), 2 pass, 2 fail, 1 not runnable"
[ -f "$X/.teamwright/logs/check-commands/core.lint.log" ] && ok "per-command log kept under .teamwright/logs" \
  || bad "per-command log kept under .teamwright/logs"
tw --json check-commands --project "$X" --config "$TMP/x.yml" --area core > "$TMP/out" 2>&1
python3 - "$TMP/out" <<'PY' && ok "check-commands --json --area" || bad "check-commands --json --area" "$(cat "$TMP/out")"
import json, sys
j = json.load(open(sys.argv[1]))
st = {r["key"]: r["status"] for r in j["results"]}
assert st == {"generate_command": "pass", "test_command": "pass", "lint_command": "fail",
              "api_test_command": "not-runnable"}, st
assert not j["ok"]
PY
printf 'version: 1\nareas:\n  - name: slow\n    test_command: "sleep 5"\n' > "$TMP/slow.yml"
tw check-commands --project "$X" --config "$TMP/slow.yml" --timeout 1 > "$TMP/out" 2>&1
has "timeout is a failure with a reason" "$TMP/out" "timeout after 1s"
printf 'version: 1\nareas:\n  - name: d\n    runner: docker\n    image: "x:1"\n    test_command: "true"\n' > "$TMP/dk.yml"
TW_DOCKER=no-such-docker-xyz tw check-commands --project "$X" --config "$TMP/dk.yml" > "$TMP/out" 2>&1
has "docker missing: not runnable" "$TMP/out" "not-runnable  d"
tw check-commands --project "$X" --config "$TMP/slow.yml" > /dev/null 2>&1
tw --json check-commands --project "$X" --config "$TMP/x.yml" --area other > "$TMP/out" 2>&1
python3 - "$TMP/out" <<'PY2' && ok "results carry runner and duration" || bad "results carry runner and duration" "$(cat "$TMP/out")"
import json, sys
r = json.load(open(sys.argv[1]))["results"][0]
assert r["runner"] == "host" and isinstance(r["duration_s"], float), r
PY2
printf 'version: 1\nareas:\n  - name: web\n    test_command: "true"\n    e2e_ui_command: ""\ntools:\n  ui_verify: playwright\n' > "$TMP/ui.yml"
tw check-commands --project "$X" --config "$TMP/ui.yml" > "$TMP/out" 2>&1
expect_rc "a UI runner without an e2e_ui_command is not a pass" 1 "$?"
has "...reported as not runnable" "$TMP/out" "tools.ui_verify is playwright but no area has an e2e_ui_command"

# ---- documents written before install are the project's, not conflicts ----------------
D="$TMP/predocs"; mkdir -p "$D/docs"; git -C "$D" init -q -b main
printf '# Requirements\n\nVersion: 2 - Status: approved\n' > "$D/docs/requirements.md"
printf '# Open questions\n\n| OQ-01 | x |\n' > "$D/docs/open-questions.md"
write_cfg "$TMP/predocs.yml" fake-spec one
tw plan --project "$D" --config "$TMP/predocs.yml" > "$TMP/out" 2>&1
has "filled requirements kept as the project's" "$TMP/out" "kept-project    docs/requirements.md"
has "no conflict for project documents" "$TMP/out" "0 conflict(s)"
tw apply --project "$D" --config "$TMP/predocs.yml" > /dev/null 2>&1
has "apply leaves the filled requirements as they were" "$D/docs/requirements.md" "Status: approved"

# ---- no_mcp: a tool used without its MCP server -------------------------------------------
N="$TMP/nomcp"; mkdir -p "$N"; git -C "$N" init -q -b main
write_cfg "$TMP/nomcp.yml" fake-spec one; printf 'no_mcp: [ui_verify]\n' >> "$TMP/nomcp.yml"
tw apply --project "$N" --config "$TMP/nomcp.yml" > /dev/null 2>&1
python3 - "$N" <<'PY2' && ok "no_mcp leaves the tool's MCP server out of .mcp.json" || bad "no_mcp leaves the tool's MCP server out of .mcp.json"
import json, os, sys
p = os.path.join(sys.argv[1], ".mcp.json")
m = json.load(open(p))["mcpServers"] if os.path.exists(p) else {}
assert "fake-ui" not in m and "fake-nav" in m, m
PY2
printf 'no_mcp: [browser]\n' >> "$TMP/nomcp.yml"
tw plan --project "$N" --config "$TMP/nomcp.yml" > "$TMP/out" 2>&1
has "no_mcp with an unknown capability is rejected" "$TMP/out" "no_mcp must be a list of capabilities"

# ---- check-commands: changes outside the area's workdir are notes; environment errors ----
echo "o1" > "$X/outside.txt"; git -C "$X" add -A; git -C "$X" commit -qm outside
cat > "$TMP/env.yml" <<'YML'
version: 1
areas:
  - name: app
    workdir: pkg
    test_command: "echo edited >> ../outside.txt"
    lint_command: "echo 'connect ECONNREFUSED 127.0.0.1:5432'; echo '161 failed'; exit 1"
    api_test_command: "echo 'Error: P1001: database server at localhost:5432 is not reachable'; exit 1"
    e2e_ui_command: "echo 'No devices found'; exit 1"
  - name: web
    test_command: "echo 'expected 200, got 404: not found'; exit 1"
YML
tw check-commands --project "$X" --config "$TMP/env.yml" > "$TMP/out" 2>&1
has "change outside workdir is not a failure" "$TMP/out" "pass          app        test_command"
has "change outside workdir is reported as a note" "$TMP/out" "note: app test_command: tracked files outside workdir 'pkg' changed during the run"
has "refused DB connection: not runnable (environment)" "$TMP/out" "not-runnable  app        lint_command"
has "environment reason names the line" "$TMP/out" "environment (service not reachable): connect ECONNREFUSED 127.0.0.1:5432"
has "Prisma P1001: not runnable" "$TMP/out" "not-runnable  app        api_test_command"
has "no device for UI e2e: not runnable" "$TMP/out" "environment (no device): No devices found"
has "a real assertion failure stays fail" "$TMP/out" "fail          web        test_command"
printf 'version: 1\nareas:\n  - name: ui\n    e2e_ui_command: "echo npm error npx canceled due to missing packages and no YES option: [\\"playwright\\"]; exit 1"\n' > "$TMP/npx.yml"
tw check-commands --project "$X" --config "$TMP/npx.yml" > "$TMP/out" 2>&1
has "npx refusing to download: not runnable (environment), not fail" "$TMP/out" "environment (package not installed)"
printf 'version: 1\nareas:\n  - name: web\n    test_command: "true"\ntools:\n  ui_verify: playwright\nui_verify_deferred: "decisions.md #6"\n' > "$TMP/ui2.yml"
tw check-commands --project "$X" --config "$TMP/ui2.yml" > "$TMP/out" 2>&1
expect_rc "deferred UI verification: check-commands passes" 0 "$?"
has "...and says it is deferred" "$TMP/out" "note: UI verification deferred by the owner (decisions.md #6)"
printf 'version: 1\nareas:\n  - name: web\n    test_command: "true"\ntools:\n  ui_verify: none\nui_verify_deferred: "decisions.md #2"\n' > "$TMP/ui3.yml"
tw check-commands --project "$X" --config "$TMP/ui3.yml" > "$TMP/out" 2>&1
has "deferral is noted with ui_verify: none too" "$TMP/out" "note: UI verification deferred by the owner (decisions.md #2): tools.ui_verify is none"
printf 'ui_verify_deferred: ""\n' >> "$TMP/ui2.yml"
tw check-commands --project "$X" --config "$TMP/ui2.yml" > "$TMP/out" 2>&1
has "an empty deferral reason is rejected" "$TMP/out" "ui_verify_deferred must be a non-empty reason"
git -C "$X" checkout -q -- outside.txt
tw --json check-commands --project "$X" --config "$TMP/env.yml" --area app > "$TMP/out" 2>&1
python3 -c '
import json, sys
j = json.load(open(sys.argv[1]))
r = {x["key"]: x for x in j["results"]}
assert r["lint_command"]["environment"] == "service not reachable", r
assert r["test_command"]["changed_outside_workdir"] == ["outside.txt"], r
assert "modifies" not in r["test_command"], r
' "$TMP/out" && ok "json: environment kind and changed_outside_workdir" || bad "json: environment kind and changed_outside_workdir" "$(cat "$TMP/out")"
git -C "$X" checkout -q -- outside.txt


# ---- the plugin travels with the project --------------------------------------
# the version the installer records: plugin.json's, or on a release channel (no version) the commit
KV="$(python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("twi", sys.argv[1]+"/scripts/tw-install.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.kit_info(sys.argv[1])["version"])' "$K")"
KM="$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json"; mkdir -p "$(dirname "$KM")"
P="$TMP/plug"; mkdir -p "$P"; git -C "$P" init -q -b main
write_cfg "$TMP/plug.yml"
printf '{"teamwright": {"source": {"source": "github", "repo": "acme/teamwright", "ref": "next"}}}\n' > "$KM"
tw apply --project "$P" --config "$TMP/plug.yml" > "$TMP/out" 2>&1
python3 - "$P" "$KV" <<'PY' && ok "settings enable the plugin and name its marketplace; installed.json records the version" || bad "plugin in settings and @kit" "$(cat "$TMP/out")"
import json, sys
s = json.load(open(sys.argv[1] + "/.claude/settings.json"))
assert s["enabledPlugins"] == {"teamwright@teamwright": True}, s
assert s["extraKnownMarketplaces"] == {"teamwright": {"source": {"source": "github", "repo": "acme/teamwright", "ref": "next"}}}, s
m = json.load(open(sys.argv[1] + "/.teamwright/installed.json"))
assert m["@kit"] == {"plugin": "teamwright@teamwright", "version": sys.argv[2]}, m["@kit"]
cmds = [h["command"] for g in s["hooks"]["SessionStart"] for h in g["hooks"]]
assert any("session-check.sh" in c for c in cmds), cmds
PY
[ -x "$P/scripts/hooks/session-check.sh" ] && ok "session-check.sh installed executable" || bad "session-check.sh installed executable"
tw plan --project "$P" --config "$TMP/plug.yml" > "$TMP/out" 2>&1
hasnt "same version: no kit-version action" "$TMP/out" "kit-version"
python3 - "$P" <<'PY'
import json, sys
p = sys.argv[1] + "/.teamwright/installed.json"; m = json.load(open(p)); m["@kit"]["version"] = "0.0.1"
json.dump(m, open(p, "w"))
p = sys.argv[1] + "/.claude/settings.json"; s = json.load(open(p))
s["enabledPlugins"]["teamwright@teamwright"] = False
s["extraKnownMarketplaces"]["teamwright"] = {"source": {"source": "github", "repo": "mine/fork"}}
json.dump(s, open(p, "w"))
PY
tw plan --project "$P" --config "$TMP/plug.yml" > "$TMP/out" 2>&1
has "older recorded version: plan shows kit-version" "$TMP/out" "kit-version     .teamwright/installed.json  (teamwright@teamwright $KV)"
tw apply --project "$P" --config "$TMP/plug.yml" > /dev/null 2>&1
python3 - "$P" "$KV" <<'PY' && ok "update: version re-recorded, owner's plugin choices kept" || bad "update keeps owner's plugin choices"
import json, sys
s = json.load(open(sys.argv[1] + "/.claude/settings.json"))
assert s["enabledPlugins"]["teamwright@teamwright"] is False
assert s["extraKnownMarketplaces"]["teamwright"]["source"]["repo"] == "mine/fork"
assert json.load(open(sys.argv[1] + "/.teamwright/installed.json"))["@kit"]["version"] == sys.argv[2]
PY

# a local-directory marketplace becomes its git origin (+ branch); a token is never written
R="$TMP/kitrepo"; mkdir -p "$R"; git -C "$R" init -q -b pilot
git -C "$R" remote add origin https://github.com/acme/tw.git
printf '{"teamwright": {"source": {"source": "directory", "path": "%s"}}}\n' "$R" > "$KM"
P2="$TMP/plug2"; mkdir -p "$P2"; git -C "$P2" init -q -b main
tw apply --project "$P2" --config "$TMP/plug.yml" > /dev/null 2>&1
python3 -c 'import json,sys; s=json.load(open(sys.argv[1]+"/.claude/settings.json")); assert s["extraKnownMarketplaces"]["teamwright"]["source"]=={"source":"github","repo":"acme/tw","ref":"pilot"}, s' "$P2" \
  && ok "directory marketplace: github origin with its branch" || bad "directory marketplace -> github origin"
git -C "$R" remote set-url origin https://user:secret@git.example.com/acme/tw.git
P3="$TMP/plug3"; mkdir -p "$P3"; git -C "$P3" init -q -b main
tw apply --project "$P3" --config "$TMP/plug.yml" > "$TMP/out" 2>&1
hasnt "a remote with credentials is never written" "$P3/.claude/settings.json" "secret"
has "no shareable source: noted" "$TMP/out" "no shareable source for marketplace 'teamwright'"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1]+"/.claude/settings.json")); assert s["enabledPlugins"]=={"teamwright@teamwright": True}' "$P3" \
  && ok "no source: the plugin is still enabled" || bad "no source: plugin enabled"
rm -f "$KM"

# ---- release channels: a kit without a version, one channel per project ----------------
KC="$TMP/kit-next"; cp -R "$K" "$KC"
python3 - "$KC" <<'PY'
import json, sys
p = sys.argv[1] + "/.claude-plugin/plugin.json"; d = json.load(open(p)); d.pop("version", None); json.dump(d, open(p, "w"))
p = sys.argv[1] + "/.claude-plugin/marketplace.json"; d = json.load(open(p)); d["name"] = "teamwright-next"
for e in d["plugins"]:
    e.pop("version", None)
json.dump(d, open(p, "w"))
PY
twc() { python3 "$1/scripts/tw-install.py" --kit "$1" --providers "$FIX" "${@:2}"; }
kitrec() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]+"/.teamwright/installed.json"))["@kit"], sort_keys=True))' "$1"; }
git -C "$KC" init -q -b next && git -C "$KC" add -A && git -C "$KC" commit -qm channel
SHA="$(git -C "$KC" rev-parse HEAD | cut -c1-12)"
PC="$TMP/chan1"; mkdir -p "$PC"; git -C "$PC" init -q -b main
twc "$KC" apply --project "$PC" --config "$TMP/plug.yml" > "$TMP/out" 2>&1
expect_rc "channel kit from a git checkout: version = the commit (12 hex, as Claude Code computes it)" \
  "{\"plugin\": \"teamwright@teamwright-next\", \"version\": \"$SHA\"}" "$(kitrec "$PC")"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1]+"/.claude/settings.json")); assert s["enabledPlugins"]=={"teamwright@teamwright-next": True}, s' "$PC" \
  && ok "channel kit alone: its plugin id is enabled" || bad "channel kit alone: its plugin id is enabled"
KCC="$TMP/cache/teamwright-next/teamwright/abcdef012345"; mkdir -p "$(dirname "$KCC")"; cp -R "$KC" "$KCC"; rm -rf "$KCC/.git"
mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
printf '{"version": 2, "plugins": {"teamwright@teamwright-next": [{"scope": "user", "installPath": "%s", "version": "abcdef012345"}]}}\n' "$KCC" \
  > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
twc "$KCC" apply --project "$PC" --config "$TMP/plug.yml" > "$TMP/out" 2>&1
expect_rc "channel kit from the plugin cache (no .git): version from installed_plugins.json" \
  '{"plugin": "teamwright@teamwright-next", "version": "abcdef012345"}' "$(kitrec "$PC")"
rm -f "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
twc "$KCC" plan --project "$PC" --config "$TMP/plug.yml" > "$TMP/out" 2>&1
has "a channel copy nobody recorded: version empty, re-recorded (no crash)" "$TMP/out" "kit-version"
PS2="$TMP/chan2"; mkdir -p "$PS2/.claude"; git -C "$PS2" init -q -b main
printf '{"enabledPlugins": {"teamwright@teamwright": true}}\n' > "$PS2/.claude/settings.json"
twc "$KC" apply --project "$PS2" --config "$TMP/plug.yml" > "$TMP/out" 2>&1
python3 -c 'import json,sys; s=json.load(open(sys.argv[1]+"/.claude/settings.json")); assert s["enabledPlugins"]=={"teamwright@teamwright": True}, s["enabledPlugins"]; assert "teamwright-next" not in (s.get("extraKnownMarketplaces") or {}), s' "$PS2" \
  && ok "the project enables the stable channel: the channel kit does not enable a second copy" \
  || bad "the project enables the stable channel: the channel kit does not enable a second copy"
has "one channel per project: noted" "$TMP/out" "one channel per project"
has "the rest of the settings are still merged (hooks)" "$PS2/.claude/settings.json" "session-check.sh"
PS3="$TMP/chan3"; mkdir -p "$PS3/.claude"; git -C "$PS3" init -q -b main
printf '{"enabledPlugins": {"teamwright@teamwright-next": true}}\n' > "$PS3/.claude/settings.local.json"
tw apply --project "$PS3" --config "$TMP/plug.yml" > "$TMP/out" 2>&1
python3 -c 'import json,sys; s=json.load(open(sys.argv[1]+"/.claude/settings.json")); assert "teamwright@teamwright" not in (s.get("enabledPlugins") or {}), s' "$PS3" \
  && ok "next enabled in settings.local.json: the stable kit does not enable itself in settings.json" \
  || bad "next enabled in settings.local.json: the stable kit does not enable itself in settings.json"

# ---- process settings: validated, rendered, absent = defaults -------------------------
PS="$TMP/procset"; mkdir -p "$PS"; git -C "$PS" init -q -b main
write_cfg "$TMP/ps.yml" fake-spec one
cp "$TMP/ps.yml" "$TMP/ps-bad.yml"
printf 'process:\n  review:\n    blocking: strict\n  speed: 2\n' >> "$TMP/ps-bad.yml"
tw plan --project "$PS" --config "$TMP/ps-bad.yml" > "$TMP/out" 2>&1
expect_rc "invalid process settings: plan fails" 1 "$?"
has "unknown process key named" "$TMP/out" "process.speed: unknown key"
has "bad threshold named" "$TMP/out" "process.review.blocking must be one of"
tw apply --project "$PS" --config "$TMP/ps.yml" > "$TMP/out" 2>&1
has "no settings: AGENTS.md renders the defaults" "$PS/AGENTS.md" "review blocks from **low** findings up"
cp "$TMP/ps.yml" "$TMP/ps-next.yml"
printf 'process:\n  review:\n    blocking: medium\n  batch:\n    max_tasks: 3\n    by_priority:\n      P1: 2\n  autonomy:\n    start: auto\n    continue: true\n' >> "$TMP/ps-next.yml"
tw apply --project "$PS" --config "$TMP/ps-next.yml" > "$TMP/out" 2>&1
expect_rc "valid process settings apply" 0 "$?"
has "AGENTS.md renders the threshold" "$PS/AGENTS.md" "review blocks from **medium** findings up"
has "AGENTS.md renders the per-priority caps" "$PS/AGENTS.md" "P0 1, P1 2, P2 3, P3 3"
has "code-reviewer renders the threshold" "$PS/.claude/agents/code-reviewer.md" "Blocking threshold: medium"
grep -q "{{REVIEW_BLOCKING}}\|{{BATCH_" "$PS/AGENTS.md" "$PS/.claude/agents/code-reviewer.md" \
  && bad "no settings placeholder left unresolved" || ok "no settings placeholder left unresolved"
grep -q "^process:" "$PS/.teamwright/config.yml" && ok "settings written to config.yml" || bad "settings written to config.yml"
has "AGENTS.md renders the parallel setting" "$PS/AGENTS.md" "tasks in parallel worktrees: **1**"
[ -x "$PS/scripts/tw-req" ] && ok "scripts/tw-req installed executable" || bad "scripts/tw-req installed executable"
awk '{print} /^  - name: backend$/{print "    ci_workflow: \"\""}' "$TMP/ps.yml" > "$TMP/ps-ci.yml"
tw plan --project "$PS" --config "$TMP/ps-ci.yml" > "$TMP/out" 2>&1
has "empty ci_workflow is refused" "$TMP/out" "ci_workflow must name the CI workflow"
awk '{print} /^  - name: backend$/{print "    generated: [../out]"; print "    copy_env: [x]"}' "$TMP/ps.yml" > "$TMP/ps-gen.yml"
tw plan --project "$PS" --config "$TMP/ps-gen.yml" > "$TMP/out" 2>&1
has "generated outside the project is refused" "$TMP/out" "generated must be a list of paths relative"
has "generated without generate_command is refused" "$TMP/out" "generated names the outputs of generate_command"
has "copy_env must be a map" "$TMP/out" "copy_env must map variable names"
awk '{print} /^  - name: backend$/{print "    generate_command: \"make gen\""; print "    generated: [backend/gen]"; print "    copy_env:"; print "      CARGO_TARGET_DIR: \"{cache}/target\""}' "$TMP/ps.yml" > "$TMP/ps-gen2.yml"
tw plan --project "$PS" --config "$TMP/ps-gen2.yml" > "$TMP/out" 2>&1; expect_rc "generated and copy_env accepted" 0 "$?"
# test guard keys: test_select_command, test_runner_patterns, process.test_guard
awk '{print} /^  - name: backend$/{print "    test_select_command: \"pytest -q\""}' "$TMP/ps.yml" > "$TMP/ps-ts.yml"
printf 'test_runner_patterns: ["(unclosed"]\nprocess:\n  test_guard: maybe\n' >> "$TMP/ps-ts.yml"
tw plan --project "$PS" --config "$TMP/ps-ts.yml" > "$TMP/out" 2>&1
has "test_select_command without {tests} is refused" "$TMP/out" "test_select_command must be a command with a {tests} placeholder"
has "a bad test_runner_patterns regex is refused" "$TMP/out" "test_runner_patterns: '(unclosed' is not a valid regular expression"
has "a bad process.test_guard is refused" "$TMP/out" "process.test_guard must be one of block, warn, off"
awk '{print} /^  - name: backend$/{print "    test_select_command: \"scripts/tw-run backend -- pytest {tests}\""}' "$TMP/ps.yml" > "$TMP/ps-ts2.yml"
tw plan --project "$PS" --config "$TMP/ps-ts2.yml" > "$TMP/out" 2>&1
has "test_select_command wrapped in tw-run is refused" "$TMP/out" "test_select_command: write the bare command"
awk '{print} /^  - name: backend$/{print "    test_select_command: \"pytest -q -n ${PYTEST_WORKERS:-4} {tests}\""}' "$TMP/ps.yml" > "$TMP/ps-ts3.yml"
printf 'test_runner_patterns: ["^bin/specs"]\nprocess:\n  test_guard: warn\n' >> "$TMP/ps-ts3.yml"
tw plan --project "$PS" --config "$TMP/ps-ts3.yml" > "$TMP/out" 2>&1; expect_rc "test guard keys accepted" 0 "$?"
# stages, models and the selection mode (0.12)
cp "$TMP/ps.yml" "$TMP/ps-st.yml"
printf 'process:\n  stages:\n    review:\n      batch: 0\n      min: 3\n      linger: 2\n    deploy:\n      batch: 1\n    implement: 2\n  models:\n    review: gpt-9\n  router:\n    select: llm\n' >> "$TMP/ps-st.yml"
tw plan --project "$PS" --config "$TMP/ps-st.yml" > "$TMP/out" 2>&1
expect_rc "invalid stage settings: plan fails" 1 "$?"
has "a stage batch out of range is refused" "$TMP/out" "process.stages.review.batch must be 1..10"
has "an unknown stage key is refused" "$TMP/out" "process.stages.review.linger: unknown key"
has "an unknown stage is refused" "$TMP/out" "process.stages.deploy: unknown key"
has "a stage must be a mapping" "$TMP/out" "process.stages.implement must be a mapping"
has "an unknown model is refused" "$TMP/out" "process.models.review must be a model alias"
has "a bad selection mode is refused" "$TMP/out" "process.router.select must be one of script, agent"
cp "$TMP/ps.yml" "$TMP/ps-st2.yml"
printf 'process:\n  stages:\n    review:\n      batch: 3\n      min: 2\n      max_wait_hours: 4\n    red-tests:\n      batch: 2\n  models:\n    red-tests: sonnet\n    review: claude-opus-4-1\n  router:\n    select: agent\n' >> "$TMP/ps-st2.yml"
tw plan --project "$PS" --config "$TMP/ps-st2.yml" > "$TMP/out" 2>&1; expect_rc "stages, models and router.select accepted" 0 "$?"
grep -q "review_blocking" "$PS/.teamwright/config.yml" && bad "rendered helper keys are not written back" || ok "rendered helper keys are not written back"

# render drift (#6): a settings change does not reach a locally edited role file
drift() { python3 "$KIT/scripts/tw-process.py" --project "$PS" --json | python3 -c 'import json,sys; print(" ".join("%s:%s:%s->%s" % (d["file"], d["setting"], d["found"], d["expected"]) for d in json.load(sys.stdin)["render_drift"]))'; }
expect_rc "freshly rendered files: no drift" "" "$(drift)"
printf '\nLocal note: we also check migrations.\n' >> "$PS/.claude/agents/code-reviewer.md"
sed 's/blocking: medium/blocking: high/' "$TMP/ps-next.yml" > "$TMP/ps-high.yml"
tw apply --project "$PS" --config "$TMP/ps-high.yml" > "$TMP/out" 2>&1
has "AGENTS.md follows the change" "$PS/AGENTS.md" "review blocks from **high** findings up"
expect_rc "the edited reviewer file keeps the old threshold and is reported" \
  ".claude/agents/code-reviewer.md:review_blocking:medium->high" "$(drift)"
mkdir -p "$PS/docs/tasks"; task_file "$PS/docs/tasks/T-1.md" T-1 TODO bug full
python3 "$KIT/scripts/tw-next.py" --project "$PS" --json | grep -q "render drift: .claude/agents/code-reviewer.md carries review_blocking medium, config says high" \
  && ok "the router warns about the drift" || bad "the router warns about the drift"
sed -i.bak 's/Blocking threshold: medium/Blocking threshold: high/' "$PS/.claude/agents/code-reviewer.md"
expect_rc "fixed by hand: no drift, the local note stays" "" "$(drift)"

finish
