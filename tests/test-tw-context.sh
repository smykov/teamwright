#!/usr/bin/env bash
# Regression: scripts/tw-context.py - a configured context tool that does not index an
# area's language, or that the roles read around, is reported (pilot: Serena indexed only
# TypeScript while the main code was Rust, and nothing said so).
. "$(dirname "$0")/lib.sh"
echo "tw-context"
CTX="$KIT/scripts/tw-context.py"
q() { python3 "$CTX" --project . --json | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

p="$TMP/proj"; mkdir -p "$p/.teamwright/logs" "$p/.serena" "$p/core/src" "$p/ui/src"; cd "$p" || exit 1
git init -q -b main .
for i in 1 2 3 4 5 6; do echo "fn f$i() {}" > "core/src/m$i.rs"; done
for i in 1 2 3 4 5; do echo "export const x$i = 1" > "ui/src/m$i.ts"; done
cat > .teamwright/config.yml <<'YML'
version: 1
areas:
  - name: core
    source_dirs: [core/src]
    runner: docker
    image: "rust:1"
  - name: ui
    source_dirs: [ui/src]
tools:
  context: serena
YML
printf 'languages:\n- typescript\n' > .serena/project.yml
git add -A; git commit -qm init

expect_rc "indexed languages read from .serena/project.yml" "typescript" "$(q '",".join(d["indexed_languages"])')"
expect_rc "rust area not indexed" "rust" "$(q '",".join(d["areas"][0]["not_indexed"])')"
q '"\n".join(d["findings"])' | grep -q "rust not indexed by serena.*docker" \
  && ok "finding names the area, the language and the docker hint" || bad "finding names the area, the language and the docker hint"
expect_rc "ui area is covered" "" "$(q '",".join(d["areas"][1]["not_indexed"])')"

printf 'language_servers:\n- typescript\n- rust\n' > .serena/project.yml
expect_rc "newer language_servers key is read" "0" "$(q 'len([f for f in d["findings"] if "not indexed" in f])')"

# usage: 25 built-in reads of code, 2 serena calls -> below the share threshold
{ for i in $(seq 1 25); do printf '{"event":"pre","session_id":"s1","agent_type":"developer","tool":"Read","detail":"core/src/m1.rs"}\n'; done
  printf '{"event":"pre","session_id":"s1","agent_type":"developer","tool":"mcp__serena__find_symbol","detail":""}\n'
  printf '{"event":"pre","session_id":"s1","agent_type":"code-reviewer","tool":"mcp__serena__get_symbols_overview","detail":""}\n'
  printf '{"event":"pre","session_id":"s1","agent_type":"developer","tool":"Read","detail":"README.md"}\n'
} > .teamwright/logs/tools.jsonl
expect_rc "usage counts tool calls and code reads only" "2 25" "$(q '"%d %d" % (d["usage"]["tool"], d["usage"]["builtin"])')"
q '"\n".join(d["findings"])' | grep -q "only 7% of code reading went through serena.*developer" \
  && ok "low share is a finding naming the role" || bad "low share is a finding naming the role" "$(q '"|".join(d["findings"])')"

# run from a git worktree (#7): the hooks journal into the main checkout
git worktree add -q "$TMP/wt" -b wt 2>/dev/null
expect_rc "from a worktree, the main checkout's journal is read" "2 25" \
  "$(cd "$TMP/wt" && q '"%d %d" % (d["usage"]["tool"], d["usage"]["builtin"])')"

sedi 's/context: serena/context: builtin/' .teamwright/config.yml
expect_rc "builtin context: nothing to check" "0" "$(q 'len(d["findings"])')"
finish
