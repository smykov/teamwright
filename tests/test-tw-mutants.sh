#!/usr/bin/env bash
# Regression: scripts/tw-mutants re-runs a task's mutant catalog on a throwaway copy in one
# tw-run start; only a survivor that breaks a named guarantee fails the run.
. "$(dirname "$0")/lib.sh"
echo "tw-mutants"
P="$TMP/proj"; mkdir -p "$P/.teamwright" "$P/scripts" "$P/app" "$P/docs/tasks/T-1.mutants"
cp -R "$HOOKS" "$P/scripts/hooks"
cp "$KIT/template/scripts/tw-run" "$KIT/template/scripts/tw-mutants" "$P/scripts/"
# the runner counts its starts in a file outside the repository
cat > "$P/.teamwright/config.yml" <<YML
version: 1
areas:
  - name: app
    workdir: app
  - name: box
    workdir: app
    runner: docker
    image: example/test:1
YML
# a fake docker: logs each start and the mounted root, then runs the command there
cat > "$TMP/docker" <<SH
#!/bin/sh
src=""; wd=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -v) case "\$2" in *:/work) src="\${2%:/work}" ;; esac; shift 2 ;;
    -w) wd="\$2"; shift 2 ;;
    -u|-e) shift 2 ;;
    run|--rm|-it) shift ;;
    *) shift; break ;;
  esac
done
echo "\$src" >> "$TMP/docker.starts"
cd "\$src\${wd#/work}" && exec "\$@"
SH
chmod +x "$TMP/docker"
cat > "$P/app/check.sh" <<'SH'
#!/bin/sh
# guarantee AC-1: an empty name is rejected; AC-2: a name is trimmed
. ./lib.sh
[ "$(valid "")" = no ] || { echo "AC-1 broken"; exit 1; }
[ "$(trim "  a ")" = a ] || { echo "AC-2 broken"; exit 1; }
SH
cat > "$P/app/lib.sh" <<'SH'
valid() { if [ -z "$1" ]; then echo no; else echo yes; fi; }
trim() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }
log_it() { echo "logged"; }
SH
C="$P/docs/tasks/T-1.mutants"
printf '# runs only the task tests\necho start >> %s/starts; sh check.sh\n' "$TMP" > "$C/test-command"
cat > "$C/01-accept-empty.mutant" <<'M'
guarantee: AC-1: an empty name is rejected
file: app/lib.sh
added_by: test-writer
--- old
if [ -z "$1" ]; then echo no
--- new
if false; then echo no
--- end
M
cat > "$C/02-no-trim.mutant" <<'M'
guarantee: AC-2: a name is trimmed
file: app/lib.sh
added_by: task-validator round 1
--- old
trim() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }
--- new
trim() { printf '%s' "$1"; }
--- end
M
cat > "$C/03-log-text.mutant" <<'M'
guarantee: -
file: app/lib.sh
added_by: task-validator round 1
--- old
echo "logged"
--- new
echo "LOGGED"
--- end
M
cd "$P" || exit 1
printf '.teamwright/logs/\n' > .gitignore
git init -q -b main . && git add -A && git commit -qm init
W="$(mktemp -d)"; git worktree add -q --detach "$W/tree" HEAD
mut() { bash scripts/tw-mutants "$@" 2>&1; }
starts() { if [ -f "$TMP/starts" ]; then wc -l < "$TMP/starts" | tr -d ' '; else echo 0; fi; }

out="$(mut app T-1 --tree "$W/tree" --check)"; rc=$?
expect_rc "--check: a valid catalog exits 0" 0 "$rc"
expect_rc "--check runs nothing" 0 "$(starts)"

out="$(mut app T-1 --tree "$W/tree")"; rc=$?
expect_rc "all guarantee mutants killed, a follow-up survives: exit 0" 0 "$rc"
printf '%s' "$out" | grep -q "^killed      01-accept-empty" && ok "AC-1 mutant killed" || bad "AC-1 mutant killed" "$out"
printf '%s' "$out" | grep -q "^survived, follow-up (no guarantee)  03-log-text" && ok "a survivor without a guarantee is a follow-up" || bad "a survivor without a guarantee is a follow-up" "$out"
printf '%s' "$out" | grep -q "^2 killed, 0 survived breaking a guarantee, 1 follow-ups, 0 equivalent" && ok "summary line" || bad "summary line" "$out"
expect_rc "one test command: baseline + 3 mutants" 4 "$(starts)"
grep -q 'if \[ -z "$1" \]' "$W/tree/app/lib.sh" && ok "the copy is restored after each mutant" || bad "the copy is restored after each mutant"
[ -z "$(git status --porcelain)" ] && ok "the working tree is untouched" || bad "the working tree is untouched" "$(git status --porcelain)"
rep="$(printf '%s' "$out" | sed -n 's/^report: //p')"
case "$rep" in "$P"/.teamwright/logs/mutants/T-1-*.txt) [ -f "$rep" ] && ok "report kept under .teamwright/logs/mutants" || bad "report file exists" "$rep" ;;
  *) bad "report kept under .teamwright/logs/mutants" "$rep" ;; esac

