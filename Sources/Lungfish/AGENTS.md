# Lungfish (app executable)

Line numbers were checked at commit a0eec8b32.

## Purpose

The app's `main.swift`. It answers the relocation smoke request, wires the Sparkle updater to `AppDelegate`, and starts NSApplication. It holds no feature logic and should stay that way.

## Allowed imports

LungfishApp, Sparkle, AppKit and Foundation. Sparkle is declared only on this target so that `lungfish-cli` never inherits the updater (comment on the Sparkle dependency in Package.swift).

## Entry points

| Type | Path |
|---|---|
| Process entry and `SparkleUpdaterBridge` | Sources/Lungfish/main.swift |
| App icon resource | Sources/Lungfish/AppIcon.icns |
| Relocation smoke hook | `DebugRelocationSmoke`, Sources/LungfishApp/App/DebugRelocationSmoke.swift |

## Contracts this module owns

- Update checks reach `AppDelegate` only through `checkForUpdatesHandler` and `canCheckForUpdatesHandler`.
- The release build wraps this binary in an .app with Sparkle.framework copied from SwiftPM artifacts (scripts/build-app.sh).

## Tests

No test target. The app is exercised through LungfishAppTests, the Xcode-only LungfishXCUITests (scripts/testing/run-macos-xcui.sh) and scripts/smoke-test-debug-app.sh.

## Known traps

| Trap | Evidence |
|---|---|
| `.build/debug/Lungfish` has no bundle identity, so screen capture cannot see its windows. Use `bash scripts/build-app.sh --debug --skip-build` and launch the bundle | memory file reference_gui_walkthrough_debug_build.md |
| A debug app finds resources through the compile-time .build path, so it crashes once its worktree is deleted. Build debug apps from the primary checkout | memory file reference_gui_walkthrough_debug_build.md |
| Several debug builds share the bundle id `com.lungfish.browser.debug`. Launch by path and confirm the pid | memory file reference_gui_walkthrough_debug_build.md |
| Debug, Preview and Stable are separate app builds. Confirm which one a fix targets | memory file project_app_channels.md |
