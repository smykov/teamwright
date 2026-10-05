---
capability: context
provider: serena
mcp:
  name: serena
  config: {"command": "serena", "args": ["start-mcp-server", "--context", "claude-code", "--project-from-cwd"]}
  add: "claude mcp add --scope project serena -- serena start-mcp-server --context claude-code --project-from-cwd"
detect:
  files: [.serena, .serena/project.yml]
  commands: [serena]
requires: [uv, serena]
---

# Serena — symbol-aware navigation (MCP)

[Serena](https://github.com/oraios/serena) exposes language-server symbol tools over MCP: definitions, references, file overviews. Agents use it to gather context before analysis and review instead of text search.

## Install

Sources (checked 2026-09-30): [README — Quick Start](https://github.com/oraios/serena#quick-start), [Claude Code client setup](https://oraios.github.io/serena/02-usage/030_clients.html), [project workflow](https://oraios.github.io/serena/02-usage/040_workflow.html), [language support](https://oraios.github.io/serena/01-about/020_programming-languages.html).

Prerequisite: [uv](https://docs.astral.sh/uv/getting-started/installation/). Some languages need extra language-server dependencies (see language support).

```bash
uv tool install -p 3.13 serena-agent
serena init
# in the repository root:
serena project create
serena project index
```

MCP server for this project (the installer merges it into `.mcp.json`; equivalent CLI below):

```bash
claude mcp add --scope project serena -- serena start-mcp-server --context claude-code --project-from-cwd
```

**Documents too.** Add `markdown` to `languages` in `.serena/project.yml` (Serena runs the Marksman language server for it), then `serena project index`: headings become symbols, so a role reads one section of a spec instead of the whole file. Requirement ids in tables are not symbols — for those, `scripts/tw-req <ID>`.

`.serena/project.yml` is meant to be committed; `.serena/project.local.yml` is ignored by git. Serena's docs note that Claude Code may prefer its built-in tools; if agents ignore Serena, see the system-prompt override in the client setup page.

## Rules for agents

- **Before reading files to understand code, ask Serena.** `get_symbols_overview` for a file's structure; `find_symbol` for a definition (pass `relative_path` to scope it, `include_body: true` only for the symbol you need); `find_referencing_symbols` for every caller of a seam; `find_implementations` / `find_declaration` for interfaces.
- **Who uses it for what:** investigator — every path that handles the concern (hypothesis "a second path"); developer — callers of the seam before changing it; test-writer — the seam's public surface; reviewer — call sites and sibling paths of every changed symbol.
- **Documents** (`docs/`, specs): `get_symbols_overview` on the file lists its headings; read only the section you need (`find_symbol` with the heading name, or the line range it reports). A requirement id: `scripts/tw-req <ID>`.
- **Text search** (`search_for_pattern`, or grep) is for strings, config keys, SQL, templates and files the language server does not parse; use it too when a symbol tool returns nothing or times out.
- **An empty result is not proof of absence** — an unindexed file, an unsupported language or a dynamic call also return nothing. Say which tool and scope you used.
- **Stale index** (results miss code you can see): tell the orchestrator to run `serena project index`; meanwhile fall back to grep and say so.
- **Edit with the normal Edit/Write tools**, not Serena's editing tools (`replace_symbol_body`, `insert_*`, `rename_symbol`): the teamwright gates see only Edit/Write. Do not write Serena memories for process facts — those live in `docs/`.
- **Serena not connected** (no `mcp__serena__*` tools): use grep and file reads, and say so in your report.
