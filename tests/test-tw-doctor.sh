#!/usr/bin/env bash
# Regression: scripts/tw-doctor.py (#31) - one check per requirement of the project and its
# autonomous contour, with a class and the fix; GitHub through gh; read-only.
. "$(dirname "$0")/lib.sh"
echo "tw-doctor"
D="$KIT/scripts/tw-doctor.py"
st() {  # st ID [ARGS...] -> the state of check ID ("" when absent)
  local id="$1"; shift
  python3 "$D" --project . --json "$@" | python3 -c "import json,sys; print(' '.join(c['state'] for c in json.load(sys.stdin)['checks'] if c['id']=='$id'))"
}
field() {  # field ID KEY [ARGS...]
  local id="$1" k="$2"; shift 2
  python3 "$D" --project . --json "$@" | python3 -c "import json,sys; print(' '.join(c['$k'] for c in json.load(sys.stdin)['checks'] if c['id']=='$id'))"
}

python3 "$D" --project "$TMP/nowhere" >/dev/null 2>&1; expect_rc "no such project: exit 2" 2 "$?"
mkdir -p "$TMP/bare" && cd "$TMP/bare" && git init -q -b main .
expect_rc "no config: teamwright is not installed" "missing" "$(st config)"

p="$TMP/proj"; mkdir -p "$p/.teamwright" "$p/.github/workflows" "$TMP/bin"; cd "$p" || exit 1
git init -q -b main .
git remote add origin https://github.com/acme/widget.git
printf 'version: 1\nmode: gate-first\nareas:\n  - name: app\n    path: app\n    runner: docker\n    image: "img:1"\nprocess:\n  models:\n    analyze: opus\n' > .teamwright/config.yml
printf '{"@kit": {"version": "0.16.2"}}\n' > .teamwright/installed.json
git add -A; git commit -qm init

# repo
expect_rc "an older kit than the plugin: update" "missing agent" "$(st kit-version) $(field kit-version class)"
expect_rc "git hooks off" "missing" "$(st git-hooks)"
git config core.hooksPath scripts/hooks
expect_rc "git hooks on" "ok" "$(st git-hooks)"
expect_rc "a setting left below its recommended value is an owner decision" "warn owner-decision" \
  "$(st setting:models.implement) $(field setting:models.implement class)"
expect_rc "a recommended value the config sets is not listed" "" "$(st setting:models.analyze)"
expect_rc "the manual steps after the project's kit, not those of its own version" "True False" \
  "$(python3 "$D" --project . --json | python3 -c "import json,sys; ids=[c['id'] for c in json.load(sys.stdin)['checks']]; print(any(i.startswith('manual:0.17.0:') for i in ids), any(i.startswith('manual:0.16.2:') for i in ids))")"
expect_rc "--since moves the start" "False" \
  "$(python3 "$D" --project . --json --since 0.17.0 | python3 -c "import json,sys; print(any(c['id'].startswith('manual:0.17.0:') for c in json.load(sys.stdin)['checks']))")"
expect_rc "a line that only says to run /teamwright:update is left out" "0" \
  "$(python3 "$D" --project . --json | python3 -c "import json,sys; print(sum(c['fix'].startswith('\`/teamwright:update\`') for c in json.load(sys.stdin)['checks']))")"
printf '#!/bin/sh\n[ "$1 $2 $3" = "image inspect img:1" ] && exit "${DOCKER_RC:-1}"\nexit 9\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
export TW_DOCKER="$TMP/bin/docker"
expect_rc "a docker area's image missing on this host" "missing" "$(st docker-image:img:1)"
expect_rc "a docker area's image present" "ok" "$(DOCKER_RC=0 st docker-image:img:1)"

# contour: no workflow
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view") echo '{"nameWithOwner":"acme/widget","defaultBranchRef":{"name":"main"}}' ;;
  "secret list") echo "${GH_SECRETS:-[]}" ;;
  "label list") echo '[{"name":"teamwright"},{"name":"bug"}]' ;;
  "api repos/acme/widget/branches/main/protection")
    case "${GH_PROT:-404}" in
      200) echo '{}' ;;
      403) echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >&2; exit 1 ;;
      *) echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
    esac ;;
  "api repos/acme/widget/actions/runners") echo "{\"runners\":[{\"name\":\"box\",\"status\":\"${GH_RUNNER:-online}\",\"labels\":[{\"name\":\"self-hosted\"},{\"name\":\"linux\"}]}]}" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$TMP/bin/gh"
export TW_GH="$TMP/bin/gh" GH_LOG="$TMP/gh.log"; : > "$GH_LOG"
expect_rc "no contour workflow: a decision, not a fault" "missing owner-decision" "$(st contour-workflow) $(field contour-workflow class)"
expect_rc "and GitHub is not asked" "0" "$(wc -l < "$GH_LOG" | tr -d ' ')"
expect_rc "--scope contour asks GitHub anyway" "missing" "$(st model-secret --scope contour)"

