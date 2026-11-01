#!/usr/bin/env bash
# Regression: agents cannot change teamwright's own state - the mode switch
# (.teamwright/config.yml), the install manifest and the ledgers. Config changes go
# through tw-install.py, run by the main session with the owner.
. "$(dirname "$0")/lib.sh"
echo "state-guard"
GATE="$HOOKS/review-gate.sh"
P="$TMP/proj"; mkdir -p "$P/.teamwright/sessions" "$P/docs/tasks"
export CLAUDE_PROJECT_DIR="$P"
printf 'version: 1\nmode: enforce\nareas:\n  - name: core\n' > "$P/.teamwright/config.yml"
echo '{}' > "$P/.teamwright/installed.json"
SUB=(@agent_id=a-dev @agent_type=developer)
run() { hook_json "$@" | bash "$GATE"; }
CFG="$P/.teamwright/config.yml"

# ---- Edit / Write -----------------------------------------------------------------
expect_deny "subagent Edit of config.yml denied" \
  "$(run Edit s1 "file_path=$CFG" "old_string=mode: enforce" "new_string=mode: gate-first" "${SUB[@]}")" "STATE GUARD"
expect_deny "main session Write of config.yml denied" \
  "$(run Write s1 "file_path=.teamwright/config.yml" "content=mode: gate-first")" "STATE GUARD"
expect_deny "Write of installed.json denied" \
  "$(run Write s1 "file_path=$P/.teamwright/installed.json" "content={}" "${SUB[@]}")" "STATE GUARD"
expect_deny "Write of a session ledger denied" \
  "$(run Write s1 "file_path=.teamwright/sessions/T-1.reviews.jsonl" "content={}" "${SUB[@]}")" "STATE GUARD"
expect_deny "Write of the journal denied" \
  "$(run Write s1 "file_path=.teamwright/logs/tools.jsonl" "content={}" "${SUB[@]}")" "STATE GUARD"
expect_allow "Write of an unrelated .teamwright file allowed" \
  "$(run Write s1 "file_path=.teamwright/config.next.yml" "content=mode: enforce")"

# ---- the secret scan before the commit is the agent's to run ----------------------
TW=(@agent_id=a-t @agent_type=test-writer)
expect_allow "scripts/tw-scan runs under enforce" "$(run Bash s1 "command=scripts/tw-scan" "${TW[@]}")"
expect_allow "scripts/tw-scan --strict runs under enforce" "$(run Bash s1 "command=./scripts/tw-scan --strict" "${TW[@]}")"
expect_deny "the hook itself stays refused" "$(run Bash s1 "command=scripts/hooks/pre-commit" "${TW[@]}")" "STATE GUARD"

# ---- gate-first does not soften the guard on the mode switch ---------------------
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\n' > "$CFG"
expect_deny "gate-first: config.yml still hard-denied" \
  "$(run Write s1 "file_path=$CFG" "content=mode: enforce" "${SUB[@]}")" "STATE GUARD"
printf 'version: 1\nmode: enforce\nareas:\n  - name: core\n' > "$CFG"

# ---- Bash ---------------------------------------------------------------------------
expect_deny "sed -i on config.yml denied" \
  "$(run Bash s1 "command=sed -i s/enforce/gate-first/ .teamwright/config.yml")" "STATE GUARD"
expect_deny "redirect into installed.json denied" \
  "$(run Bash s1 "command=echo {} > .teamwright/installed.json" "${SUB[@]}")" "STATE GUARD"
expect_deny "python rewrite of config.yml denied" \
  "$(run Bash s1 "command=python3 -c \"open('.teamwright/config.yml','w').write('mode: gate-first')\"")" "STATE GUARD"
expect_deny "cd + sed on config.yml denied" \
  "$(run Bash s1 "command=cd .teamwright && sed -i s/enforce/gate-first/ config.yml")" "STATE GUARD"
expect_allow "reading config.yml allowed" "$(run Bash s1 "command=cat .teamwright/config.yml")"
expect_allow "main session runs the installer" \
  "$(run Bash s1 "command=python3 /kit/scripts/tw-install.py apply --config .teamwright/config.next.yml")"
expect_deny "subagent cannot run the installer" \
  "$(run Bash s1 "command=python3 /kit/scripts/tw-install.py enforce" "${SUB[@]}")" "STATE GUARD"
expect_deny "installer call chained with a config rewrite denied" \
  "$(run Bash s1 "command=python3 tw-install.py plan; sed -i s/enforce/gate-first/ .teamwright/config.yml")" "STATE GUARD"
