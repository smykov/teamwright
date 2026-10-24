#!/usr/bin/env bash
# release-check.sh — the version bump rule, checked before tagging a release.
#
# WHY. `/plugin update` compares the `version` in .claude-plugin/plugin.json with the
# installed one: a change shipped without a bump never reaches users who installed
# from a git marketplace ("already at latest version"). The rule:
#   1. Any change to what the plugin ships (skills/, scripts/, template/, providers/,
#      docs/process/, .claude-plugin/) bumps `version` in plugin.json — patch for
#      fixes, minor for new behaviour or changed defaults, major for breaking changes
#      to the config schema or the task record format.
#   2. marketplace.json carries the same version for the plugin entry.
#   3. CHANGELOG.md has a `## [X.Y.Z]` section for it.
#   4. The release is tagged `vX.Y.Z`; a later change to shipped paths without a new
#      version fails this check.
#
# CHANNELS. A release channel (marketplace `teamwright-<channel>`, e.g. teamwright-next on
# branch next) carries no version at all - the commit SHA is the version, so every pushed
# commit reaches `/plugin update`; nothing is tagged from it. The channel is read from the
# marketplace name (scripts/check-versions.py), not from the git branch: CI is detached.
set -u
cd "$(dirname "$0")/.." || exit 2
fail=0
err() { echo "release-check: $1" >&2; fail=1; }

channel="$(python3 scripts/check-versions.py --channel 2>/dev/null)"
if [ -n "$channel" ] && [ "$channel" != stable ]; then
  if python3 scripts/check-versions.py >&2; then
    echo "release-check: ok (channel $channel: no version, no release tag from this branch)"
    exit 0
  fi
  exit 1
fi

ver="$(python3 -c 'import json; print(json.load(open(".claude-plugin/plugin.json"))["version"])' 2>/dev/null)"
[ -n "$ver" ] || { err "no version in .claude-plugin/plugin.json"; exit 1; }
mver="$(python3 -c 'import json; print([p.get("version","") for p in json.load(open(".claude-plugin/marketplace.json"))["plugins"] if p["name"]=="teamwright"][0])' 2>/dev/null)"
[ "$mver" = "$ver" ] || err "marketplace.json version '$mver' differs from plugin.json '$ver'"
grep -q "^## \[$ver\]" CHANGELOG.md 2>/dev/null || err "CHANGELOG.md has no '## [$ver]' section"

last="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [ -z "$last" ]; then
  echo "release-check: no v* tag yet; version $ver will be the first release tag"
elif [ "$last" != "v$ver" ]; then
  echo "release-check: version $ver, last release $last - bumped"
else
  changed="$(git diff --name-only "$last" -- skills scripts template providers docs/process .claude-plugin | head -5)"
  if [ -n "$changed" ]; then
    err "shipped files changed since $last but version is still $ver; bump it (rule above). e.g.:"
    printf '  %s\n' "$changed" >&2
  else
    echo "release-check: version $ver = $last, no shipped changes since"
  fi
fi
[ "$fail" -eq 0 ] && echo "release-check: ok ($ver)"
exit "$fail"
