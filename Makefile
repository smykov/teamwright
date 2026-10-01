# teamwright kit tooling. Requires bash, git, python3; shellcheck/gitleaks optional locally.
SHELL := /usr/bin/env bash
HOOKS := template/scripts/hooks
SH_FILES := $(wildcard $(HOOKS)/*.sh) $(HOOKS)/pre-commit $(HOOKS)/commit-msg $(HOOKS)/pre-push \
            template/scripts/install-hooks.sh template/scripts/tw-run scripts/release-check.sh $(wildcard tests/*.sh) \
            examples/demo.sh
GITLEAKS_CONFIG := .gitleaks.toml
METRICS := template/scripts/metrics/teamwright-metrics

.PHONY: test lint scan check release-check demo

test:            ## run hook, installer and metrics regression tests (temp git repos), incl. the demo
	@bash tests/run.sh

demo:            ## one task through every gate in a throwaway repo, then metrics (examples/demo.sh)
	@bash examples/demo.sh

lint:            ## shellcheck + python syntax + JSON validity
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -S warning $(SH_FILES) && echo "shellcheck: ok"; \
	else echo "shellcheck: not installed, skipped"; fi
	@python3 -c "import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]" $(HOOKS)/_task.py $(HOOKS)/_hookio.py $(HOOKS)/_config.py $(METRICS) scripts/tw-install.py scripts/tw-next.py examples/make-cast.py && echo "python: ok"
	@python3 -m json.tool template/.claude/settings.json >/dev/null && echo "settings.json: ok"
	@python3 -m json.tool template/scripts/metrics/metrics.example.json >/dev/null && echo "metrics.example.json: ok"
	@for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json; do python3 -m json.tool $$f >/dev/null || exit 1; done; echo "plugin manifests: ok"
	@python3 -c "import json,re,sys; v=json.load(open('.claude-plugin/plugin.json'))['version']; m=[p.get('version') for p in json.load(open('.claude-plugin/marketplace.json'))['plugins'] if p['name']=='teamwright'][0]; c=open('CHANGELOG.md').read(); sys.exit(0 if m==v and re.search(r'^## \['+re.escape(v)+r'\]', c, re.M) else 'version: plugin.json %s, marketplace.json %s, CHANGELOG section %s' % (v, m, 'found' if re.search(r'^## \['+re.escape(v)+r'\]', c, re.M) else 'missing'))" && echo "version consistent (plugin.json, marketplace.json, CHANGELOG.md)"
	@python3 scripts/tw-install.py --project . --kit . plan --config template/.teamwright/config.example.yml >/dev/null && echo "config.example.yml: ok"
	@if command -v claude >/dev/null 2>&1; then claude plugin validate . >/dev/null && claude plugin validate .claude-plugin/plugin.json >/dev/null && echo "claude plugin validate: ok"; \
	else echo "claude CLI not installed: plugin validate skipped"; fi
	@for f in $(SH_FILES); do bash -n "$$f" || exit 1; done; echo "bash -n: ok"
	@! grep -n "\$$(cat <<" $(SH_FILES) || { echo "heredoc inside \$$(...) breaks bash 3.2 (macOS): read it into a variable first"; exit 1; }; echo "bash 3.2 heredoc check: ok"

scan:            ## secret scan of the kit itself (gitleaks, else built-in fallback)
	@if command -v gitleaks >/dev/null 2>&1; then \
	  gitleaks git --config $(GITLEAKS_CONFIG) --redact --no-banner . ; \
	else \
	  echo "gitleaks not installed: built-in fallback over working-tree files"; \
	  git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do \
	    git diff --no-index --unified=0 --no-color /dev/null "$$f" || true; \
	  done | bash $(HOOKS)/pre-commit --scan-stdin && echo "scan: clean"; \
	fi

release-check:   ## before tagging: version bumped vs the last v* tag, manifests and CHANGELOG agree
	@bash scripts/release-check.sh

check: lint test scan