# contour: the sketch from docs/usage.md
python3 - "$KIT/docs/usage.md" > .github/workflows/teamwright-stage.yml <<'PY'
import re, sys
print(re.search(r"```yaml\n(name: teamwright stage.*?)```", open(sys.argv[1]).read(), re.S).group(1))
PY
expect_rc "the sketch: the kit, the hooks step and allowed_bots are there" "ok ok ok" \
  "$(st workflow-kit) $(st workflow-hooks) $(st workflow-allowed-bots)"
expect_rc "the sketch alone dispatches no CI on the chain's branch" "missing" "$(st workflow-ci-dispatch)"
sedi 's/^          gh workflow run teamwright-stage.yml$/          gh workflow run teamwright-stage.yml; gh workflow run ci.yml --ref "task\/T-1"/' .github/workflows/teamwright-stage.yml
expect_rc "a CI dispatch on the task branch" "ok" "$(st workflow-ci-dispatch)"
sedi 's/allowed_bots: .*$/prompt_extra: x/' .github/workflows/teamwright-stage.yml
expect_rc "claude-code-action without allowed_bots" "missing" "$(st workflow-allowed-bots)"
sedi 's/      TEAMWRIGHT_KIT: \/opt\/teamwright/      TEAMWRIGHT_KIT: \/opt\/teamwright\n      CLAUDE_CODE_SUBPROCESS_ENV_SCRUB: "1"/' .github/workflows/teamwright-stage.yml
expect_rc "the env scrub with a docker area: a conflict" "missing" "$(st workflow-scrub)"

# contour: GitHub
expect_rc "the model key the workflow names is not set" "missing" "$(st model-secret)"
expect_rc "set" "ok" "$(GH_SECRETS='[{"name":"ANTHROPIC_API_KEY"}]' st model-secret)"
expect_rc "labels: teamwright is there" "ok" "$(st labels)"
expect_rc "no branch protection: TM-16" "missing" "$(st branch-protection)"
expect_rc "protection not on this plan: a decision, TM-16 stays open" "warn owner-decision" \
  "$(GH_PROT=403 st branch-protection) $(GH_PROT=403 field branch-protection class)"
expect_rc "protected" "ok" "$(GH_PROT=200 st branch-protection)"
expect_rc "an online runner with the workflow's labels" "ok" "$(st runner-online)"
expect_rc "an offline runner" "missing" "$(GH_RUNNER=offline st runner-online)"
expect_rc "no other workflow on the contour's runner" "ok" "$(st runner-shared)"
printf 'on: push\njobs:\n  deploy:\n    runs-on: [self-hosted, linux]\n    steps:\n      - run: ./deploy\n        env: { KEY: "${{ secrets.DEPLOY_KEY }}" }\n' > .github/workflows/deploy.yml
expect_rc "a deploy workflow on the same runner, with its secret named" "warn .github/workflows/deploy.yml (secrets: DEPLOY_KEY)" \
  "$(st runner-shared) $(field runner-shared evidence)"
printf -- '- run: gh issue edit 1 --add-label tw:stop\n' >> .github/workflows/teamwright-stage.yml
expect_rc "a tw: label the workflow sets and nobody created" "missing" "$(st labels)"
expect_rc "the fix creates it" "gh label create tw:stop" "$(field labels fix)"
expect_rc "gh missing: unknown, not ok" "unknown" "$(TW_GH="$TMP/bin/no-such-gh" st github)"

# runner
expect_rc "the runner without TEAMWRIGHT_KIT" "missing" "$(env -u TEAMWRIGHT_KIT python3 "$D" --project . --json --scope runner | python3 -c "import json,sys; print([c['state'] for c in json.load(sys.stdin)['checks'] if c['id']=='runner-kit'][0])")"
expect_rc "with it" "ok" "$(TEAMWRIGHT_KIT="$KIT" st runner-kit --scope runner)"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/gitleaks"; chmod +x "$TMP/bin/gitleaks"
expect_rc "gitleaks on this machine" "ok" "$(PATH="$TMP/bin:$PATH" st gitleaks --scope runner)"
expect_rc "the installer runs the same doctor" "ok" \
  "$(TEAMWRIGHT_KIT="$KIT" python3 "$KIT/scripts/tw-install.py" doctor --project . --json --scope runner | python3 -c "import json,sys; print([c['state'] for c in json.load(sys.stdin)['checks'] if c['id']=='runner-kit'][0])")"

before="$(git status --porcelain)"
python3 "$D" --project . | grep -q "^doctor: [0-9]* check(s)" && ok "human output" || bad "human output"
expect_rc "read-only: the tree is unchanged" "$before" "$(git status --porcelain)"
cd "$KIT" || exit 1

finish
