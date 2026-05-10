# State Management Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden app state management so resize, async loading, navigation, selection, and biological actions always reflect the active content identity.

**Architecture:** Introduce small shared state primitives first, then migrate domain controllers in branches with disjoint write scopes. Keep `MainSplitViewController` edits isolated to one branch. Tests are written before production changes, with deterministic unit/controller coverage before XCUI.

**Tech Stack:** Swift 6.2+, SwiftPM, XCTest, AppKit, SwiftUI, existing Lungfish app targets.

---

## Branch Sequence

1. `codex/state-foundations`
2. `codex/main-window-state`
3. `codex/viewer-fetch-state`
4. `codex/database-workflow-import-state`
5. `codex/metagenomics-selection-state`
6. `codex/state-integration-tests`

Branches 2-5 must be based on the final commit from branch 1. Branch 6 must be based on the merged integration result from branches 2-5.

## Task 1: Fix SwiftPM Test Discovery Baseline

**Files:**
- Modify: `Package.swift`
- Existing failing test file: `Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimGUIIntegrationTests.swift`

- [ ] **Step 1: Verify the baseline failure**

Run:

```bash
swift test list
```

Expected before the fix:

```text
Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimGUIIntegrationTests.swift:8:18: error: no such module 'LungfishApp'
```

- [ ] **Step 2: Add the missing integration-test dependency**

In `Package.swift`, add `"LungfishApp"` to the `LungfishIntegrationTests` target dependencies:

```swift
.testTarget(
    name: "LungfishIntegrationTests",
    dependencies: [
        "LungfishCore",
        "LungfishIO",
        "LungfishUI",
        "LungfishWorkflow",
        "LungfishCLI",
        "LungfishApp",
        "LungfishTestSupport",
    ],
    path: "Tests/LungfishIntegrationTests",
    resources: [
        .copy("Fixtures")
    ]
),
```

- [ ] **Step 3: Verify discovery now reaches test listing**

Run:

```bash
swift test list
```

Expected after the fix: command exits 0 and prints test names.

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "test: fix integration target app dependency"
```

## Task 2: Shared Async Request Gate

**Files:**
- Create: `Sources/LungfishApp/StateManagement/AsyncRequestGate.swift`
- Test: `Tests/LungfishAppTests/AsyncRequestGateTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/LungfishAppTests/AsyncRequestGateTests.swift`:

```swift
import XCTest
@testable import LungfishApp

final class AsyncRequestGateTests: XCTestCase {
    func testLatestTokenIsCurrentAndOlderTokenIsStale() {
        var gate = AsyncRequestGate<String>()

        let first = gate.begin(identity: "sample-A")
        let second = gate.begin(identity: "sample-B")

        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testInvalidateMakesExistingTokenStale() {
        var gate = AsyncRequestGate<String>()

        let token = gate.begin(identity: "query-A")
        gate.invalidate()

        XCTAssertFalse(gate.isCurrent(token))
    }

    func testIdentityMismatchIsStaleEvenWhenGenerationMatches() {
        var gate = AsyncRequestGate<String>()

        let token = gate.begin(identity: "track-A")

        XCTAssertFalse(gate.isCurrent(token, expectedIdentity: "track-B"))
        XCTAssertTrue(gate.isCurrent(token, expectedIdentity: "track-A"))
    }
}
```

- [ ] **Step 2: Run and verify red**

Run:

```bash
swift test --filter AsyncRequestGateTests
```

Expected: compile failure because `AsyncRequestGate` does not exist.

- [ ] **Step 3: Implement minimal gate**

Create `Sources/LungfishApp/StateManagement/AsyncRequestGate.swift`:

```swift
import Foundation

public struct AsyncRequestToken<Identity: Hashable>: Equatable {
    public let generation: UInt64
    public let identity: Identity
}

public struct AsyncRequestGate<Identity: Hashable> {
    private var generation: UInt64 = 0
    private var activeIdentity: Identity?

