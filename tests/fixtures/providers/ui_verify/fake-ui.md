---
capability: ui_verify
provider: fake-ui
mcp:
  name: fake-ui
verify_tool_value: fake-ui
detect:
  files: [fakeui.config.json]
---

## Install

```json
{"mcpServers": {"fake-ui": {"command": "npx", "args": ["fake-ui-mcp"]}}}
```

## Rules for agents

- FAKE-UI-RULE: UI evidence is a `fake-ui test` run.

## Evidence

`test-results/fake-ui/`
