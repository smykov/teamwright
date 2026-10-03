#!/usr/bin/env bash
# Regression: journal.sh (tool-call, permission and outcome journals).
. "$(dirname "$0")/lib.sh"
echo "journal"
J="$HOOKS/journal.sh"
P="$TMP/proj"; mkdir -p "$P/docs/tasks" "$P/.teamwright"
export CLAUDE_PROJECT_DIR="$P"
L="$P/.teamwright/logs"
j() { hook_json "$@" | bash "$J"; }
field() {  # field FILE LINE_NO KEY -> value
  python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[int(sys.argv[2])-1]); v=r.get(sys.argv[3]); print(json.dumps(v) if isinstance(v,(list,bool)) else v)' "$@"
}

SECRET="s3cr3t""Value42"
out="$(j Bash s1 "command=cd /work && API_TOKEN=$SECRET curl -H 'Authorization: $SECRET' https://example.invalid" \
  @hook_event_name=PreToolUse @agent_id=a1 @agent_type=developer)"
expect_allow "journal prints nothing (never a decision)" "$out"
expect_rc "PreToolUse writes tools.jsonl" 1 "$(wc -l < "$L/tools.jsonl" | tr -d ' ')"
expect_rc "event is pre" pre "$(field "$L/tools.jsonl" 1 event)"
expect_rc "agent_id is recorded" a1 "$(field "$L/tools.jsonl" 1 agent_id)"
expect_rc "agent_type is recorded" developer "$(field "$L/tools.jsonl" 1 agent_type)"
expect_rc "Bash detail is program + subcommand only (cd and VAR= stripped)" "curl -H" "$(field "$L/tools.jsonl" 1 detail)"
if grep -q "$SECRET" "$L/tools.jsonl"; then bad "no command arguments or secrets in the journal"; else ok "no command arguments or secrets in the journal"; fi

j Write s1 "file_path=$P/src/a.py" "content=PASSWORD=$SECRET" @hook_event_name=PostToolUse
expect_rc "PostToolUse is journaled as post" post "$(field "$L/tools.jsonl" 2 event)"
expect_rc "file tools record the repo-relative path" "src/a.py" "$(field "$L/tools.jsonl" 2 detail)"
if grep -q "$SECRET" "$L/tools.jsonl"; then bad "file contents are never journaled"; else ok "file contents are never journaled"; fi

j Agent s1 "subagent_type=code-reviewer" "description=Review T-12" "prompt=Review T-12 and T-12 again, compare with T-3. Key $SECRET" @hook_event_name=PreToolUse
expect_rc "Agent spawn records subagent_type" code-reviewer "$(field "$L/tools.jsonl" 3 subagent_type)"
expect_rc "Agent spawn records the task from the description, not ids mentioned in the prompt" '["T-12"]' "$(field "$L/tools.jsonl" 3 task_ids)"
if grep -q "$SECRET" "$L/tools.jsonl"; then bad "prompts are never journaled"; else ok "prompts are never journaled"; fi
j Bash s1 "command=false" @hook_event_name=PostToolUseFailure
expect_rc "PostToolUseFailure is journaled as failure" failure "$(field "$L/tools.jsonl" 4 event)"

j Bash s1 "command=git push --force origin main" @hook_event_name=PermissionDenied "@denial_reason=blocked $SECRET"
expect_rc "PermissionDenied goes to perms.jsonl" PermissionDenied "$(field "$L/perms.jsonl" 1 event)"
if grep -q "$SECRET" "$L/perms.jsonl"; then bad "denial reasons are not stored"; else ok "denial reasons are not stored"; fi
j Bash s1 "command=make deploy" @hook_event_name=PermissionRequest
expect_rc "PermissionRequest goes to perms.jsonl" "make deploy" "$(field "$L/perms.jsonl" 2 detail)"

task_file "$P/docs/tasks/T-12.md" T-12 IN_PROGRESS bug full
echo T-12 > "$P/.teamwright/current-task"
out="$(hook_json "" s1 "@hook_event_name=Stop" "@last_assistant_message=Done.
Outcome: barrier" | bash "$J")"
expect_allow "Stop hook prints nothing (does not block the stop)" "$out"
expect_rc "Stop writes the outcome" barrier "$(field "$L/outcomes.jsonl" 1 outcome)"
expect_rc "outcome carries the active task" T-12 "$(field "$L/outcomes.jsonl" 1 current_task)"
expect_rc "outcome carries the task status" IN_PROGRESS "$(field "$L/outcomes.jsonl" 1 task_status)"
expect_rc "outcome counts the main agent's tool calls" 1 "$(field "$L/outcomes.jsonl" 1 tool_calls)"
hook_json "" s1 "@hook_event_name=SubagentStop" @agent_id=a1 @agent_type=developer "@last_assistant_message=no outcome line" | bash "$J"
expect_rc "SubagentStop without an outcome line records none" none "$(field "$L/outcomes.jsonl" 2 outcome)"
expect_rc "SubagentStop counts that subagent's calls" 1 "$(field "$L/outcomes.jsonl" 2 tool_calls)"