    public init() {}

    public mutating func begin(identity: Identity) -> AsyncRequestToken<Identity> {
        generation &+= 1
        activeIdentity = identity
        return AsyncRequestToken(generation: generation, identity: identity)
    }

    public mutating func invalidate() {
        generation &+= 1
        activeIdentity = nil
    }

    public func isCurrent(_ token: AsyncRequestToken<Identity>) -> Bool {
        token.generation == generation && activeIdentity == token.identity
    }

    public func isCurrent(_ token: AsyncRequestToken<Identity>, expectedIdentity: Identity) -> Bool {
        isCurrent(token) && token.identity == expectedIdentity
    }
}
```

- [ ] **Step 4: Verify green**

Run:

```bash
swift test --filter AsyncRequestGateTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/StateManagement/AsyncRequestGate.swift Tests/LungfishAppTests/AsyncRequestGateTests.swift
git commit -m "feat: add async request gate"
```

## Task 3: Content and Window Identity

**Files:**
- Create: `Sources/LungfishApp/StateManagement/ContentSelectionIdentity.swift`
- Create: `Sources/LungfishApp/StateManagement/WindowStateScope.swift`
- Test: `Tests/LungfishAppTests/ContentSelectionIdentityTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/LungfishAppTests/ContentSelectionIdentityTests.swift`:

```swift
import XCTest
@testable import LungfishApp

final class ContentSelectionIdentityTests: XCTestCase {
    func testStandardizedURLsMatchForEquivalentPaths() {
        let base = URL(fileURLWithPath: "/tmp/project/../project/results", isDirectory: true)
        let equivalent = URL(fileURLWithPath: "/tmp/project/results", isDirectory: true)

        let first = ContentSelectionIdentity(url: base, kind: "nvd", sampleID: "S1", resultID: "R1")
        let second = ContentSelectionIdentity(url: equivalent, kind: "nvd", sampleID: "S1", resultID: "R1")

        XCTAssertEqual(first, second)
    }

    func testDifferentSamplesDoNotMatchEvenWithSameURLAndResult() {
        let url = URL(fileURLWithPath: "/tmp/results", isDirectory: true)

        let sampleA = ContentSelectionIdentity(url: url, kind: "taxon", sampleID: "A", resultID: "9606")
        let sampleB = ContentSelectionIdentity(url: url, kind: "taxon", sampleID: "B", resultID: "9606")

        XCTAssertNotEqual(sampleA, sampleB)
    }

    func testWindowScopesAreUniqueUnlessExplicitlyReused() {
        let first = WindowStateScope()
        let second = WindowStateScope()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, first)
    }
}
```

- [ ] **Step 2: Run and verify red**

Run:

```bash
swift test --filter ContentSelectionIdentityTests
```

Expected: compile failure because the identity types do not exist.

- [ ] **Step 3: Implement content identity**

Create `Sources/LungfishApp/StateManagement/ContentSelectionIdentity.swift`:

```swift
import Foundation

public struct ContentSelectionIdentity: Hashable, Sendable {
    public let standardizedURLPath: String?
    public let kind: String
    public let sampleID: String?
    public let resultID: String?
    public let trackID: String?
    public let windowID: UUID?

    public init(
        url: URL?,
        kind: String,
        sampleID: String? = nil,
        resultID: String? = nil,
        trackID: String? = nil,
        windowID: UUID? = nil
    ) {
        self.standardizedURLPath = url?.standardizedFileURL.path
        self.kind = kind
        self.sampleID = sampleID
        self.resultID = resultID
        self.trackID = trackID
        self.windowID = windowID
    }
}
```

- [ ] **Step 4: Implement window scope**

Create `Sources/LungfishApp/StateManagement/WindowStateScope.swift`:

```swift
import Foundation