expect_deny "agent cannot claim the owner override" \
  "$(run Bash s1 "command=TEAMWRIGHT_OWNER=1 python3 tw-install.py apply --config x.yml")" "STATE GUARD"
expect_deny "agent cannot hide the Claude Code context" \
  "$(run Bash s1 "command=env -u CLAUDECODE python3 tw-install.py apply --config x.yml")" "STATE GUARD"
grep -q "mode: enforce" "$CFG" && ok "config unchanged by denied calls" || bad "config unchanged by denied calls"

# ---- files that define the gates: a person decides -----------------------------------
KIT_WRITES=(
  "Write|file_path=$P/scripts/hooks/review-gate.sh|an agent cannot silently rewrite a hook"
  "Edit|file_path=.claude/settings.json|Edit of settings.json asks"
  "Write|file_path=.claude/settings.local.json|Write of settings.local.json asks"
  "Write|file_path=.claude/agents/code-reviewer.md|Write of an agent definition asks"
  "Write|file_path=.mcp.json|Write of .mcp.json asks"
  "Write|file_path=.git/config|Write of .git/config asks"
  "Write|file_path=.git/hooks/pre-push|Write into .git/hooks asks"
  "Bash|command=echo x > scripts/hooks/pre-push|redirect into a hook asks"
  "Bash|command=cd scripts/hooks && echo exit > review-gate.sh|cd + redirect into a hook asks"
  "Bash|command=cd .claude && echo {} > settings.json|cd + redirect into settings asks"
  "Bash|command=echo {} | tee .mcp.json|tee into .mcp.json asks"
  "Bash|command=sed -i s/deny/allow/ .claude/settings.json|sed -i on settings asks"
  "Bash|command=cp /tmp/evil.md .claude/agents/code-reviewer.md|cp onto an agent definition asks"
  "Bash|command=mv /tmp/s.json .claude/settings.json|mv onto settings asks"
  "Bash|command=rm scripts/hooks/review-gate.sh|rm of a hook asks"
  "Bash|command=rm -f .mcp.json|rm of .mcp.json asks"
  "Bash|command=chmod -x scripts/hooks/pre-push|chmod of a hook asks"
  "Bash|command=git checkout HEAD~1 -- scripts/hooks/pre-push|checkout of an old hook asks"
  "Bash|command=python3 -c \"open('.mcp.json','w').write('{}')\"|python write of .mcp.json asks"
  "Bash|command=bash -c 'echo {} > .claude/settings.json'|bash -c redirect into settings asks"
  "Bash|command=echo x >> .git/config|append to .git/config asks"
  "Bash|command=echo x > $P/.mcp.json|absolute path inside the project asks"
)
for row in "${KIT_WRITES[@]}"; do
  IFS='|' read -r t f d <<<"$row"
  case "$d" in *"tee into"*) f="command=echo {} | tee .mcp.json"; d="tee into .mcp.json asks" ;; esac
  expect_ask "$d" "$(run "$t" s1 "$f" "content=x" "old_string=a" "new_string=b")" "STATE GUARD"
done
expect_ask "a subagent's write is asked about too" \
  "$(run Write s1 "file_path=.claude/agents/x.md" "content=x" "${SUB[@]}")" "STATE GUARD"
expect_deny "dontAsk: nobody to ask, refused" \
  "$(run Write s1 "file_path=scripts/hooks/pre-push" "content=x" @permission_mode=dontAsk)" "STATE GUARD"
expect_deny "bypassPermissions: nobody to ask, refused" \
  "$(run Bash s1 "command=echo x > .mcp.json" @permission_mode=bypassPermissions)" "STATE GUARD"