# runner: docker - one container start for the whole catalog, and it mounts the copy
out="$(TW_DOCKER="$TMP/docker" mut box T-1 --tree "$W/tree")"; rc=$?
expect_rc "docker area: exit 0" 0 "$rc"
expect_rc "docker area: one container start for baseline + 3 mutants" 1 "$(wc -l < "$TMP/docker.starts" | tr -d ' ')"
expect_rc "docker area: the container mounts the copy, not the working tree" "$(cd "$W/tree" && pwd -P)" "$(cat "$TMP/docker.starts")"

# weaken the AC-2 test in the copy: its mutant survives and names the guarantee
printf '. ./lib.sh\n[ "$(valid "")" = no ] || exit 1\n' > "$W/tree/app/check.sh"
out="$(mut app T-1 --tree "$W/tree")"; rc=$?
expect_rc "a survivor that breaks a guarantee: exit 1" 1 "$rc"
printf '%s' "$out" | grep -q "^SURVIVED    02-no-trim  app/lib.sh  breaks: AC-2: a name is trimmed" && ok "the survivor names the guarantee" || bad "the survivor names the guarantee" "$out"

out="$(mut app T-1 --tree "$W/tree" --only 01-accept-empty)"; rc=$?
expect_rc "--only runs the named mutant" 0 "$rc"
printf '%s' "$out" | grep -q "^1 killed, 0 survived" && ok "--only: one mutant" || bad "--only: one mutant" "$out"

printf 'equivalent: the log text is not part of any contract\n' > "$TMP/eq"
{ head -3 "$C/03-log-text.mutant"; cat "$TMP/eq"; tail -n +4 "$C/03-log-text.mutant"; } > "$TMP/m" && mv "$TMP/m" "$C/03-log-text.mutant"
out="$(mut app T-1 --tree "$W/tree" --only 03-log-text)"
printf '%s' "$out" | grep -q "^equivalent  03-log-text" && ok "an equivalent mutant is reported, not run" || bad "an equivalent mutant is reported, not run" "$out"

# baseline red: every mutant would look killed
printf 'exit 1\n' > "$W/tree/app/check.sh"
out="$(mut app T-1 --tree "$W/tree")"; rc=$?
expect_rc "baseline red: exit 3" 3 "$rc"
printf '%s' "$out" | grep -q "^BASELINE RED" && ok "baseline red is named" || bad "baseline red is named" "$out"
git -C "$W/tree" checkout -q -- app/check.sh

# a stale entry: the old text no longer matches exactly once
cp "$C/02-no-trim.mutant" "$TMP/keep"
sedi 's/^trim() { printf .%s. "\$1" | sed/trim() { printf "%s" "$1" | sed/' "$C/02-no-trim.mutant"
out="$(mut app T-1 --tree "$W/tree" --check)"; rc=$?
expect_rc "old text not found: exit 2" 2 "$rc"
printf '%s' "$out" | grep -q "02-no-trim: old text found 0 times in app/lib.sh" && ok "stale entry is named" || bad "stale entry is named" "$out"
cp "$TMP/keep" "$C/02-no-trim.mutant"
printf 'guarantee: AC-1\nfile: app/lib.sh\nseverity: high\n--- old\nx\n--- new\ny\n--- end\n' > "$C/04-bad.mutant"
out="$(mut app T-1 --tree "$W/tree" --check)"; expect_rc "unknown field: exit 2" 2 "$?"
printf '%s' "$out" | grep -q "unknown line 'severity: high'" && ok "unknown field is named" || bad "unknown field is named" "$out"
printf 'guarantee: AC-1\nfile: app/lib.sh\n--- old\nvalid\n--- new\nvalid2\n' > "$C/04-bad.mutant"
mut app T-1 --tree "$W/tree" --check >/dev/null; expect_rc "missing --- end: exit 2" 2 "$?"
rm "$C/04-bad.mutant"

mut app T-1 --tree "$P" >/dev/null; expect_rc "the working tree is refused as --tree" 2 "$?"
mut app T-1 >/dev/null; expect_rc "no --tree: exit 2" 2 "$?"
mut app T-9 --tree "$W/tree" >/dev/null; expect_rc "no catalog: exit 2" 2 "$?"
mut nope T-1 --tree "$W/tree" --check >/dev/null; expect_rc "unknown area: exit 2" 2 "$?"
git worktree remove --force "$W/tree"
finish
