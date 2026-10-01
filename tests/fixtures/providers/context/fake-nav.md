---
capability: context
provider: fake-nav
mcp:
  name: fake-nav
  config: {"command": "fake-nav-server", "args": ["--project", "."]}
  add: "claude mcp add fake-nav -- fake-nav-server"
detect:
  files: [.fakenav]
  commands: [fake-nav-server]
requires: [fake-nav-server]
---

## Install

Add the MCP server.

## Rules for agents

- FAKE-NAV-RULE: find symbols before reading files.
