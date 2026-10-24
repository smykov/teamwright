#!/usr/bin/env bash
# Regression: the autonomous-run example in docs/usage.md (one stage per CI job). Not an
# end-to-end run on GitHub: the YAML parses, the router call in its "Ask the router" step
# runs against a real project and prints every output the other steps read, and the
# file it dispatches is the one the docs say it is saved as.
. "$(dirname "$0")/lib.sh"
echo "usage example (autonomous runs)"
OUT="$TMP/example"
msg="$(python3 "$KIT/tests/usage_example.py" extract "$KIT/docs/usage.md" "$OUT")"; rc=$?
expect_rc "the example parses and its structure holds${msg:+ ($msg)}" 0 "$rc"
msg="$(TW_YAML_LITE=1 python3 "$KIT/tests/usage_example.py" extract "$KIT/docs/usage.md" "$TMP/lite")"; rc=$?
expect_rc "the subset parser (no PyYAML, e.g. bash 3.2 CI) reads it too${msg:+ ($msg)}" 0 "$rc"
[ -f "$OUT/route.sh" ] || { bad "the route step's script was extracted"; finish; exit 1; }
fact() { python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))[sys.argv[2]]) if isinstance(json.load(open(sys.argv[1]))[sys.argv[2]], list) else json.load(open(sys.argv[1]))[sys.argv[2]])' "$OUT/facts.json" "$1"; }
echo "  (YAML read with: $(fact parser))"
expect_rc "the steps read run, prompt, model and reason from the route step" "model prompt reason run" "$(fact used)"

# the route step against a project with work: run=true and a stage command
P="$TMP/proj"; mkdir -p "$P/docs/tasks" "$P/.teamwright" && cd "$P" || exit 1
git init -q -b main .
printf 'version: 1\nmode: enforce\nareas:\n  - name: core\nprocess:\n  models:\n    analyze: sonnet\n' > .teamwright/config.yml
printf -- '---\nid: T-1\ntitle: one\ntype: feature\nstatus: ANALYSIS\npriority: P2\ndepends_on: []\n---\nbody\n' > docs/tasks/T-1.md
git add -A && git commit -qm init
route() {  # route -> the step's GITHUB_OUTPUT, run as the job runs it (bash -e)
  local o="$TMP/gh-output"; : > "$o"
  TEAMWRIGHT_KIT="$KIT" GITHUB_OUTPUT="$o" bash -e "$OUT/route.sh" || return $?
  cat "$o"
}
got="$(route)"; rc=$?
expect_rc "the route step runs (tw-next.py --json with the documented flags)" 0 "$rc"
out_of() { printf '%s\n' "$got" | sed -n "s/^$1=//p"; }
expect_rc "run=true when there is work" true "$(out_of run)"
expect_rc "prompt is the stage command from headless.prompt (no ids)" "/teamwright:analyze" "$(out_of prompt)"
expect_rc "model comes from headless.model (process.models)" sonnet "$(out_of model)"
case "$(out_of reason)" in "") bad "reason is printed";; *) ok "reason is printed";; esac
rm -f docs/tasks/T-1.md && git add -A && git commit -qm empty
got="$(route)"
expect_rc "nothing to do: run=false" false "$(out_of run)"
expect_rc "nothing to do: the model falls back to opus" opus "$(out_of model)"

# the CLI flags the claude step passes exist (only when the claude CLI is here)
if command -v claude >/dev/null 2>&1; then
  missing=""
  for f in $(fact claude_flags); do claude --help 2>/dev/null | grep -q -- "$f" || missing="$missing $f"; done
  expect_rc "claude accepts the flags the example passes ($(fact claude_flags))" "" "$missing"
else
  echo "  skip claude CLI not installed: flags of claude_args not checked"
fi
finish