# the legitimate paths stay open
for cmd in \
  "python3 /home/u/.claude/plugins/cache/teamwright/teamwright/9.9.9/scripts/tw-install.py update --no-fetch --apply" \
  "python3 /home/u/.claude/plugins/cache/teamwright/teamwright/9.9.9/scripts/tw-install.py update" \
  "python3 /kit/scripts/tw-install.py apply --accept .claude/settings.json" \
  "git add scripts/hooks .claude/settings.json .claude/agents .mcp.json .gitignore" \
  "git add -A && git commit -m 'chore(process): teamwright 0.15.1 -> 0.16.0, rewrites .mcp.json > scripts/hooks'" \
  "git status" "git diff -- scripts/hooks .claude/settings.json" "git log -p .mcp.json" \
  "bash scripts/install-hooks.sh" "bash scripts/install-hooks.sh --check" \
  "cat .claude/settings.json" "grep -n deny .claude/settings.json" "sed -n 1,5p scripts/hooks/pre-push" \
  "cp .mcp.json /tmp/mcp.bak" "python3 -c \"import json; print(json.dumps(json.load(open('.mcp.json'))))\"" \
  "echo x > docs/hooks.md" "echo x > src/scripts/hooks/fixture.txt" "cp a b" \
  "git config --get core.hooksPath" "git config core.hooksPath" "git config user.name ci" \
  "touch TEAMWRIGHT_PAUSE" "cat TEAMWRIGHT_PAUSE" "grep -rn TEAMWRIGHT_ALLOW_PUSH docs" \
  "git commit -m 'docs: a person runs TEAMWRIGHT_ALLOW_PUSH=1 git push, or rm TEAMWRIGHT_PAUSE'" \
  "git push origin main"; do
  expect_allow "allowed: $cmd" "$(run Bash s1 "command=$cmd")"
done
expect_allow "Write of a role-like file elsewhere allowed" "$(run Write s1 "file_path=docs/agents/x.md" "content=x")"
expect_allow "Write of a nested hooks path allowed" "$(run Write s1 "file_path=src/scripts/hooks/x.sh" "content=x")"

# ---- the human exits around git hooks: hard in every mode, naming them stays allowed ---
OVERRIDES=(
  "TEAMWRIGHT_ALLOW_PUSH=1 git push origin main"
  "export TEAMWRIGHT_ALLOW_PUSH=1; git push"
  "env TEAMWRIGHT_ALLOW_PUSH=1 git push"
  "bash -c 'TEAMWRIGHT_ALLOW_PUSH=1 git push'"
  "TEAMWRIGHT_PAUSE_FILE=/nonexistent git push"
  "TEAMWRIGHT_PUSH_STATUSES=TODO git push"
  "python3 -c \"import os,subprocess; os.environ['TEAMWRIGHT_ALLOW_PUSH']='1'; subprocess.run(['git','push'])\""
  "rm TEAMWRIGHT_PAUSE"
  "rm -f ./TEAMWRIGHT_PAUSE"
  "cd . && rm TEAMWRIGHT_PAUSE"
  "(rm TEAMWRIGHT_PAUSE)"
  "unlink TEAMWRIGHT_PAUSE"
  "mv TEAMWRIGHT_PAUSE /tmp/x"
  "git rm -f TEAMWRIGHT_PAUSE"
  "find . -name TEAMWRIGHT_PAUSE -delete"
  "python3 -c \"import os; os.remove('TEAMWRIGHT_PAUSE')\""
  "git config core.hooksPath /dev/null"
  "git config --local core.hooksPath .nothing"
  "git config --global core.hooksPath /dev/null"
  "git config --unset core.hooksPath"
  "git config --unset-all core.hookspath"
  "git -c core.hooksPath=/dev/null push"
  "git -c core.hooksPath=/dev/null commit -m x"
  "git -C . config core.hooksPath x"
  "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git push"
)
for cmd in "${OVERRIDES[@]}"; do
  expect_deny "refused: $cmd" "$(run Bash s1 "command=$cmd")" "STATE GUARD"
done

# ---- gate-first: the kit guard warns, the human exits stay refused -----------------------
printf 'version: 1\nmode: gate-first\nareas:\n  - name: core\n' > "$CFG"
gf="$(run Write s1 "file_path=.claude/settings.json" "content={}")"
case "$gf" in
  *'"permissionDecision"'*) bad "gate-first: a kit file write warns, no decision" "$gf" ;;
  *"gate-first"*"STATE GUARD"*) ok "gate-first: a kit file write warns, no decision" ;;
  *) bad "gate-first: a kit file write warns, no decision" "$gf" ;;
esac
expect_allow "gate-first: the installer's update passes silently" \
  "$(run Bash s1 "command=python3 /home/u/.claude/plugins/cache/teamwright/teamwright/9.9.9/scripts/tw-install.py update --no-fetch --apply")"
expect_allow "gate-first: committing the update passes silently" \
  "$(run Bash s1 "command=git add scripts/hooks .claude/settings.json && git commit -m 'chore(process): teamwright update'")"
expect_deny "gate-first: the push override is still refused" \
  "$(run Bash s1 "command=TEAMWRIGHT_ALLOW_PUSH=1 git push")" "STATE GUARD"
