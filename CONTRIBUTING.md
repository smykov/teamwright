# Contributing to teamwright

Thanks for helping. Reports of gates that block the wrong thing, or let the wrong thing through, are as valuable as code: open an issue with the hook input or the steps to reproduce.

## Setup

You need `bash` (3.2 or later), `git`, `python3` (standard library only) and `make`. `shellcheck` and `gitleaks` are optional locally and run in CI; the `claude` CLI, when present, adds `claude plugin validate` to `make lint`.

```bash
git clone https://github.com/smykov/teamwright.git
cd teamwright
make check            # lint + tests + secret scan
```

| Command | What it runs |
|---|---|
| `make test` | regression tests in throwaway git repositories (`tests/test-*.sh`), including the demo |
| `make lint` | shellcheck, `bash -n`, Python syntax, Markdown links and anchors (`scripts/check-links.py`), JSON validity, plugin manifests, version consistency, a bash 3.2 check |
| `make scan` | secret scan of the repository (gitleaks with `.gitleaks.toml`, else the built-in scanner) |
| `make demo` | `examples/demo.sh`: one task through every gate |
| `make release-check` | before tagging: the version was bumped since the last `v*` tag and the manifests and changelog agree |

Run `make test`, `make lint` and `make scan` before every commit. CI runs lint and the secret scan on Linux, the tests on Linux and macOS, and the tests again under bash 3.2 (the macOS default) in a container:

```bash
docker run --rm -v "$PWD":/src:ro bash:3.2 bash -c 'apk add -q git python3 make coreutils >/dev/null &&
  cp -r /src /w && cd /w && git config --global user.email ci@example.invalid &&
  git config --global user.name ci && git config --global init.defaultBranch main && bash tests/run.sh'
```

## Repository layout

- `skills/` — plugin commands: `/teamwright:adopt`, `init`, `requirements`, `flow`, `status`, `reconfigure`.
- `template/` — what gets installed into a project: `AGENTS.md`, role agents, hooks, docs templates, metrics CLI.
- `docs/process/` — the process reference; copied into projects on install (except `plugin.md`) and linked from the role files.
- `providers/<capability>/<provider>.md` — tool adapters rendered into `AGENTS.md` and the role files.
- `scripts/` — installer (`tw-install.py`), router (`tw-next.py`), progress report (`tw-progress.py`), context-tool check (`tw-context.py`), process data (`tw-process.py`), parallel worktrees (`tw-parallel.py`), release check.
- `tests/` — regression tests; `tests/lib.sh` has the helpers (`hook_json`, `expect_deny`, `task_file`, `new_repo`).
- `examples/` — the offline demo and its recorder.
- `docs/design-decisions.md` — why the kit is shaped the way it is; `docs/usage.md` — user guide.

`CLAUDE.md` at the root is the same guidance for agents working on the kit.

## Rules

- **A change to a hook, the installer or the router comes with a test that fails without it.** Gate tests send hook JSON (`hook_json` in `tests/lib.sh`) and assert the decision and a word of the reason.
- **Everything here reads as published.** No hosts, IP addresses, absolute paths, names of real projects, clients or people, and no secrets. Examples are generic. Synthetic secrets in tests carry the `teamwright:allow-secret` marker or are allowlisted in `.gitleaks.toml`.
- **User-facing files are in English.**
- **The process stays fixed, tools stay pluggable.** No hook may depend on a specific tool: gates read task files, records and journals.
- **`template/docs/failures.md` ships empty.** Incidents belong to the project that has them.
- **Metrics come from git and logs**, never from an agent's self-report. A missing source prints `no data`, not `0`.
- **Hooks fail open on internal errors** and stay silent on allow; a block always names its exit.
- **bash 3.2 compatible**: no associative arrays, `mapfile`, `${var,,}`, or a heredoc inside `$(...)` (read it into a variable with `IFS= read -r -d '' var <<'EOF' || true`).

## Versions and the changelog

`/plugin update` compares the `version` in `.claude-plugin/plugin.json`, so a change users do not get a version for never reaches them.

- Any change to what the plugin ships (`skills/`, `scripts/`, `template/`, `providers/`, `docs/process/`) bumps `version` in `.claude-plugin/plugin.json` **and** `.claude-plugin/marketplace.json`, and gets an entry in a matching `## [x.y.z] - YYYY-MM-DD` section of `CHANGELOG.md`.
- Other changes (README, `docs/usage.md`, `examples/`, tests, CI) go under `## [Unreleased]`, or into the open version's section.
- Semantic versioning; while in 0.x a minor version may change behaviour. `make lint` checks that the three versions agree; `make release-check` checks the bump against the last tag.

