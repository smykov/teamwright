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
