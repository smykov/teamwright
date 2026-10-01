---
capability: ui_verify
provider: espresso-xcuitest
verify_tool_value: [espresso, xcuitest]
mcp: none
detect:
  files: [app/src/androidTest]
requires: []
---

# Espresso / XCUITest — native UI tests

For native Android (Espresso, run by the Android Gradle plugin) and native iOS (XCUITest, run by Xcode). The verify record's `tool` is `espresso` or `xcuitest` for the platform that ran.

## When it fits

Native Android (Espresso) and native iOS (XCUITest) apps, with system alerts handled by the platform's own APIs (UI Automator, interruption monitors). For a cross-platform app prefer the framework's runner (`patrol`) or `maestro`. Needs a device, emulator or simulator.

## Install

Sources (checked 2026-09-30): [Espresso setup](https://developer.android.com/training/testing/espresso/setup), [running instrumented tests](https://developer.android.com/studio/test/command-line), [XCUITest — user interface tests](https://developer.apple.com/documentation/xctest/user-interface-tests), [`xcodebuild` test](https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results).

- Android: add the `androidx.test.espresso:espresso-core` and `androidx.test.ext:junit` test dependencies and `testInstrumentationRunner "androidx.test.runner.AndroidJUnitRunner"` as in the setup guide; tests in `src/androidTest/`.
- iOS: add a UI Testing Bundle target in Xcode; tests use `XCUIApplication`.

## Rules for agents

- **Android tests** in `src/androidTest/`, one `@Test` per Acceptance scenario; match views with `withId(...)` or content descriptions, not display text; synchronise with Espresso idling resources, never `Thread.sleep`. Permission dialogs: `GrantPermissionRule` for the happy path, UI Automator for the denied branch.
- **iOS tests** in the UI test target; query elements by `accessibilityIdentifier`; wait with `waitForExistence(timeout:)`; system alerts via `addUIInterruptionMonitor` or `XCUIApplication(bundleIdentifier: "com.apple.springboard")`.
- **Run:** the area's `e2e_ui_command` — typically `./gradlew connectedAndroidTest` (one class: `-Pandroid.testInstrumentationRunnerArguments.class=<fqcn>`) or `xcodebuild test -scheme <scheme> -destination '<simulator>' -resultBundlePath <path>` (one test: `-only-testing:<target>/<class>/<method>`).
- **No device, emulator or simulator:** validator → `NEEDS_OWNER`; test-writer → "not run: no device".
- **Validator:** `tool: espresso` or `tool: xcuitest`; `evidence` is `build/reports/androidTests/connected/` (Android) or the `.xcresult` bundle path (iOS).

## Evidence

Android: `build/reports/androidTests/connected/` (HTML) or `build/outputs/androidTest-results/` (XML) of the app module. iOS: the `.xcresult` bundle from `-resultBundlePath`.