## Adding a tool adapter

A provider is one Markdown file, `providers/<capability>/<provider>.md`; capabilities are `spec`, `context`, `docs`, `ui_verify`, `api_verify`.

1. Copy the closest existing adapter. Front matter: `capability`, `provider`, `requires` (binaries), `mcp` (`none`, or `name`, a one-line JSON `config` and an optional `add` line), `detect` (`files`, `commands`) for `inventory`; for `ui_verify` also `verify_tool_value`, the `tool:` value its verify records carry.
2. Sections: `## Install` with links to the tool's official docs and the date you checked them; `## When it fits` (UI runners); `## Rules for agents` — injected verbatim into `AGENTS.md` and the role files: when to use the tool, which of its commands, what to do when it is missing, what an empty result means.
3. Add it to the capability table in `docs/process/tools.md`, the Tools table in `README.md` and the comment in `template/.teamwright/config.example.yml`.
4. Check it renders: `python3 scripts/tw-install.py --kit . plan --config <a config that selects it> --project <a scratch repo>`. Installer tests use fake adapters in `tests/fixtures/providers/`; add a test when the adapter needs installer behaviour that is not covered.
5. Bump the version and add a changelog entry (adapters ship with the plugin).

## Plugin packaging facts

`claude plugin validate .` (marketplace) and `claude plugin validate .claude-plugin/plugin.json` (plugin) both run in `make lint` when the `claude` CLI is present. The plugin check prints one expected warning: the root `CLAUDE.md` is not loaded as plugin context; it is for developing the kit.

### Facts from the Claude Code docs this layout relies on

Checked on 2026-09-30 against code.claude.com/docs/en/plugins (create-marketplace, marketplace-reference, manifest-reference) and hooks; verified with `claude plugin validate` on Claude Code 2.1.285.

- A marketplace is a directory with `.claude-plugin/marketplace.json`; required fields are `name`, `owner` (with `owner.name`) and `plugins`. Each entry needs `name` and `source`. A missing `description` is a validation warning.
- A relative `source` resolves from the marketplace root (the directory that contains `.claude-plugin/`), must start with `./`, and `"."` on its own means the root itself. A path containing `..` fails validation.
- The plugin manifest lives at `.claude-plugin/plugin.json`; only `name` is required (kebab-case, no spaces, `@`, `:` or path separators). Missing `version`, `description` or `author` are warnings. Setting `version` keeps users on that version until it changes.
- Entry `name` and manifest `name` must match: the install id is `<entry-name>@<marketplace>`, and components are namespaced under the manifest name (`/teamwright:adopt`).
- Default component locations at the plugin root: `skills/<name>/SKILL.md` (preferred for new plugins), `commands/*.md`, `agents/*.md`, `hooks/hooks.json`, `.mcp.json`. Other files such as `scripts/` are allowed. Setting `commands` or `agents` in the manifest replaces the default scan; `skills` adds to it — so the manifest declares no component keys and relies on the defaults.
- `${CLAUDE_PLUGIN_ROOT}` is the absolute path of the installed plugin and is substituted in skill, command and agent Markdown bodies; it is not in the environment of the Bash tool, so commands write `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" ...` in their body. Do not write state there: it changes on update.
- A `CLAUDE.md` at the plugin root is not loaded as context (`claude plugin validate` warns).
- Marketplace names such as `claude-code-plugins`, `anthropic-*` variants, `github`, `npm` are reserved; `teamwright` is not.
- PreToolUse hook output: `hookSpecificOutput.permissionDecision` is `allow | deny | ask | defer`; JSON **without** `permissionDecision` leaves the call to the normal permission flow, while top-level `systemMessage` (shown to the user) and `hookSpecificOutput.additionalContext` (given to the model) still apply. Gate-first mode uses exactly this: a warning without a decision.

## Feedback from projects

Projects that run teamwright send improvements back with `/teamwright:feedback`: an issue through the forms (label `from-project`) for an observation, a pull request from a fork for a tested change to the kit. Such reports carry numbers from `/teamwright:improve` and no project details. Triage them like any issue; a change they lead to cites the issue in the CHANGELOG.

## Pull requests

Keep a pull request to one change. Fill in the template: the checks you ran, the changelog entry, and the version bump when shipped files changed. Report security issues privately, not in a pull request: [SECURITY.md](SECURITY.md).