expect_rc "outcome_source: message" message "$(field "$L/outcomes.jsonl" 1 outcome_source)"

# runtime without last_assistant_message: the Outcome line is read from the transcript
TR="$TMP/transcript.jsonl"
{ echo '{"type":"user","message":{"role":"user","content":"go"}}'
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Outcome: idle (old turn)"}]}}'
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}'
  echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}'
  echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done this session: T-12 ANALYSIS->IN_PROGRESS\n**Outcome:** barrier"}]}}'
} > "$TR"
hook_json "" s1 "@hook_event_name=Stop" "@transcript_path=$TR" | bash "$J"
expect_rc "Stop without last_assistant_message reads the transcript" barrier "$(field "$L/outcomes.jsonl" 3 outcome)"
expect_rc "outcome_source: transcript" transcript "$(field "$L/outcomes.jsonl" 3 outcome_source)"
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will continue when it finishes."}]}}' >> "$TR"
hook_json "" s1 "@hook_event_name=Stop" "@transcript_path=$TR" | bash "$J"
expect_rc "final text without an Outcome line: none (older lines are not reused)" none "$(field "$L/outcomes.jsonl" 4 outcome)"
expect_rc "outcome_source: none" none "$(field "$L/outcomes.jsonl" 4 outcome_source)"
hook_json "" s1 "@hook_event_name=Stop" "@transcript_path=$TMP/no-such.jsonl" | bash "$J"
expect_rc "missing transcript: none, no crash" none "$(field "$L/outcomes.jsonl" 5 outcome)"

# SubagentStop without agent_type: taken from that agent's own tool calls
hook_json Read s1 "file_path=src/a.py" @hook_event_name=PreToolUse @agent_id=a7 @agent_type=problem-investigator | bash "$J"
hook_json "" s1 "@hook_event_name=SubagentStop" @agent_id=a7 | bash "$J"
expect_rc "SubagentStop without agent_type: filled from the journal" problem-investigator "$(field "$L/outcomes.jsonl" 6 agent_type)"

# task ids: description first, else only the first id of the prompt
j Agent s9 "subagent_type=developer" "description=Fix the parser" "prompt=Task T-7. Gate is red because of T-3 and T-5." @hook_event_name=PreToolUse
expect_rc "no id in the description: prompt ids are used (wider match, never a missed spawn)" '["T-7", "T-3", "T-5"]' "$(python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in open(sys.argv[1])][-1]["task_ids"]))' "$L/tools.jsonl")"
j Agent s9 "subagent_type=code-reviewer" "description=Review T-7 and T-8" "prompt=see T-3" @hook_event_name=PreToolUse
expect_rc "ids in the description are all kept" '["T-7", "T-8"]' "$(python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in open(sys.argv[1])][-1]["task_ids"]))' "$L/tools.jsonl")"

# Stop while a launched agent is still running: waiting, not none
last_out() { python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])][-1]; print(r["outcome"], r["outcome_source"])' "$L/outcomes.jsonl"; }
j Agent s8 "subagent_type=developer" "description=T-7" @hook_event_name=PostToolUse
hook_json "" s8 "@hook_event_name=Stop" "@last_assistant_message=I will continue when it finishes." | bash "$J"
expect_rc "Stop with a launched agent still running: waiting" "waiting open-agent" "$(last_out)"
hook_json "" s8 "@hook_event_name=SubagentStop" @agent_id=a9 | bash "$J"
hook_json "" s8 "@hook_event_name=Stop" "@last_assistant_message=still waiting" | bash "$J"
expect_rc "a runtime SubagentStop (no type, no calls) does not end the wait" "waiting open-agent" "$(last_out)"
hook_json "" s8 "@hook_event_name=SubagentStop" @agent_id=a7 @agent_type=Explore | bash "$J"
hook_json "" s8 "@hook_event_name=Stop" "@last_assistant_message=still waiting" | bash "$J"
expect_rc "a nested agent of another type finishing does not end the wait" "waiting open-agent" "$(last_out)"
hook_json "" s8 "@hook_event_name=SubagentStop" @agent_id=a8 @agent_type=developer | bash "$J"
hook_json "" s8 "@hook_event_name=Stop" "@last_assistant_message=done, no outcome line" | bash "$J"
expect_rc "agent finished, no Outcome line: none" "none none" "$(last_out)"
j Agent s8 "subagent_type=code-reviewer" "description=T-7" @hook_event_name=PostToolUse
hook_json "" s8 "@hook_event_name=Stop" "@last_assistant_message=Outcome: barrier" | bash "$J"
expect_rc "an explicit Outcome line wins over waiting" "barrier message" "$(last_out)"

out="$(printf '{bad' | bash "$J")"; expect_allow "garbage input is ignored" "$out"
chmod 000 "$L"; out="$(j Read s1 file_path=x @hook_event_name=PreToolUse)"; chmod 755 "$L"
expect_allow "unwritable log dir fails silently" "$out"
finish
