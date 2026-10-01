# Tools

The process is fixed: task lifecycle, analysis block, red tests first, a separate reviewer with recurrence exits, a recorded verification of the running system, journals and metrics. The **tools** that serve it are chosen per project, one per capability, in `.teamwright/config.yml`:

```yaml
tools:
  spec: spec-kit
  context: serena
  docs: context7
  ui_verify: playwright
  api_verify: project-runner
```

No hook depends on a tool. Gates read task files, review and verify records and journals; a verify record names the tool that produced it (`tool:`), and the gate checks that the record exists for the current code, not which tool wrote it.

## Capabilities

| Capability | What it serves in the process | Default | Alternatives |
|---|---|---|---|
| `spec` | Large work: specify → clarify → plan → tasks; every task gets `design_ref` | [Spec Kit](https://github.com/github/spec-kit) | [OpenSpec](https://github.com/Fission-AI/OpenSpec); `none` — a plain `docs/specs/<name>.md` |
| `context` | Code-aware context before analysis, implementation and review: definitions, every caller of a seam | [Serena](https://github.com/oraios/serena) (MCP) | [CodeGraphContext](https://github.com/CodeGraphContext/CodeGraphContext) (MCP, `codegraph`); `builtin` — grep, glob, LSP |
| `docs` | Package API lookup for the pinned version before use | [Context7](https://github.com/upstash/context7) (MCP) | `none` — the package's own docs for that version |
| `ui_verify` | End-to-end UI test runs for `kind: ui` verify records | [Playwright](https://playwright.dev/) (web; + Playwright MCP for exploration) | [Patrol](https://github.com/leancodepl/patrol), [Flutter `integration_test`](https://docs.flutter.dev/testing/integration-tests), [Maestro](https://github.com/mobile-dev-inc/maestro), Espresso / XCUITest (`espresso-xcuitest`), `none` |
| `api_verify` | API test runs for `kind: api` verify records | `project-runner` — the project's own suite (Jest + supertest, pytest + httpx, …) | — |

## How a tool reaches the agents

Each provider has an adapter in the kit, `providers/<capability>/<provider>.md`: how to detect and install it (with links to its official docs), its MCP server entry, and a **Rules for agents** block — when to use it, which of its tools or commands, what to do when it is missing, and what an empty result means. Onboarding (`/teamwright:adopt`, `/teamwright:init`) renders the chosen blocks into `AGENTS.md` and every role file between the markers:

```
<!-- teamwright:tools:begin -->
... rendered, do not edit by hand ...
<!-- teamwright:tools:end -->
```

`/teamwright:reconfigure` changes a capability's provider: it updates the config, re-renders only the text between the markers, and adds the provider's MCP server to `.mcp.json` with the owner's consent. Everything outside the markers is the project's own text and is never rewritten.

## Toolchain runners

Tools above serve the process; the **toolchain** (compilers, SDKs, test runners) is what every area's commands need to run at all. Each area declares how its commands run:

```yaml
areas:
  - name: app
    runner: docker            # host | docker (default host)
    image: "<the image CI uses for this area>"   # required with runner: docker
    cache: [".pub-cache"]     # package caches kept between runs (named volumes)
    workdir: app
    test_command: "flutter test"          # written without a wrapper
    generate_command: "flutter gen-l10n"  # optional: codegen, run before the gate
```

- `scripts/tw-run <area> -- <cmd>` (installed into the project) runs `<cmd>` on the host or in `docker run --rm` with the caller's uid/gid, the repository mounted, `workdir` as the working directory and the caches as volumes, and exits with the command's code. Rendered commands in `AGENTS.md` and the role files already go through it; `gate_command` is the aggregate and calls `scripts/tw-run` itself for docker areas.
- **Same image as CI.** When CI runs an area in a container, that image is the default for `runner: docker`, so a local green means a CI green. Otherwise the official image pinned to the version in the manifest or lock file, or a host install — the owner chooses at onboarding.
- **The gate does not modify tracked files.** Code generation that rewrites tracked files goes into `generate_command`, run separately; `tw-install.py check-commands` runs every configured command once and reports pass / fail / not runnable and whether `git status` changed.
- **No bare command that does not run.** A command is in the config only after it ran once, or it is marked not runnable with a first-sprint task.
- **UI runs need a device.** A container rarely has an emulator: `e2e_ui_command` usually runs on the host with a device or emulator attached; without one it is a first-sprint task, not a silent gap.
- Runner and image changes go through `.teamwright/config.next.yml` + `tw-install.py apply --config` like any config change (`/teamwright:reconfigure`).

## Choosing a UI runner

An existing suite wins over the default only if it covers the need. For mobile apps the deciding question is whether verified flows go through **system dialogs or native UI** (permissions, notifications, pickers, another app): then `patrol` (Flutter; builds on `integration_test`, existing tests carry over) or `maestro` (any framework, black-box), never plain `flutter-integration-test`, which cannot press native dialogs. Each `providers/ui_verify/*.md` adapter has a `## When it fits` section. Whichever is chosen, `e2e_ui_command` is run once at onboarding, or recorded as a first-sprint task with the exact blocker (no device, native setup missing).

## Rules that do not depend on the tool

- **Evidence is a test run**, never an interactive session: an MCP-driven browser or device helps to explore and reproduce; the verify record cites a committed test executed by its runner.
- **An empty search result is not proof of absence**, from any tool. Reports say where and how the agent looked.
- **Package APIs are checked against the pinned version's documentation**, never from memory.
- **Installing a tool is the owner's call.** Onboarding asks before adding an MCP server or installing a CLI; secrets such as API keys come from the environment, never from a committed file.
- A project with a UI and no UI runner is brought up to the process (a first-sprint task to add one), not verified by hand.
