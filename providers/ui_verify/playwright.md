---
capability: ui_verify
provider: playwright
verify_tool_value: playwright
mcp:
  name: playwright
  config: {"command": "npx", "args": ["@playwright/mcp@latest", "--isolated"]}
  add: "claude mcp add --scope project playwright -- npx @playwright/mcp@latest --isolated"
detect:
  files: [playwright.config.ts, playwright.config.js, playwright.config.mjs, playwright.config.cjs]
requires: [node, npx]
---

# Playwright — end-to-end UI tests for web

[Playwright Test](https://playwright.dev/docs/intro) (`@playwright/test`) runs committed browser tests — the evidence for `kind: ui` verify records. [Playwright MCP](https://github.com/microsoft/playwright-mcp) lets agents drive a browser interactively to explore and find locators; it is never the evidence.

## When it fits

Web UIs (any framework) in a browser. Not for native mobile apps; a mobile web view inside a native app needs a mobile runner.

## Install

Sources (checked 2026-09-30): [Playwright — installation](https://playwright.dev/docs/intro), [reporters](https://playwright.dev/docs/test-reporters), [trace viewer](https://playwright.dev/docs/trace-viewer), [Playwright MCP — Claude Code](https://github.com/microsoft/playwright-mcp#getting-started), [MCP options](https://github.com/microsoft/playwright-mcp#configuration).

Test runner, in the web app's directory (the onboarding command asks first; it adds a dev dependency, a config and example tests):

```bash
npm init playwright@latest
npx playwright install --with-deps   # browsers; on CI as well
npx playwright test
```

MCP server for exploration (merged into `.mcp.json` by the installer). `--isolated` keeps the browser profile in memory, so parallel sessions do not fight over one profile:

```bash
claude mcp add --scope project playwright -- npx @playwright/mcp@latest --isolated
```

Set `use.baseURL` in `playwright.config.*` from an environment variable (e.g. `BASE_URL`) so the same tests run against local and staging without hosts in code. Keep `trace: 'on-first-retry'` or `'retain-on-failure'` so a failed verification leaves a trace.

## Rules for agents

- **Test files:** under the project's Playwright `testDir` (see `playwright.config.*`), one scenario per test named after the Acceptance line. Locators: `getByRole`, `getByLabel`, `getByTestId` — no CSS chains or XPath tied to layout. Wait with web-first assertions (`await expect(locator).toHaveText(...)`), never `waitForTimeout`.
- **Run:** the area's `e2e_ui_command` (typically `npx --no playwright test <file>` — `--no` stops npx from downloading a package that is not installed); a single test with `-g "<title>"`; against a running system with its base URL from the environment (`BASE_URL=... npx playwright test`). Red first: show the test fails on the missing behaviour, not on a locator typo.
- **Assert the effect,** not only the page text: where the test can reach it, check the API response (`page.waitForResponse`, `request` fixture) or the stored state.
- **Explore with Playwright MCP** (`browser_navigate`, `browser_snapshot` for the accessibility tree and refs, `browser_click`, `browser_fill_form`, `browser_console_messages`, `browser_network_requests`) to reproduce a bug or find locators. Snapshot before acting; never type real credentials; close the browser (`browser_close`) when done. What you learn goes into a committed test.
- **Validator:** record `tool: playwright` and the exact command; `evidence` is the HTML report directory (`playwright-report/`) or a JUnit file, plus `test-results/` traces for failures.
- **Browsers missing** (`Executable doesn't exist`): installing them (`npx playwright install`) is setup, not a test failure — ask the owner first, it downloads browsers; never install when the owner declined downloads. **Flaky** (passes on retry): report it as a finding; a retry pass is not a clean PASS.

## Evidence

The HTML report directory (`playwright-report/`) or a JUnit file (`--reporter=junit`, `PLAYWRIGHT_JUNIT_OUTPUT_NAME=<path>`), plus `test-results/` traces and screenshots for failed tests. A CI artifact URL is fine when the run happened in CI.