public struct WindowStateScope: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}
```

- [ ] **Step 5: Verify green**

Run:

```bash
swift test --filter ContentSelectionIdentityTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/StateManagement/ContentSelectionIdentity.swift Sources/LungfishApp/StateManagement/WindowStateScope.swift Tests/LungfishAppTests/ContentSelectionIdentityTests.swift
git commit -m "feat: add content and window identity"
```

## Task 4: Async Validation Session

**Files:**
- Create: `Sources/LungfishApp/StateManagement/AsyncValidationSession.swift`
- Test: `Tests/LungfishAppTests/AsyncValidationSessionTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/LungfishAppTests/AsyncValidationSessionTests.swift`:

```swift
import XCTest
@testable import LungfishApp

final class AsyncValidationSessionTests: XCTestCase {
    func testLatestInputResultIsAccepted() {
        var session = AsyncValidationSession<String, Int>()

        let first = session.begin(input: "path-A")
        let second = session.begin(input: "path-B")

        XCTAssertFalse(session.shouldAccept(resultFor: first))
        XCTAssertTrue(session.shouldAccept(resultFor: second))
    }

    func testCancelRejectsPendingResults() {
        var session = AsyncValidationSession<String, Int>()

        let token = session.begin(input: "query")
        session.cancel()

        XCTAssertFalse(session.shouldAccept(resultFor: token))
    }
}
```

- [ ] **Step 2: Run and verify red**

Run:

```bash
swift test --filter AsyncValidationSessionTests
```

Expected: compile failure because `AsyncValidationSession` does not exist.

- [ ] **Step 3: Implement minimal session**

Create `Sources/LungfishApp/StateManagement/AsyncValidationSession.swift`:

```swift
import Foundation

public struct AsyncValidationSession<Input: Hashable, Output> {
    private var gate = AsyncRequestGate<Input>()

    public init() {}

    public mutating func begin(input: Input) -> AsyncRequestToken<Input> {
        gate.begin(identity: input)
    }

    public mutating func cancel() {
        gate.invalidate()
    }

    public func shouldAccept(resultFor token: AsyncRequestToken<Input>) -> Bool {
        gate.isCurrent(token)
    }
}
```

- [ ] **Step 4: Verify green**

Run:

```bash
swift test --filter AsyncValidationSessionTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/StateManagement/AsyncValidationSession.swift Tests/LungfishAppTests/AsyncValidationSessionTests.swift
git commit -m "feat: add async validation session"
```

## Task 5: Selection Identity Store

**Files:**
- Create: `Sources/LungfishApp/StateManagement/SelectionIdentityStore.swift`
- Test: `Tests/LungfishAppTests/SelectionIdentityStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/LungfishAppTests/SelectionIdentityStoreTests.swift`:

```swift
import XCTest
@testable import LungfishApp

final class SelectionIdentityStoreTests: XCTestCase {
    func testSelectionSurvivesReorderByIdentity() {
        var store = SelectionIdentityStore<String>()
        store.select(["taxon:S1:9606"])

        let rows = ["taxon:S2:9606", "taxon:S1:9606", "taxon:S3:9606"]
        let indexes = store.visibleIndexes(in: rows)

        XCTAssertEqual(indexes, IndexSet(integer: 1))
    }

    func testSelectionClearsWhenIdentityNoLongerVisible() {
        var store = SelectionIdentityStore<String>()
        store.select(["virus:S1:NC_1"])

        let rows = ["virus:S2:NC_1"]
        store.removeSelectionsNotVisible(in: rows)

        XCTAssertTrue(store.selectedIDs.isEmpty)
    }
}
```

- [ ] **Step 2: Run and verify red**

Run:

```bash
swift test --filter SelectionIdentityStoreTests
```

Expected: compile failure because `SelectionIdentityStore` does not exist.

- [ ] **Step 3: Implement minimal store**

Create `Sources/LungfishApp/StateManagement/SelectionIdentityStore.swift`:

```swift
import Foundation

public struct SelectionIdentityStore<ID: Hashable> {
    public private(set) var selectedIDs: Set<ID> = []

