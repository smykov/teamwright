---
capability: ui_verify
provider: maestro
verify_tool_value: maestro
mcp:
  name: maestro
  config: {"command": "maestro", "args": ["mcp"]}
  add: "claude mcp add --scope project maestro -- maestro mcp"
detect:
  files: [.maestro]
  commands: [maestro]
requires: [java, maestro]
---

# Maestro — black-box mobile UI flows

[Maestro](https://github.com/mobile-dev-inc/maestro) drives Android and iOS apps (any framework) through the accessibility layer with YAML flows, including system dialogs. The Maestro MCP server ships inside the CLI and lets agents inspect and tap a live device.

## When it fits

Black-box flows on Android and iOS for **any framework** (Flutter, React Native, native), including system dialogs and permissions, without touching the app's build. Choose it over Patrol when the app is not Flutter, when you do not want native test setup in the app, or for cross-app flows. Needs a device or emulator and Java 17+.

## Install

Sources (checked 2026-09-30): [README — install](https://github.com/mobile-dev-inc/maestro#installing-maestro), [installing the CLI](https://docs.maestro.dev/maestro-cli/how-to-install-maestro-cli), [Maestro MCP](https://docs.maestro.dev/get-started/maestro-mcp), [test reports](https://docs.maestro.dev/llms-full.txt) ("Test reports and artifacts").

Requires Java 17+. The installer script is fetched from the network — the onboarding command asks first:

```bash
curl -fsSL "https://get.maestro.mobile.dev" | bash
maestro --version
```

MCP server (merged into `.mcp.json` by the installer):

```bash
claude mcp add --scope project maestro -- maestro mcp
```

Flows are YAML files, conventionally in `.maestro/` at the app root. A device, emulator or simulator is required.

## Rules for agents

- **Flow files:** one flow per Acceptance scenario in the project's flow directory (`.maestro/` by default), named after the Acceptance line. Select elements by `id` (resource id / accessibility identifier) before visible text; wait with `extendedWaitUntil` or assertions, never `sleep`-style waits. Handle permission dialogs as steps in the flow, including the denied branch when it is the failure branch.
- **Run:** the area's `e2e_ui_command`; one flow with `maestro test <flow>.yaml`; a report with `maestro test --format junit --output <dir>/report.xml <flows>` and artifacts with `--test-output-dir <dir>`.
- **Explore with Maestro MCP** (`list_devices`, `inspect_screen`, `take_screenshot`, `run` with an inline flow, `cheat_sheet` for syntax) to find ids and reproduce a bug; save what works as a committed flow. Do not use `run_on_cloud` unless the owner asked for it (paid service, uploads the app).
- **No device available:** validator → `NEEDS_OWNER`; test-writer → "not run: no device".
- **Validator:** record `tool: maestro` and the exact command; `evidence` is the JUnit report path plus the `--test-output-dir` screenshots for failures.

## Evidence

The JUnit report (`--format junit --output <path>`) plus the `--test-output-dir` directory (screenshots, `commands.json`) for failed flows.
