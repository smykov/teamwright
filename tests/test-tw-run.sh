#!/usr/bin/env bash
# Regression: scripts/tw-run runs an area command on the host or in the area's image.
# Docker is replaced by a fake that records its arguments; a real container run is
# attempted only when a local alpine image already exists (never pulled).
. "$(dirname "$0")/lib.sh"
echo "tw-run"
P="$TMP/proj"; mkdir -p "$P/.teamwright" "$P/scripts" "$P/app/sub"
cp -R "$HOOKS" "$P/scripts/hooks"
cp "$KIT/template/scripts/tw-run" "$P/scripts/tw-run"
cat > "$P/.teamwright/config.yml" <<'YML'
version: 1
areas:
  - name: core
  - name: app
    workdir: app
  - name: img
    runner: docker
    image: "example.invalid/toolchain:1.0"
    workdir: app
    cache: [".pub-cache", /opt/cache]
  - name: noimg
    runner: docker
  - name: odd
    runner: vm
YML
cd "$P" || exit 1
run() { bash scripts/tw-run "$@" 2>&1; }

# ---- host --------------------------------------------------------------------------
expect_rc "host: runs in the project root" "$P" "$(run core -- pwd)"
expect_rc "host: runs in workdir" "$P/app" "$(run app -- pwd)"
expect_rc "host: shell string with &&" "$P/app/sub" "$(run app -- 'cd sub && pwd')"
expect_rc "host: extra args appended to a shell string" "x y" "$(run app -- 'echo' x y)"
expect_rc "host: separate words with spaces kept" "a b|c" "$(run core -- printf '%s|' 'a b' c | sed 's/|$//')"
run core -- 'exit 7' >/dev/null; expect_rc "host: exit code is the command's" 7 "$?"
out="$(run nope -- true)"; rc=$?
expect_rc "unknown area exits 2" 2 "$rc"
printf '%s' "$out" | grep -q "no area 'nope'" && ok "unknown area named" || bad "unknown area named" "$out"
run odd -- true >/dev/null; expect_rc "unknown runner exits 2" 2 "$?"
run noimg -- true >/dev/null; expect_rc "docker without image exits 2" 2 "$?"
run core >/dev/null; expect_rc "no command exits 2" 2 "$?"
(cd app && bash ../scripts/tw-run core -- pwd > "$TMP/o") && expect_rc "root found from the script, not cwd" "$P" "$(cat "$TMP/o")"

# ---- docker (fake) -------------------------------------------------------------------
cat > "$TMP/fake-docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DOCKER_LOG"
exit "${FAKE_DOCKER_RC:-0}"
SH
chmod +x "$TMP/fake-docker"
export FAKE_DOCKER_LOG="$TMP/docker.args"
TW_DOCKER="$TMP/fake-docker" run img -- flutter test test/a_test.dart >/dev/null
expect_rc "docker: exit 0 passed through" 0 "$?"
A="$(tr '\n' ' ' < "$FAKE_DOCKER_LOG")"
want=("run --rm -u $(id -u):$(id -g)" "-v $P:/work" "-w /work/app" "-e HOME=/tw-home"
      "-v $P/.teamwright/cache/img/home:/tw-home" "-v $P/.teamwright/cache/img/_opt_cache:/opt/cache"
      "example.invalid/toolchain:1.0 sh -c flutter \"\$@\" sh test test/a_test.dart")
for w in "${want[@]}"; do
  case "$A" in *"$w"*) ok "docker args: $w" ;; *) bad "docker args: $w" "$A" ;; esac
done
[ -d "$P/.teamwright/cache/img/home/.pub-cache" ] && ok "relative cache lives in the persisted home" \
  || bad "relative cache lives in the persisted home"
FAKE_DOCKER_RC=5 TW_DOCKER="$TMP/fake-docker" run img -- 'make test' >/dev/null
expect_rc "docker: command exit code passed through" 5 "$?"
out="$(TW_DOCKER=no-such-docker-xyz run img -- true)"; rc=$?
expect_rc "docker missing: exit 127 (not runnable)" 127 "$rc"
printf '%s' "$out" | grep -q "not runnable" && ok "docker missing: says not runnable" || bad "docker missing: says not runnable" "$out"
out="$(TW_RUN_PRINT=1 TW_DOCKER=no-such-docker-xyz run img -- 'a && b')"
case "$out" in *"example.invalid/toolchain:1.0 sh -c"*) ok "TW_RUN_PRINT prints the command" ;; *) bad "TW_RUN_PRINT prints the command" "$out" ;; esac

# ---- real container, only when an alpine image is already local --------------------
img="$(docker image ls --format '{{.Repository}}:{{.Tag}}' alpine 2>/dev/null | head -n1)"
if [ -n "$img" ] && docker info >/dev/null 2>&1; then
  sedi "s|example.invalid/toolchain:1.0|$img|" .teamwright/config.yml
  out="$(run img -- 'pwd; id -u; touch made-in-container')"
  case "$out" in "/work/app"*"$(id -u)"*) ok "container: workdir and caller uid" ;; *) bad "container: workdir and caller uid" "$out" ;; esac
  [ -O app/made-in-container ] && ok "container: written file belongs to the caller" || bad "container: written file belongs to the caller"
else
  echo "  skip real container run (no local alpine image or no docker daemon)"
fi
finish
