#!/usr/bin/env bash
# Regression: scripts/check-versions.py (make lint) and scripts/release-check.sh, per
# release channel: stable (marketplace `teamwright`) keeps the bump rule, a channel
# (`teamwright-<name>`) must carry no version. Read from the marketplace name, not the
# branch: the checks run on a detached HEAD in CI.
. "$(dirname "$0")/lib.sh"
echo "release-check (channels)"
R="$TMP/kit"; mkdir -p "$R/.claude-plugin" "$R/scripts" "$R/skills/x" && cd "$R" || exit 1
git init -q -b main .
cp "$KIT/scripts/release-check.sh" "$KIT/scripts/check-versions.py" scripts/
manifests() {  # manifests MARKETPLACE_NAME VERSION_OR_EMPTY [ENTRY_VERSION]
  local v="${2:+  \"version\": \"$2\",
}" ev="${3-$2}"
  printf '{\n  "name": "teamwright",\n%s  "description": "d"\n}\n' "$v" > .claude-plugin/plugin.json
  printf '{\n  "name": "%s",\n  "owner": {"name": "o"},\n  "plugins": [{"name": "teamwright", "source": ".",%s "description": "d"}]\n}\n' \
    "$1" "${ev:+ \"version\": \"$ev\",}" > .claude-plugin/marketplace.json
}
printf '# Changelog\n\n## [0.12.0] - 2026-10-24\n\n- x\n' > CHANGELOG.md
echo a > skills/x/SKILL.md
lint() { python3 scripts/check-versions.py >/dev/null 2>&1; echo $?; }
rel() { bash scripts/release-check.sh >/dev/null 2>&1; echo $?; }

manifests teamwright 0.12.0
git add -A && git commit -qm r && git tag v0.12.0
expect_rc "stable: versions agree, changelog section -> lint ok" 0 "$(lint)"
expect_rc "stable: tagged, nothing changed -> release-check ok" 0 "$(rel)"
echo b > skills/x/SKILL.md && git commit -qam change
expect_rc "stable: shipped change without a bump -> release-check fails (rule kept)" 1 "$(rel)"
manifests teamwright 0.12.1
expect_rc "stable: bump without a changelog section -> lint fails" 1 "$(lint)"
printf '\n## [0.12.1] - 2026-10-25\n\n- y\n' >> CHANGELOG.md
expect_rc "stable: bumped with a changelog section -> release-check ok" 0 "$(rel)"
manifests teamwright 0.12.1 0.12.0
expect_rc "stable: marketplace entry version differs -> lint fails" 1 "$(lint)"
manifests teamwright ""
expect_rc "stable: no version -> lint fails" 1 "$(lint)"

manifests teamwright-next ""
expect_rc "channel next: no version anywhere -> lint ok" 0 "$(lint)"
expect_rc "channel next: release-check ok without a bump or tag" 0 "$(rel)"
expect_rc "channel name read from the marketplace" next "$(python3 scripts/check-versions.py --channel)"
git checkout -q --detach HEAD
expect_rc "channel next on a detached HEAD (CI): release-check ok" 0 "$(rel)"
manifests teamwright-next 0.12.1 ""
expect_rc "channel next: a version in plugin.json -> lint fails (would freeze updates)" 1 "$(lint)"
expect_rc "channel next: a version in plugin.json -> release-check fails" 1 "$(rel)"
manifests teamwright-next "" 0.12.1
expect_rc "channel next: a version in the marketplace entry -> lint fails" 1 "$(lint)"
manifests other ""
expect_rc "a marketplace name that is no channel -> lint fails" 1 "$(lint)"
finish
