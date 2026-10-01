---
name: reconfigure
description: Change the tool for one teamwright capability (spec, context, docs, ui_verify, api_verify) or update areas, commands and toolchain runners — updates .teamwright/config.yml through config.next.yml, re-renders only the tool blocks between the markers, installs the new provider's MCP server with consent.
argument-hint: "[capability] [provider]"
disable-model-invocation: true
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" inventory *) Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" plan *) Bash(git status *)
---

# /teamwright:reconfigure — swap a tool, keep the process

Arguments: `$ARGUMENTS` (e.g. `ui_verify patrol`; empty → ask).

Installer: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" <inventory|plan|apply> [--config FILE] [--dry-run] [--json]`. Adapters: `${CLAUDE_PLUGIN_ROOT}/providers/<capability>/<provider>.md`.

1. **Current state.** Read `.teamwright/config.yml` (missing → stop, suggest `/teamwright:adopt`). Show `tools:` and the areas' commands.
2. **Choose.** Capability and provider from the arguments, or ask: list the adapter files for that capability, the current one marked, already-installed ones first (`inventory --json` → `providers_detected`). Read the new adapter (front matter, `## Install`, `## Rules for agents`).
3. **Install, with consent.** Missing CLI → show the adapter's install commands and source link; run on "yes". New MCP server → it is added to `.mcp.json` by `apply`; say so and ask. API keys only through environment variables.
4. **Related config.** `ui_verify` changed → propose the new `e2e_ui_command` per area (verify it exists) and remind that new verify records use the new `tool:` value; old records stay as they are. `api_verify` → `api_test_command`. A runner change (`host` ↔ `docker`, another `image`) → prefer the image the CI uses; commands stay written without a wrapper. `spec` changed → existing specs stay where they are; `design_ref` of old tasks is not rewritten.
5. **Propose the config.** Agents cannot edit `.teamwright/config.yml` (state guard, `docs/process/gates.md`): copy it to `.teamwright/config.next.yml` with the Write tool, change only the keys that change, keep `mode` as it is (lowering `enforce` to `gate-first` is the owner's own step outside Claude Code), then `plan --config .teamwright/config.next.yml --json`. Expected: `tools` actions for every file with markers (`AGENTS.md`, role files), the `.mcp.json` merge. Report `kept-local` and `conflict` files: text outside the markers is never touched.
6. **Apply** on "yes": `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" apply --config .teamwright/config.next.yml` (validates, shows the diff, writes `.teamwright/config.yml` and deletes `config.next.yml`), then `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" check-commands` and report every changed command's result. The old provider's MCP server is **not removed** automatically: ask whether to delete its entry from `.mcp.json` and do it with Edit on "yes".
7. Show `git diff --stat`; commit only on "yes". Restart Claude Code to load MCP changes.

Report: `Reconfigured: <capability> <old> → <new> · files re-rendered: <n> · MCP: <added/kept/removed> · config keys changed: <…>`.