expect_deny "gate-first: removing the pause is still refused" "$(run Bash s1 "command=rm TEAMWRIGHT_PAUSE")" "STATE GUARD"
printf 'version: 1\nmode: enforce\nareas:\n  - name: core\n' > "$CFG"

# ---- only real writes count: naming the file is not writing it (real-world false positive)
expect_allow "git add + commit of config.yml allowed (message mentions install/tee/rm)" \
  "$(run Bash s1 "command=git add .teamwright/config.yml && git commit -m 'chore: install teamwright, rm old config.yml note, tee up review'")"
expect_allow "subagent may commit the config it proposed" \
  "$(run Bash s1 "command=git add .teamwright/config.yml docs/tasks/T-1.md && git commit -m 'T-1: config'" "${SUB[@]}")"
expect_allow "git diff / log of config.yml allowed" "$(run Bash s1 "command=git diff -- .teamwright/config.yml; git log -p .teamwright/config.yml")"
expect_allow "grep piped to head allowed" "$(run Bash s1 "command=grep -n mode .teamwright/config.yml | head -5")"
expect_allow "sed -n (read) allowed" "$(run Bash s1 "command=sed -n 1,20p .teamwright/config.yml")"
expect_allow "echo mentioning config.yml into another file allowed" \
  "$(run Bash s1 "command=echo 'see .teamwright/config.yml' >> docs/notes.md")"
expect_allow "copy config.yml to the proposal allowed" \
  "$(run Bash s1 "command=cp .teamwright/config.yml .teamwright/config.next.yml" "${SUB[@]}")"
expect_allow "write the proposal with a redirect allowed" \
  "$(run Bash s1 "command=sed s/flutter/fvm\\ flutter/ .teamwright/config.yml > .teamwright/config.next.yml" "${SUB[@]}")"
expect_allow "python reading config.yml allowed" \
  "$(run Bash s1 "command=python3 -c \"print(open('.teamwright/config.yml').read())\"")"
expect_allow "installer plan on the live config allowed (main session)" \
  "$(run Bash s1 "command=python3 \"\${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py\" plan --config .teamwright/config.yml")"
expect_allow "tw-run commands allowed" "$(run Bash s1 "command=scripts/tw-run app -- flutter test")"
expect_allow "Write of the proposal by a subagent allowed" \
  "$(run Write s1 "file_path=$P/.teamwright/config.next.yml" "content=mode: enforce" "${SUB[@]}")"

expect_deny "append redirect into config.yml denied" \
  "$(run Bash s1 "command=echo 'mode: gate-first' >> .teamwright/config.yml")" "config.next.yml"
expect_deny "tee into config.yml denied" "$(run Bash s1 "command=cat x.yml | tee .teamwright/config.yml")" "STATE GUARD"
expect_deny "mv proposal over config.yml denied" \
  "$(run Bash s1 "command=mv .teamwright/config.next.yml .teamwright/config.yml")" "STATE GUARD"
expect_deny "cp onto config.yml denied" "$(run Bash s1 "command=cp /tmp/x.yml .teamwright/config.yml")" "STATE GUARD"
expect_deny "rm of installed.json denied" "$(run Bash s1 "command=rm -f .teamwright/installed.json")" "STATE GUARD"
expect_deny "git checkout of config.yml denied" "$(run Bash s1 "command=git checkout HEAD -- .teamwright/config.yml")" "STATE GUARD"
expect_deny "heredoc into config.yml denied" \
  "$(run Bash s1 "command=cat > .teamwright/config.yml <<'EOF'
mode: gate-first
EOF")" "STATE GUARD"
expect_deny "python heredoc writing config.yml denied" \
  "$(run Bash s1 "command=python3 - <<'EOF'
open('.teamwright/config.yml', 'w').write('mode: gate-first')
EOF")" "STATE GUARD"
expect_deny "bash -c with a redirect denied" \
  "$(run Bash s1 "command=bash -c 'echo mode: gate-first > .teamwright/config.yml'")" "STATE GUARD"
expect_deny "glob sed -i over .teamwright denied" "$(run Bash s1 "command=sed -i s/a/b/ .teamwright/*.yml")" "STATE GUARD"
expect_deny "node writeFileSync denied" \
  "$(run Bash s1 "command=node -e \"require('fs').writeFileSync('.teamwright/config.yml','x')\"")" "STATE GUARD"
expect_deny "subagent applying the proposal denied" \
  "$(run Bash s1 "command=python3 /kit/scripts/tw-install.py apply --config .teamwright/config.next.yml" "${SUB[@]}")" \
  "main session"

finish