    public init() {}

    public mutating func select<S: Sequence>(_ ids: S) where S.Element == ID {
        selectedIDs = Set(ids)
    }

    public mutating func clear() {
        selectedIDs.removeAll()
    }

    public mutating func removeSelectionsNotVisible<S: Sequence>(in visibleIDs: S) where S.Element == ID {
        let visible = Set(visibleIDs)
        selectedIDs = selectedIDs.intersection(visible)
    }

    public func visibleIndexes(in visibleIDs: [ID]) -> IndexSet {
        var indexes = IndexSet()
        for (index, id) in visibleIDs.enumerated() where selectedIDs.contains(id) {
            indexes.insert(index)
        }
        return indexes
    }
}
```

- [ ] **Step 4: Verify green**

Run:

```bash
swift test --filter SelectionIdentityStoreTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/StateManagement/SelectionIdentityStore.swift Tests/LungfishAppTests/SelectionIdentityStoreTests.swift
git commit -m "feat: add selection identity store"
```

## Task 6: Main Window State Branch

**Branch:** `codex/main-window-state`

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Layout/WorkspaceShellLayoutCoordinator.swift`
- Modify: `Sources/LungfishApp/Views/Layout/TwoPaneTrackedSplitCoordinator.swift`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Test: `Tests/LungfishAppTests/WorkspaceShellLayoutTests.swift`
- Create: `Tests/LungfishAppTests/MainSplitSelectionCoordinatorTests.swift`
- Create: `Tests/LungfishAppTests/InspectorNotificationScopingTests.swift`

- [ ] **Step 1: Add failing resize tests before layout edits**

Add tests that prove ordinary shell resize clamps widths without changing persisted user widths, and stacked split resize preserves clamped extents.

Run:

```bash
swift test --filter WorkspaceShellLayoutTests
```

Expected before implementation: at least one new test fails.

- [ ] **Step 2: Implement resize changes**

Change the shell resize path so ordinary resize recomputes resolved widths under programmatic suppression, uses `splitView.bounds.width` as the active width source when non-zero, and records user widths only from explicit divider drag intent.

- [ ] **Step 3: Add failing navigation and stale-load tests**

Create tests where slow selection A completes after selection B and cannot update the viewer/inspector. Add tests where context-menu Open routes through explicit display instead of notification-only selection.

- [ ] **Step 4: Implement navigation and scoped notification changes**

Use `ContentSelectionIdentity`, `WindowStateScope`, and `AsyncRequestGate` to guard result loader commits and observer callbacks. Keep backward compatibility for legacy unscoped notifications until the integration branch removes it.

- [ ] **Step 5: Verify branch**

Run:

```bash
swift test --filter WorkspaceShellLayoutTests
swift test --filter MainSplitSelectionCoordinatorTests
swift test --filter InspectorNotificationScopingTests
```

Expected: pass.

## Task 7: Viewer Fetch State Branch

**Branch:** `codex/viewer-fetch-state`

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- Test: `Tests/LungfishAppTests/ViewerViewportNotificationTests.swift`
- Create: `Tests/LungfishAppTests/SequenceViewerFetchInvalidationTests.swift`

- [ ] **Step 1: Add failing fetch invalidation tests**

Write tests that start read/depth/consensus fetch A, change settings or active track, complete A, and assert caches remain invalid until fetch B commits.

- [ ] **Step 2: Add failing resize redraw test**

Add a controller/view test proving geometry change marks the viewer as needing display immediately, before the deferred redraw task fires.

- [ ] **Step 3: Implement viewer invalidation**

Add a single viewer invalidation method that bumps read/depth/consensus generations, clears read/depth/consensus/pack/selection caches, resets `isFetching*`, and stores an active fetch identity based on bundle, track, region, and read-display settings.

- [ ] **Step 4: Verify branch**

Run:

```bash
swift test --filter ViewerViewportNotificationTests
swift test --filter SequenceViewerFetchInvalidationTests
```

