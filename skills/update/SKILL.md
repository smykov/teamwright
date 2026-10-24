---
name: update
description: Update teamwright in this project in one step — the plugin (its marketplace, then the plugin, through the claude CLI) and the kit files the installer wrote here (hooks, roles, process docs, scripts), shown as a plan first and applied on the owner's yes, then committed. Use when a new teamwright version is out or /teamwright:status reports install drift.
argument-hint: "[--no-fetch] — skip the plugin update; plan from the installed copy"
disable-model-invocation: true
allowed-tools: Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" update *) Bash(git status *) Bash(git diff *) Bash(git add *) Bash(git commit *) Bash(git log *)
---

# /teamwright:update — the plugin and the project's kit, together

Arguments: `$ARGUMENTS`. A plugin update alone changes nothing in the project: the hooks, role files, process docs and scripts here are the kit the installer wrote. This command does both.

## 1. Plan

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" update $ARGUMENTS
```

It updates the marketplace and the plugin for this project's channel (`teamwright@teamwright`, or `teamwright@teamwright-next` when the project enables the experimental channel) with `claude plugin marketplace update` and `claude plugin update`, finds the copy Claude Code installed for this project, and runs the installer's **plan** from that copy — not from the one this session loaded. Show the owner, in one short table:

- the plugin version installed and the kit version in this project (`.teamwright/installed.json`);
- what would change (`update` lines), what is kept because it was edited here (`kept-local`) and every **conflict**;
- the notes (an MCP server with a different config, the gate mode).

No change and no conflict → say "up to date" and stop. A step that failed (`claude` CLI not found, an update error) → show it; `/plugin` updates by hand, then this command again with `--no-fetch`.

## 2. Apply — on the owner's "yes"

Uncommitted changes in the tree → ask to commit them first (or set them aside yourself, outside Claude Code: `git stash` is denied here): the kit's files and the owner's work must not mix in one commit.

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tw-install.py" update --no-fetch --apply
```

Conflicts are not overwritten: list each with its path; the owner merges by hand and records it with `tw-install.py apply --accept <path>` (the plan shows the command).

## 3. Commit

`git status` → the files the installer changed (and `.gitignore` when it added lines). Commit only those: `chore(process): teamwright <old kit> → <new kit>`.

## 4. Restart

Say: "Restart Claude Code to load the new commands and skills — the hooks and role files are already in effect." Then, after the restart, `/teamwright:status` shows no drift.

Report: `Updated: plugin <id> <old> → <new> · kit <old> → <new> · changed <n> · kept-local <n> · conflicts <paths or none> · commit <sha>`.
