---
capability: docs
provider: context7
mcp:
  name: context7
  config: {"type": "http", "url": "https://mcp.context7.com/mcp", "headers": {"Authorization": "Bearer ${CONTEXT7_API_KEY:-}"}}
  add: 'claude mcp add --scope project --transport http context7 https://mcp.context7.com/mcp --header "Authorization: Bearer ${CONTEXT7_API_KEY}"'
detect:
  commands: [ctx7]
requires: []
---

# context7 — current package documentation (MCP)

[Context7](https://github.com/upstash/context7) serves version-specific library documentation. Agents look up a package API before using it instead of relying on memory.

## Install

Sources (checked 2026-09-30): [README — Installation](https://github.com/upstash/context7#installation), [manual setup for other clients](https://context7.com/docs/resources/all-clients). Claude Code: [MCP scopes and environment variable expansion in `.mcp.json`](https://code.claude.com/docs/en/mcp).

The installer adds the remote server to the project's `.mcp.json` with the key read from the environment — **the key never goes into a committed file**:

```bash
export CONTEXT7_API_KEY=...   # free key from the Context7 dashboard; in your shell profile or secret manager
```

An API key is recommended for rate limits, not strictly required; the entry uses `${CONTEXT7_API_KEY:-}` so an unset variable does not break `.mcp.json`. Alternative: `npx ctx7 setup --claude` (Node.js 18+) configures the agent interactively via OAuth — it writes its own configuration, so run it only if you prefer it over the project entry.

## Rules for agents

- **Before using a library or framework API** you have not already verified in this task — a new call, a changed signature, a config option, a migration — look it up: `resolve-library-id` (`libraryName`, `query`) → `query-docs` (`libraryId`, `query`). Skip the first step when the ID is known (e.g. `/vercel/next.js`).
- **Pin the version:** read the version from the project's lock file or manifest and put it in the query; docs for another major version are a finding, not an answer.
- **Cite it:** name the library ID and version in your report when a decision depends on the docs. The reviewer checks changed calls against the same source.
- **No match or empty result:** the package is not indexed — read the package's own docs or source in the dependency directory, say so, and never fill the gap from memory.
- **Not connected** (no `mcp__context7__*` tools) or rate-limited: same fallback; report it.
