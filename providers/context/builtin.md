---
capability: context
provider: builtin
mcp: none
requires: []
---

# Built-in navigation — grep, glob, LSP

No MCP server: agents navigate with the runtime's own tools (Grep, Glob, Read) and, where the runtime has one configured, a language-server tool. Nothing to install; weakest at finding every caller, so the rules compensate.

## Install

Nothing to install. Optional: a code-intelligence (LSP) plugin for the project's language gives Claude Code go-to-definition and references — see the [Claude Code docs on code intelligence](https://code.claude.com/docs/en/plugins/code-intelligence).

## Rules for agents

- **Search by name, then by shape.** Grep the exact identifier (word boundaries, e.g. `\bname\b`), then its other forms: string keys, route paths, reflection/DI registrations, config names, generated code, tests. Glob to see a module's files before reading them.
- **Every path into a seam:** grep all callers of the function and of anything that wraps it; list them in your report with `file:line`. The reviewer repeats the search for every changed symbol.
- **Language server available** (an LSP tool in the runtime): prefer it for definitions and references, and use grep for what it does not parse.
- **An empty result is not proof of absence** — aliases, dynamic calls, other languages in the repo. Say the exact patterns and directories you searched.
- **Read narrowly:** the lines around a match, not whole large files.