Expected: pass.

## Task 8: Database, Workflow, Import, and Wizard State Branch

**Branch:** `codex/database-workflow-import-state`

**Files:**
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift`
- Modify: `Sources/LungfishApp/Views/Workflow/WorkflowConfigurationPanel.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdImportSheet.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift`
- Test: existing dialog/wizard tests plus new focused tests.

- [ ] **Step 1: Add failing async search/schema/import tests**

Use injectable delayed fakes or extracted state models to prove query/path/workflow A cannot overwrite B after B becomes active.

- [ ] **Step 2: Add failing readiness tests**

Prove EsViritu Run remains disabled until `databasePath` exists and Unified runner readiness only reflects the currently selected runner.

- [ ] **Step 3: Implement async validation sessions**

Use `AsyncValidationSession` or branch-local wrappers around it for database search, schema load, import path scan/validation, and wizard readiness callbacks.

- [ ] **Step 4: Verify branch**

Run targeted tests for each changed dialog/state area. At minimum:

```bash
swift test --filter DatabaseSearchDialogStateTests
swift test --filter WorkflowConfigurationPanelTests
swift test --filter UnifiedClassifierRunnerTests
```

Expected: pass or document exact unavailable test target if a named test file does not exist yet.

## Task 9: Metagenomics Selection State Branch

**Branch:** `codex/metagenomics-selection-state`

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/BatchTableView.swift`
- Modify result controllers that consume row-index selection callbacks.
- Test: existing metagenomics result tests plus new identity tests.

- [ ] **Step 1: Add failing sort/filter selection tests**

Create fixtures with the same taxon/accession/organism/contig names across samples/runs. Select one row, sort/filter/reload, and assert selection is preserved by identity or cleared when not visible.

- [ ] **Step 2: Implement row identity support**

Use `SelectionIdentityStore` in table wrappers/controllers. Row identity must include sample/run/result path where duplicate biological names are possible.

- [ ] **Step 3: Verify branch**

Run:

```bash
swift test --filter MetagenomicsGapFixTests
swift test --filter TaxonomyViewControllerTests
swift test --filter MappingResultViewControllerTests
```

Expected: pass or document exact unavailable test target if a named test file does not exist yet.

## Task 10: Integration and XCUI Branch

**Branch:** `codex/state-integration-tests`

**Files:**
- Modify: `Tests/LungfishXCUITests/TestSupport/MainWindowRobot.swift`
- Create: `Tests/LungfishXCUITests/MainWindowStateXCUITests.swift`
- Create: `Tests/LungfishXCUITests/MultiWindowStateXCUITests.swift`
- Create: `Tests/LungfishXCUITests/DialogResetXCUITests.swift`
- Add test fixtures only as needed.

- [ ] **Step 1: Add XCUI robot resize/divider helpers**

Expose helpers for resizing the main window, toggling sidebar/inspector, dragging dividers, opening a second project window, and reopening sheets.

- [ ] **Step 2: Add shell resize smoke tests**

Test wide-to-narrow-to-wide resize, sidebar/inspector toggles, and visible viewer responsiveness.

- [ ] **Step 3: Add multi-window isolation tests**

Open two windows and verify selection/inspector/toolbar updates in one window do not update the other.

- [ ] **Step 4: Add dialog reset tests**

Open, dirty, cancel, and reopen database/search/workflow dialogs. Verify state is fresh except intentional persisted preferences.

- [ ] **Step 5: Run full verification**

Run:

```bash
swift test list
swift test --filter LungfishAppTests
scripts/testing/run-macos-xcui.sh LungfishXCUITests/MainWindowStateXCUITests
scripts/testing/run-macos-xcui.sh LungfishXCUITests/MultiWindowStateXCUITests
scripts/testing/run-macos-xcui.sh LungfishXCUITests/DialogResetXCUITests
```

Expected: pass, or report exact environment blocker with command output.
