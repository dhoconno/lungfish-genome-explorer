# Wave 5 Modal Reduction 2 Plan

Scope: remove alert-only `runModal()` no-window fallbacks that do not need synchronous decisions.

Plan:
- Lower the allowed `runModal()` inventory for `AssemblyRuntimePreflight.swift`.
- Keep normal attached-window behavior as `beginSheetModal`.
- Replace the no-window warning fallback with `NSApp.presentError` because this path reports a warning and does not need a synchronous decision result.
- Apply the same treatment to assembly result warnings shown after a result window has closed.
- Verify with AppKit modal safety tests, presenter semantics tests, app build, and `git diff --check`.
