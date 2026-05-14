# Project Lock Banner And Help Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a persistent read-only warning banner when the GUI opens a project with active or unreadable lock metadata, and make Help menu links open online docs plus prefilled GitHub issue reports.

**Architecture:** Keep lock evaluation in `ProjectOpenWarningState` and add a small presentation layer that formats user-facing title/detail strings. Wrap the existing `MainSplitViewController` in a lightweight content controller that owns the banner, while `MainSplitViewController.applyProjectSessionState` notifies the wrapper when project lock state changes. Reuse `OperationFailureIssueReporter` and `GitHubIssueOpener` for issue URL generation/opening so UI tests keep intercepting network-free issue launches.

**Tech Stack:** Swift, AppKit, XCTest, Swift Package Manager.

---

## File Structure

- Create `Sources/LungfishApp/App/ProjectLockWarningPresentation.swift`
  Formats `ProjectOpenWarningState` into banner title/detail/accessibility strings.
- Create `Sources/LungfishApp/Views/MainWindow/ProjectLockWarningBannerView.swift`
  AppKit view for the slim persistent warning banner.
- Create `Sources/LungfishApp/Views/MainWindow/MainWindowContentViewController.swift`
  Vertical shell that owns the banner and embeds the existing `MainSplitViewController`.
- Modify `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
  Add `onProjectOpenWarningStateChanged` callback and call it when session state is applied or global open notifications arrive.
- Modify `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
  Install `MainWindowContentViewController` as window content while preserving `mainSplitViewController`.
- Modify `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`
  Add stable banner and online documentation identifiers.
- Modify `Sources/LungfishApp/App/MainMenu.swift`
  Add "Documentation" menu item and wire the help protocol action.
- Modify `Sources/LungfishApp/App/AppDelegate.swift`
  Open ReadTheDocs and build richer issue context from the active project/session.
- Modify `Sources/LungfishApp/Services/OperationFailureIssueReporter.swift`
  Add a general issue-report context/body builder that shares repository URL behavior with operation failures.
- Modify `docs/user-manual/chapters/01-foundations/09-shared-projects.md`
  Replace the obsolete note saying the GUI does not warn.
- Test with:
  - `Tests/LungfishAppTests/ProjectLockWarningPresentationTests.swift`
  - `Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift`
  - `Tests/LungfishAppTests/AppShellAccessibilityTests.swift`
  - `Tests/LungfishAppTests/OperationFailureIssueReporterTests.swift`

### Task 1: Lock Warning Presentation Tests

**Files:**
- Create: `Tests/LungfishAppTests/ProjectLockWarningPresentationTests.swift`
- Create: `Sources/LungfishApp/App/ProjectLockWarningPresentation.swift`

