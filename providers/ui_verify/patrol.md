---
capability: ui_verify
provider: patrol
verify_tool_value: patrol
mcp: none
detect:
  files: [patrol_test]
  commands: [patrol]
requires: [flutter, dart, patrol]
---

# Patrol — Flutter end-to-end tests with native automation

[Patrol](https://github.com/leancodepl/patrol) extends Flutter integration tests with native automation: permission dialogs, notifications, system settings, other apps. Choose it over plain `integration_test` when the app depends on system dialogs.

## When it fits

Flutter apps whose flows touch **system dialogs or native UI**: runtime permissions (including the denied branch), notifications, pickers, the share sheet, system settings, another app. Builds on `integration_test`, so existing integration tests carry over. Needs a device or emulator and native setup in the Android/iOS projects. Prefer it over plain `flutter-integration-test` whenever a dialog is on a flow you must verify.

## Install

Sources (checked 2026-09-30): [Patrol documentation — setup](https://patrol.leancode.co/documentation), [`patrol test` command](https://patrol.leancode.co/cli-commands/test), [patrol_cli on pub.dev](https://pub.dev/packages/patrol_cli).

```bash
dart pub global activate patrol_cli
# in the Flutter app directory:
flutter pub add patrol --dev
patrol doctor
```

Then add the `patrol:` section to `pubspec.yaml` (`app_name`, `android.package_name`, `ios.bundle_id`) and the native setup for Android (instrumentation test runner) and iOS as the setup page describes — this touches native build files, so the onboarding command shows the diff and asks first. Tests live in `patrol_test/` by default (`test_directory` in the `patrol:` section changes it; files end in `_test.dart`). A device or emulator is required.

## Rules for agents

- **Test files:** in the Patrol test directory (`patrol_test/` unless `pubspec.yaml` sets `test_directory`), `patrolTest('<Acceptance line>', ($) async { ... })`. Find widgets by `Key` or semantics (`$(#submitButton)`, `$(Key('...'))`), not by text that localisation changes. Reuse existing robot/page objects.
- **System dialogs** through `$.platform.mobile` (e.g. `grantPermissionWhenInUse()`, `selectFineLocation()`, `openNotifications()`), never by tapping coordinates. Cover the **denied** branch too when the Acceptance failure branch is a refused permission.
- **Run:** the area's `e2e_ui_command`; one file with `patrol test --target <dir>/<name>_test.dart`, a device with `--device <id>`. `patrol develop --target ...` is for exploring with hot restart — never the evidence.
- **No device or emulator available:** stop and report `NEEDS_OWNER` (validator) or "not run: no device" (test-writer); do not fall back to widget tests and call it verified. `patrol doctor` output goes into the report.
- **Validator:** record `tool: patrol`, the exact command and the device/OS version in the record's notes; `evidence` is the native test report (Android: `build/app/reports/androidTests/`, JUnit) or the saved console log.

## Evidence

The native test report — Android: `build/app/reports/androidTests/` (JUnit) under the app directory; iOS: the `.xcresult` bundle — or the saved `patrol test` console log. Note the device and OS version in the record.
