---
capability: context
provider: codegraph
mcp:
  name: CodeGraphContext
  config: {"command": "codegraphcontext", "args": ["mcp", "start"]}
  add: "claude mcp add --scope project CodeGraphContext -- codegraphcontext mcp start"
detect:
  files: [.cgcignore]
  commands: [codegraphcontext, cgc]
requires: [python3, codegraphcontext]
---

# CodeGraphContext — code graph (MCP)

[CodeGraphContext](https://github.com/CodeGraphContext/CodeGraphContext) indexes the repository into a graph of files, symbols, calls, imports and inheritance, and answers relationship queries over MCP. Strong for call chains and impact across many files; needs an indexing step.

## Install

Sources (checked 2026-09-30): [README — Installation & Quick Start](https://github.com/CodeGraphContext/CodeGraphContext#-installation--quick-start), [MCP client configuration](https://github.com/CodeGraphContext/CodeGraphContext#mcp-client-configuration). Python 3.10–3.14; an embedded graph database is used by default.

```bash
pip install codegraphcontext      # or pipx install codegraphcontext
codegraphcontext doctor
# in the repository root:
codegraphcontext index .
codegraphcontext list
```

MCP server for this project (the installer merges it into `.mcp.json`; `codegraphcontext mcp setup` is the tool's own wizard and edits client settings itself — prefer the project-scoped entry):

```bash
claude mcp add --scope project CodeGraphContext -- codegraphcontext mcp start
```

Add a `.cgcignore` (gitignore syntax) for build output and dependencies.

## Rules for agents

- **Locate first, then relate.** `find_code` to locate a symbol or concept; then `analyze_code_relationships` with `query_type`: `find_callers` / `find_all_callers` (every path into a seam), `find_callees`, `call_chain` (entry point → defect), `find_importers`, `class_hierarchy`, `overrides`, `who_modifies`, `module_deps`.
- **Who uses it for what:** investigator — `call_chain` and `find_all_callers` for the "second path" hypothesis; developer — callers of the seam before changing it; reviewer — callers and siblings of every changed function; `/arch-review` — `module_deps` and hotspot complexity (`find_most_complex_functions`) next to the metrics.
- **The graph is a snapshot.** Code changed since the last index is invisible. Before relying on it, check `list_indexed_repositories`; after large changes ask the orchestrator to re-run `codegraphcontext index .` (or `watch_directory` in a long session). Indexing jobs report progress through `check_job_status`.
- **An empty result is not proof of absence** — dynamic dispatch, reflection, generated code and unsupported languages are not in the graph. Confirm with grep and say which query you ran.
- `execute_cypher_query` only when no other query answers; read-only queries only; never `delete_repository`.
- **Not connected or not indexed:** use grep and file reads, and say so in your report.