- [ ] **Step 1: Write the failing presentation tests**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class ProjectLockWarningPresentationTests: XCTestCase {
    func testUnlockedStateHasNoBannerPresentation() {
        let state = ProjectOpenWarningState.unlocked(projectURL: URL(fileURLWithPath: "/tmp/Example.lungfish"))

        XCTAssertNil(ProjectLockWarningPresentation(state: state))
    }

    func testActiveLockFormatsOwnerModeStatusAndTimestamp() throws {
        let record = ProjectLockRecord(
            schemaVersion: 1,
            toolName: "lungfish project lock",
            appVersion: "lungfish-cli 0.4.0-alpha.15",
            projectPath: "/tmp/Locked.lungfish",
            mode: "exclusive",
            user: "dho",
            host: "raven.local",
            pid: 47779,
            processStartTime: "2026-05-14T01:01:00Z",
            cwd: "/tmp",
            createdAt: "2026-05-14T01:03:00Z"
        )
        let state = ProjectOpenWarningState(
            projectURL: URL(fileURLWithPath: "/tmp/Locked.lungfish"),
            lockRecord: record,
            lockStatus: .active,
            readErrorDescription: nil
        )

        let presentation = try XCTUnwrap(ProjectLockWarningPresentation(state: state))

        XCTAssertEqual(presentation.title, "Project opened read-only")
        XCTAssertTrue(presentation.detail.contains("exclusive"))
        XCTAssertTrue(presentation.detail.contains("active"))
        XCTAssertTrue(presentation.detail.contains("lungfish project lock"))
        XCTAssertTrue(presentation.detail.contains("dho@raven.local"))
        XCTAssertTrue(presentation.detail.contains("pid 47779"))
        XCTAssertTrue(presentation.detail.contains("2026-05-14T01:03:00Z"))
    }

    func testUnreadableLockFormatsReadError() throws {
        let state = ProjectOpenWarningState(
            projectURL: URL(fileURLWithPath: "/tmp/Broken.lungfish"),
            lockRecord: nil,
            lockStatus: .unknown,
            readErrorDescription: "The data could not be read."
        )

        let presentation = try XCTUnwrap(ProjectLockWarningPresentation(state: state))

        XCTAssertEqual(presentation.title, "Project opened read-only")
        XCTAssertTrue(presentation.detail.contains("lock metadata could not be read"))
        XCTAssertTrue(presentation.detail.contains("The data could not be read."))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ProjectLockWarningPresentationTests`

Expected: FAIL because `ProjectLockWarningPresentation` is not defined.

- [ ] **Step 3: Implement minimal presentation code**

Create `ProjectLockWarningPresentation` with `title`, `detail`, `accessibilityLabel`, an initializer that returns `nil` for unlocked states, active/unknown lock detail formatting, and read-error detail formatting.

- [ ] **Step 4: Run the presentation tests**

Run: `swift test --filter ProjectLockWarningPresentationTests`

Expected: PASS.

### Task 2: Main Window Banner Tests And Implementation

**Files:**
- Modify: `Tests/LungfishAppTests/MainWindowSessionRoutingTests.swift`
- Modify: `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`
- Create: `Sources/LungfishApp/Views/MainWindow/ProjectLockWarningBannerView.swift`
- Create: `Sources/LungfishApp/Views/MainWindow/MainWindowContentViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`

- [ ] **Step 1: Write failing banner integration tests**

Add tests that create a temporary project, write a current-process active lock into `.lungfish/project.lock`, open it through `ProjectSession`, call `applyProjectSessionState`, and assert that `main-window-project-lock-banner`, `main-window-project-lock-banner-title`, and `main-window-project-lock-banner-detail` exist and include lock owner text. Add a second test opening an unlocked project and asserting the banner is absent.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MainWindowSessionRoutingTests/testReadOnlyProjectSessionShowsProjectLockBanner`

Expected: FAIL because no banner accessibility identifier exists.

- [ ] **Step 3: Add accessibility identifiers**

Add `MainWindowAccessibilityID.projectLockBanner`, `projectLockBannerTitle`, and `projectLockBannerDetail` constants.

- [ ] **Step 4: Implement banner view**

Create an AppKit `NSView` subclass containing a yellow warning icon, bold title label, wrapped detail label, stable accessibility identifiers, and an `update(with:)` method that hides itself when presentation is `nil`.

- [ ] **Step 5: Implement content wrapper**

Create `MainWindowContentViewController` that adds the banner and the existing split controller view in a vertical stack, updates the banner from `projectSession.openWarningState`, and hides the banner without occupying height when no presentation exists.

- [ ] **Step 6: Wire session updates**

Set `mainSplitViewController.onProjectOpenWarningStateChanged` from `MainWindowController.configureWindow()`. Call the callback at the end of `MainSplitViewController.applyProjectSessionState(restoring:)`, in the no-project branch, and after `handleProjectOpened(_:)` reads notification `openWarningState`.

- [ ] **Step 7: Run the banner tests**

Run: `swift test --filter MainWindowSessionRoutingTests`

Expected: PASS.

### Task 3: Help Menu Documentation And General Issue Prefill

**Files:**
- Modify: `Tests/LungfishAppTests/AppShellAccessibilityTests.swift`
- Modify: `Tests/LungfishAppTests/OperationFailureIssueReporterTests.swift`
- Modify: `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`
- Modify: `Sources/LungfishApp/App/MainMenu.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Services/OperationFailureIssueReporter.swift`

- [ ] **Step 1: Write failing Help menu tests**

Assert that the Help menu contains "Documentation" with identifier `help-menu-online-documentation` and action `#selector(AppDelegate.openOnlineDocumentation(_:))`. Keep the existing Report an Issue identifier assertion and add an action assertion for `#selector(AppDelegate.reportIssue(_:))`.

- [ ] **Step 2: Write failing issue prefill tests**

Add a test for `OperationFailureIssueReporter.generalIssueURL(context:homeDirectory:)` that asserts GitHub issue path, triage label, title `[Bug]:`, and a body containing app version, macOS version, hardware, project path redacted to `~/...`, project read-only status, lock summary, and user-editable sections.

- [ ] **Step 3: Run tests to verify failures**

Run:

```bash
swift test --filter AppShellAccessibilityTests/testMainMenuExposesStableIdentifiersForShellActions
swift test --filter OperationFailureIssueReporterTests/testGeneralIssueURLPrefillsEnvironmentAndProjectContext
```

Expected: FAIL because the online documentation menu identifier/action and general issue URL builder do not exist.

- [ ] **Step 4: Add menu identifier and action protocol**

Add `MainMenuAccessibilityID.onlineDocumentation`, add the Help menu item after local help, and add `openOnlineDocumentation(_:)` to `HelpMenuActions`.

- [ ] **Step 5: Add general issue context**

Add `OperationFailureIssueContext` with environment, optional project path, read-only recommendation, optional lock summary, and current window title. Add `generalIssueURL(context:homeDirectory:)` that redacts the home path and builds a useful issue body through the existing `newIssueURL` path.

- [ ] **Step 6: Wire AppDelegate actions**

Implement `openOnlineDocumentation(_:)` to open `https://lungfish-genome-explorer.readthedocs.io/en/latest/`. Implement `reportIssue(_:)` to build `OperationFailureIssueContext` from `OperationFailureIssueEnvironment.current`, `activeMainWindowController(sender:)`, `projectSession.projectURL`, `projectSession.isReadOnlyRecommended`, `projectSession.openWarningState`, and `window.title`, then pass the URL to `GitHubIssueOpener.open(_:)`.

- [ ] **Step 7: Run Help menu and issue reporter tests**

Run:

```bash
swift test --filter AppShellAccessibilityTests/testMainMenuExposesStableIdentifiersForShellActions
swift test --filter OperationFailureIssueReporterTests
```

Expected: PASS.

### Task 4: Documentation Update

**Files:**
- Modify: `docs/user-manual/chapters/01-foundations/09-shared-projects.md`

- [ ] **Step 1: Replace obsolete GUI note**

Replace the sentence:

```markdown
The current GUI does not yet warn on project-open when the lock exists, so shared teams should agree on CLI lock use before relying on shared storage for concurrent edits.
```

with text stating that the GUI now opens active/unknown locked projects in read-only-recommended mode, appends the read-only marker to the window title, shows a persistent banner, and blocks project-writing workflows.

- [ ] **Step 2: Verify the doc text**

Run: `rg -n "does not yet warn|persistent banner|Read Only" docs/user-manual/chapters/01-foundations/09-shared-projects.md`

Expected: no "does not yet warn" match and at least one match for the new GUI behavior text.

### Task 5: Focused Verification

**Files:**
- No new files.

- [ ] **Step 1: Run focused test suite**

Run:

```bash
swift test --filter ProjectLockWarningPresentationTests
swift test --filter MainWindowSessionRoutingTests
swift test --filter AppShellAccessibilityTests
swift test --filter OperationFailureIssueReporterTests
swift test --filter DocumentManagerTests/testOpenProjectSurfacesActiveLockAsReadOnlyWarningState
```

Expected: all commands PASS.

- [ ] **Step 2: Review diff**

Run: `git diff --stat && git diff --check`

Expected: diff only includes planned source, tests, docs, and no whitespace errors.

- [ ] **Step 3: Commit**

Run:

```bash
git add Sources/LungfishApp Tests/LungfishAppTests docs/user-manual docs/superpowers/plans
git commit -m "feat: warn on locked projects in gui"
```

Expected: commit succeeds on branch `codex/project-lock-warning-banner`.

## Self-Review

- Spec coverage: The plan covers the persistent banner, hidden state for unlocked projects, online documentation link, general issue prefill, and documentation note update.
- Placeholder scan: No placeholder steps remain; all test and implementation steps name concrete files, commands, and expected results.
- Type consistency: `ProjectLockWarningPresentation`, `MainWindowContentViewController`, `ProjectLockWarningBannerView`, `OperationFailureIssueContext`, and `generalIssueURL` are used consistently across tasks.
