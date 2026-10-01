---
capability: api_verify
provider: project-runner
mcp: none
requires: []
---

# Project runner — API tests with the project's own test stack

API evidence (`kind: api`) comes from the project's existing test runner — e.g. Jest/Vitest with supertest, pytest with httpx or requests, Go `net/http` tests, REST Assured. The command is the area's `api_test_command` in `.teamwright/config.yml`, detected from the project during onboarding.

## Install

Nothing to install from teamwright. Onboarding reads the project (package scripts, test configs, CI workflows, Makefile) and proposes `api_test_command` per area; it runs the command once to confirm it exists. A suite that only tests the app in-process still needs a thin set of tests that hit a **running** service through a base URL from the environment, and a version endpoint or log line for the deploy smoke — onboarding proposes these as first-sprint tasks when they are missing.

## Rules for agents

- **Test files** live with the area's existing API tests; follow their fixtures and naming. One test per Acceptance scenario, failure branch included (invalid input, missing auth, dependency down, limit exceeded).
- **Against the running system:** the base URL comes from an environment variable (e.g. `BASE_URL`), never a host in code or in the record. In-process tests (app booted inside the test) count for the gate, not for verification of a deploy — say which kind you ran.
- **Assert the effect:** status code and body **and** the stored state, sent message or log line where reachable — not the API's own success message alone.
- **Test data:** fake values only (`example.com`, documentation IP ranges, obvious fake tokens); create what you need and clean it up; never point at production data.
- **Run:** the area's `api_test_command`, narrowed to the task's tests with the runner's own filter (`-t`, `-k`, `--grep`). Save machine-readable output (JUnit XML or JSON reporter) when the runner supports it.
- **Validator:** `kind: api`, `tool:` the runner name (e.g. `jest`, `pytest`), the exact command, `environment: local | staging | production-like`.

## Evidence

The runner's JUnit/JSON report path, or the saved console log of the run (e.g. `test-results/api/<task>-<round>.xml`). Never a host, a token or response bodies with personal data.
