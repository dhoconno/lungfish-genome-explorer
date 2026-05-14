# Project Lock Warning Banner - Design Spec

Date: 2026-05-14
Owner: Codex
Status: Draft for approval
Scope: GUI warning surface for project-open lock state. No broad multi-window or mutation-routing refactor is included.

## Current State

The app already evaluates project lock metadata when a `.lungfish` project opens:

- `ProjectOpenWarningState.evaluate(projectURL:)` reads `.lungfish/project.lock`, classifies the lock as `active`, `stale`, or `unknown`, and produces a read-only recommendation for active, unknown, or unreadable lock metadata.
- `ProjectSession.openProject(at:)` stores that state in `openWarningState`; `ProjectSession.isReadOnlyRecommended` exposes it to the window.
- `AppDelegate.updateProjectWindowTitle(_:)` appends `(Read Only)` to locked project windows.
- `MainSplitViewController.canWriteProjectOutputs(workflowName:)`, `AppDelegate.isProjectWriteBlocked(...)`, and several workflow paths already use read-only state to block project writes.

The missing product behavior is visible persistent feedback inside the GUI. A user can open a locked project and see the normal workspace unless they notice the window title suffix or trigger a write action.

## Goals

- Show a persistent, non-modal warning banner whenever the current project session recommends read-only behavior because of project lock metadata.
- Keep browsing and inspection workflows available.
- Preserve the existing `(Read Only)` window-title suffix and write-blocking alerts.
- Make the warning accessible and testable through stable accessibility identifiers.
- Keep the change local to project-open state presentation and avoid expanding the supported multi-user editing model.

## Non-Goals

- Automatically removing stale locks from the GUI.
- Offering a "force unlock" GUI action.
- Polling the lock file continuously after project open.
- Full read-only enforcement for every possible project mutation beyond the existing guard surface.
- Claiming collaborative editing or network-storage concurrency support.

## Product Behavior

When a project opens with an active, unknown, or unreadable lock:

- The main window title continues to include `(Read Only)`.
- A slim amber banner appears above the sidebar/viewer/inspector split panes.
- The banner headline says `Project opened read-only`.
- The banner detail includes the lock owner and mode when available, for example: `exclusive lock from dho@raven.local pid 47779`.
- If the lock metadata could not be decoded, the detail uses the read error from `ProjectOpenWarningState`.
- The banner includes a warning icon and an accessible label that combines the headline and detail.
- Project browsing, selection, provenance inspection, and exports outside the project remain available.
- Project-writing workflows that already route through read-only guards continue to show the existing blocking alert.

When a project opens without a read-only recommendation:

- No banner is shown.
- The split panes fill the window as they do today.
- The window title does not include `(Read Only)`.

## UI Design

The banner should be understated but hard to miss:

- Height: approximately 44 to 56 points, with dynamic height if the detail wraps.
- Placement: top of `MainSplitViewController`, above the existing split view.
- Visual treatment: `NSVisualEffectView` or a plain `NSView` with system amber tint, a thin separator, and standard AppKit label colors. Avoid modal styling.
- Content: SF Symbol `exclamationmark.triangle.fill`, headline label, detail label.
- Layout: a horizontal stack with the icon and a vertical text stack. Text must truncate or wrap without resizing toolbar or split pane controls unpredictably.
- Accessibility identifiers:
  - `main-window-project-lock-banner`
  - `main-window-project-lock-banner-title`
  - `main-window-project-lock-banner-detail`

## Architecture

Add a small AppKit view in the main-window area rather than creating a new global service:

- `MainSplitViewController` owns an optional banner view and a vertical root stack.
- The root stack contains the banner followed by the existing `splitView`.
- `configureSplitView()` continues to configure the split view; `viewDidLoad()` installs the root stack before adding the split items.
- `applyProjectSessionState(restoring:)` calls `updateProjectLockWarningBanner()` after title/sidebar/viewer state is applied.
- `handleProjectOpened(_:)` also updates the banner for the legacy `DocumentManager` notification path.
- `updateProjectLockWarningBanner()` reads `projectSession.openWarningState` first and falls back to notification `openWarningState` only for the legacy path.

The display string should be built from `ProjectOpenWarningState` in a testable helper:

```swift
struct ProjectLockWarningPresentation: Equatable {
    let title: String
    let detail: String
    let accessibilityLabel: String
}
```

The helper returns `nil` when `isReadOnlyRecommended` is false. For lock records it includes status, mode, user, host, pid, tool name, and created time where available. For read errors it includes the read error description.

## Error Handling

- If a lock record is present but partially invalid, `ProjectOpenWarningState` already turns decode failures into an unknown/read-error warning. The banner should show that warning rather than failing project open.
- If the banner cannot resolve a specific detail field, it should omit that field rather than inventing placeholder text.
- The banner must not block project opening; the project should remain browsable in read-only mode.

## Testing

Unit and app-level tests should cover:

- `ProjectLockWarningPresentation` returns `nil` for unlocked project state.
- It formats active lock records with title, mode, owner, pid, status, tool name, and created time.
- It formats read-error states without requiring a lock record.
- `MainSplitViewController` shows the banner after applying a project session whose `openWarningState` recommends read-only.
- `MainSplitViewController` hides the banner for an unlocked project session.
- Existing `ProjectCommandTests` and `DocumentManagerTests` continue to pass.

An XCUI smoke test is optional for this narrow pass because the AppKit hierarchy can be verified through `LungfishAppTests` using the stable accessibility identifiers.

## Documentation Follow-Up

After implementation, update `docs/user-manual/chapters/01-foundations/09-shared-projects.md` to remove the sentence saying the GUI does not yet warn on project-open. Replace it with a short note that locked projects open in read-only mode with a persistent banner and write-blocking alerts.

