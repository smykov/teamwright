---
capability: ui_verify
provider: none
mcp: none
requires: []
---

# No UI verification tool

For projects without a user interface, or before a UI runner is set up. With `tools.ui_verify: none` the installer injects no tools block for this capability. A project that has a UI and no runner gets a first-sprint task to add one: the project is brought up to the process, not the process down to the project — unless the owner decided to go without UI verification for now (`ui_verify_deferred: "decisions.md #N"`, e.g. no downloads allowed): then there is no runner task, and UI tasks carry a reviewed `verify_exception`.

## When it fits

Projects without a user interface. A project with a UI and `none` is in a temporary state: a first-sprint task adds a runner, or the owner's deferral (`ui_verify_deferred`) is recorded.

## Install

Nothing to install.

## Rules for agents

- A task that changes a screen still declares `surface: ui` honestly. Without a runner it cannot reach `VERIFIED`: the validator writes `FAIL` with "no end-to-end UI runner", unless the owner grants a `verify_exception` for `kind: manual`.

## Evidence

None: only a `kind: manual` record under an explicit `verify_exception`, written by someone other than the implementer.
