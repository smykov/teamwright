---
capability: ui_verify
provider: flutter-integration-test
verify_tool_value: flutter-integration-test
mcp: none
detect:
  files: [integration_test]
requires: [flutter]
---

# Flutter integration_test — end-to-end tests in the Flutter SDK

The SDK's [`integration_test`](https://docs.flutter.dev/testing/integration-tests) package runs widget-style tests on a real device, emulator or desktop. No extra tools; it cannot press native system dialogs — use Patrol or Maestro if the flow needs them.

## When it fits

Flutter apps whose flows to verify stay **inside the app's own widgets**. It cannot press native dialogs (permissions, notifications, pickers): if any verified flow goes through one, choose `patrol` or `maestro` instead — an existing `integration_test/` directory does not change that. Needs a device, emulator or desktop target.

## Install

Sources (checked 2026-09-30): [Flutter — integration testing](https://docs.flutter.dev/testing/integration-tests), [`flutter test` reporters](https://docs.flutter.dev/testing/overview).

```bash
# in the Flutter app directory:
flutter pub add 'dev:integration_test:{"sdk":"flutter"}'
mkdir -p integration_test
flutter test integration_test
```

Each test file calls `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` first. A device or emulator is required (`flutter devices`).

## Rules for agents

- **Test files:** `integration_test/<feature>_test.dart`, `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` at the top, one `testWidgets('<Acceptance line>', ...)` per scenario. Find widgets by `Key` or semantics, not by localised text; wait with `pumpAndSettle` or by pumping until a finder matches — no fixed delays.
- **Native dialogs** (permissions, notifications) cannot be driven here: if the Acceptance failure branch goes through one, say so in the report — it needs Patrol or Maestro, or an explicit `verify_exception` from the owner.
- **Run:** the area's `e2e_ui_command`; one file with `flutter test integration_test/<name>_test.dart -d <device>`; a machine-readable result with `--reporter json` or `--file-reporter json:<path>`.
- **No device or emulator available:** validator → `NEEDS_OWNER`; test-writer → "not run: no device". Widget tests are not a substitute.
- **Validator:** record `tool: flutter-integration-test`, the command and device; `evidence` is the saved reporter output or console log.

## Evidence

The saved reporter output (`--file-reporter json:<path>`) or the console log of the run, with the device noted in the record.
