---
capability: docs
provider: none
mcp: none
requires: []
---

# No docs tool

No documentation server. With `tools.docs: none` the installer injects no tools block for this capability; the rule below is the convention the process docs already state.

## Install

Nothing to install.

## Rules for agents

- Before using a library API you have not verified in this task, read the documentation of the **pinned version**: the package's docs site for that version, or its source and type definitions in the dependency directory. Name the source in your report; never rely on memory for signatures, defaults or deprecations.
