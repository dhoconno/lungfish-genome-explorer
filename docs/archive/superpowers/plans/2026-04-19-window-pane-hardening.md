# Window Pane Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a shared AppKit layout foundation for the main window, sidebars, viewer panes, and bottom drawers so divider dragging, pane collapse/recovery, and viewport resizing behave consistently across current and future viewers.

**Architecture:** Replace ad hoc split-view math with four generic layers: a shell coordinator for `sidebar | content | inspector`, a reusable viewer-pane coordinator for list/detail/stacked layouts, semantic pane-host views for fill/scroll/viewport content, and a drawer host for bottom drawers. Migrate current metagenomics viewers onto that foundation first, but name the APIs generically so assembly, alignment, and mapping results can adopt them without new one-off geometry code.

**Tech Stack:** Swift, AppKit, NSSplitViewController, NSSplitView, Auto Layout, XCTest

---

## Scope

This plan covers:
- Main window shell sizing and resize persistence
- Shared raw split-view math and user-drag tracking
- Reusable viewer-pane layout coordination
- Reusable pane host and drawer host abstractions
- Migration of current metagenomics viewers onto the shared framework
- Adoption seams for future assembly/alignment/mapping viewers

This plan explicitly does **not** cover:
- Kraken2 `Collections` removal
- Kraken2 BLAST verify Phase 1 hang investigation
- Large miniBAM load timeout / cancellation UX for NAO-MGS

Those items should stay in separate branches/sessions.

## Baseline

Run this once on the branch before touching code:

```bash
swift test --filter MetagenomicsLayoutModeTests
```

Expected:
- PASS with `Executed 25 tests, with 0 failures`
- Current baseline still logs the existing TaxTriage split-view inconsistency warning
- No shell-level tests exist yet, so the Kraken2 sidebar recursion crash is currently uncovered

## File Structure

### New shared layout foundation files

- Create: `Sources/LungfishApp/Views/Layout/WorkspaceShellLayoutState.swift`
  - Persisted shell widths/collapse state and user-owned width bookkeeping.
- Create: `Sources/LungfishApp/Views/Layout/WorkspaceShellLayoutCoordinator.swift`
  - Main-window shell math, recommendation clamping, and reentrancy-safe restore logic.
- Create: `Sources/LungfishApp/Views/Layout/SplitGeometry.swift`
  - Shared clamp/collapse helpers for vertical and stacked layouts.
- Create: `Sources/LungfishApp/Views/Layout/TrackedSplitView.swift`
  - Generic divider request tracking, replacing metagenomics-only naming.
- Create: `Sources/LungfishApp/Views/Layout/ViewerLayoutMode.swift`
  - Generic list/detail layout mode enum for left/right/stacked presentation.
- Create: `Sources/LungfishApp/Views/Layout/ViewerPaneLayoutState.swift`
  - Persisted two-pane viewer state: orientation, divider positions, hidden pane recovery.
- Create: `Sources/LungfishApp/Views/Layout/ViewerPaneLayoutCoordinator.swift`
  - Shared two-pane layout engine for raw `NSSplitView` viewers.
- Create: `Sources/LungfishApp/Views/Layout/SplitPaneHostView.swift`
  - Full-bleed pane host that keeps embedded content synchronized to pane bounds.
- Create: `Sources/LungfishApp/Views/Layout/ScrollViewSplitPaneHostView.swift`
  - Scroll-view-specific pane host for miniBAM and other scroll-backed detail panes.
- Create: `Sources/LungfishApp/Views/Layout/DrawerHostState.swift`
  - Generic bottom drawer state and persisted height rules.
- Create: `Sources/LungfishApp/Views/Layout/DrawerHostView.swift`
  - Shared bottom drawer host with resize handle and collapse/restore semantics.

### Existing files to modify

- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
  - Replace direct `splitView.setPosition` restoration from resize callbacks with shell coordinator calls.
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
  - Add left sidebar toolbar button and bind toolbar state to shell coordinator visibility.
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
  - Introduce a generic hosted-content region that viewers/drawers attach to through shared abstractions.
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+NaoMgs.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift`
  - Stop doing bespoke pane math in display helpers; use the shared host/coordinator.
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+FASTQDrawer.swift`
  - Route bottom drawers through `DrawerHostView`.
- Modify: `Sources/LungfishApp/Views/Metagenomics/TrackedDividerSplitView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/MetagenomicsPaneSizing.swift`
  - Delete or reduce to thin wrappers over the new generic layout files.
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituDetailPane.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
  - Convert tool-specific split setup into declarative pane wiring plus tool-specific content only.
- Modify: `Sources/LungfishApp/Views/Metagenomics/MetagenomicsDrawerView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/BlastResultsDrawerContainerView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxaCollectionsDrawerView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/SampleFilterDrawerTab.swift`
  - Adopt the shared drawer host.
- Modify: `Sources/LungfishApp/Views/Results/Alignment/AlignmentResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Results/Taxonomy/TaxonomyResultViewController.swift`
  - Add adoption seams so future viewers can plug into the same generic host.

### Test files

- Create: `Tests/LungfishAppTests/WorkspaceShellLayoutTests.swift`
- Create: `Tests/LungfishAppTests/ViewerPaneLayoutCoordinatorTests.swift`
- Create: `Tests/LungfishAppTests/DrawerHostTests.swift`
- Modify: `Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift`
- Modify: `Tests/LungfishAppTests/MetagenomicsPaneSizingTests.swift`
- Modify: `Tests/LungfishAppTests/BlastResultsDrawerTests.swift`
- Modify: `Tests/LungfishAppTests/TaxaCollectionsDrawerTests.swift`
- Modify: `Tests/LungfishAppTests/SampleFilterDrawerTests.swift`
- Modify: `Tests/LungfishAppTests/TaxonomyViewControllerTests.swift`

## Task 1: Stop shell recursion and make shell widths user-owned

**Files:**
- Create: `Sources/LungfishApp/Views/Layout/WorkspaceShellLayoutState.swift`
- Create: `Sources/LungfishApp/Views/Layout/WorkspaceShellLayoutCoordinator.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Test: `Tests/LungfishAppTests/WorkspaceShellLayoutTests.swift`

- [ ] **Step 1: Write the failing shell tests**

```swift
// Tests/LungfishAppTests/WorkspaceShellLayoutTests.swift
import XCTest
@testable import LungfishApp

@MainActor
final class WorkspaceShellLayoutTests: XCTestCase {
    func testCoordinatorDoesNotRequestDividerMoveFromResizeCallback() {
        let coordinator = WorkspaceShellLayoutCoordinator(
            sidebarMinWidth: 180,
            sidebarMaxWidth: 420,
            inspectorMinWidth: 240,
            inspectorMaxWidth: 450,
            viewerMinWidth: 400
        )

        coordinator.recordUserSidebarWidth(260)
        let decision = coordinator.resizeDecision(
            event: .shellDidResize,
            currentSidebarWidth: 260,
            currentInspectorWidth: 300,
            totalWidth: 1500
        )

        XCTAssertFalse(decision.shouldSetSidebarDividerSynchronously)
        XCTAssertEqual(decision.sidebarWidthToPersist, 260)
    }

    func testCoordinatorPrefersRecordedUserWidthOverLateRecommendation() {
        let coordinator = WorkspaceShellLayoutCoordinator(
            sidebarMinWidth: 180,
            sidebarMaxWidth: 420,
            inspectorMinWidth: 240,
            inspectorMaxWidth: 450,
            viewerMinWidth: 400
        )

        coordinator.recordRecommendation(320)
        coordinator.recordUserSidebarWidth(220)

        XCTAssertEqual(coordinator.resolvedSidebarWidth(currentWidth: 220), 220)
    }
}
```

- [ ] **Step 2: Run the shell tests to verify they fail**

Run:

```bash
swift test --filter WorkspaceShellLayoutTests
```

Expected:
- FAIL to compile because `WorkspaceShellLayoutCoordinator` and `WorkspaceShellLayoutState` do not exist yet

- [ ] **Step 3: Implement the shell state and coordinator**

```swift
// Sources/LungfishApp/Views/Layout/WorkspaceShellLayoutState.swift
import CoreGraphics

struct WorkspaceShellLayoutState: Equatable {
    var isSidebarVisible = true
    var isInspectorVisible = true
    var lastUserSidebarWidth: CGFloat?
    var lastUserInspectorWidth: CGFloat?
    var pendingRecommendedSidebarWidth: CGFloat?
}

// Sources/LungfishApp/Views/Layout/WorkspaceShellLayoutCoordinator.swift
import CoreGraphics

@MainActor
final class WorkspaceShellLayoutCoordinator {
    enum Event { case shellDidResize, recommendationArrived, userDraggedSidebar, userDraggedInspector }

    struct Decision: Equatable {
        var shouldSetSidebarDividerSynchronously: Bool
        var sidebarWidthToPersist: CGFloat?
        var inspectorWidthToPersist: CGFloat?
    }

    private(set) var state = WorkspaceShellLayoutState()
    private let sidebarMinWidth: CGFloat
    private let sidebarMaxWidth: CGFloat
    private let inspectorMinWidth: CGFloat
    private let inspectorMaxWidth: CGFloat
    private let viewerMinWidth: CGFloat

    init(sidebarMinWidth: CGFloat, sidebarMaxWidth: CGFloat, inspectorMinWidth: CGFloat, inspectorMaxWidth: CGFloat, viewerMinWidth: CGFloat) {
        self.sidebarMinWidth = sidebarMinWidth
        self.sidebarMaxWidth = sidebarMaxWidth
        self.inspectorMinWidth = inspectorMinWidth
        self.inspectorMaxWidth = inspectorMaxWidth
        self.viewerMinWidth = viewerMinWidth
    }

    func recordRecommendation(_ width: CGFloat) {
        state.pendingRecommendedSidebarWidth = min(max(width, sidebarMinWidth), sidebarMaxWidth)
    }

    func recordUserSidebarWidth(_ width: CGFloat) {
        state.lastUserSidebarWidth = min(max(width, sidebarMinWidth), sidebarMaxWidth)
    }

    func recordUserInspectorWidth(_ width: CGFloat) {
        state.lastUserInspectorWidth = min(max(width, inspectorMinWidth), inspectorMaxWidth)
    }

    func resolvedSidebarWidth(currentWidth: CGFloat) -> CGFloat {
        state.lastUserSidebarWidth
            ?? state.pendingRecommendedSidebarWidth
            ?? currentWidth
    }

    func resizeDecision(event: Event, currentSidebarWidth: CGFloat, currentInspectorWidth: CGFloat, totalWidth: CGFloat) -> Decision {
        Decision(
            shouldSetSidebarDividerSynchronously: false,
            sidebarWidthToPersist: min(max(currentSidebarWidth, sidebarMinWidth), sidebarMaxWidth),
            inspectorWidthToPersist: min(max(currentInspectorWidth, inspectorMinWidth), inspectorMaxWidth)
        )
    }
}
```

- [ ] **Step 4: Wire the shell coordinator into the main window**

```swift
// Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift
private let shellLayoutCoordinator = WorkspaceShellLayoutCoordinator(
    sidebarMinWidth: 180,
    sidebarMaxWidth: 420,
    inspectorMinWidth: 240,
    inspectorMaxWidth: 450,
    viewerMinWidth: 400
)

private func applySidebarPreferredWidth(_ width: CGFloat, allowShrink: Bool) {
    shellLayoutCoordinator.recordRecommendation(width)
    guard splitView.subviews.count > 1 else { return }
    guard !sidebarItem.isCollapsed else { return }

    let current = splitView.subviews[0].frame.width
    let resolved = shellLayoutCoordinator.resolvedSidebarWidth(currentWidth: current)
    let target = allowShrink ? resolved : max(current, resolved)
    guard abs(target - current) >= 1 else { return }

    DispatchQueue.main.async { [weak self] in
        self?.splitView.setPosition(target, ofDividerAt: 0)
    }
}

public override func splitViewDidResizeSubviews(_ notification: Notification) {
    if splitView.subviews.count > 1, !sidebarItem.isCollapsed {
        shellLayoutCoordinator.recordUserSidebarWidth(splitView.subviews[0].frame.width)
    }

    if splitView.subviews.count > 2, !inspectorItem.isCollapsed {
        shellLayoutCoordinator.recordUserInspectorWidth(splitView.subviews[2].frame.width)
    }

    guard inspectorTransitionInFlight else { return }
    guard let targetCollapsed = inspectorTransitionTargetCollapsedState else { return }
    guard inspectorItem.isCollapsed == targetCollapsed else { return }
    completeInspectorCollapseAnimation(serial: inspectorTransitionSerial, source: "splitViewDidResizeSubviews")
}

// Sources/LungfishApp/Views/MainWindow/MainWindowController.swift
private enum ToolbarIdentifier {
    static let toggleSidebar = NSToolbarItem.Identifier("ToggleSidebar")
    static let toggleInspector = NSToolbarItem.Identifier("ToggleInspector")
}

public func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
) -> NSToolbarItem? {
    switch itemIdentifier {
    case ToolbarIdentifier.toggleSidebar:
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let button = makeToolbarButton(
            symbolName: "sidebar.leading",
            fallbacks: ["sidebar.left", "sidebar.squares.leading"],
            accessibilityLabel: "Toggle Sidebar"
        )
        button.target = self
        button.action = #selector(toggleSidebar(_:))
        item.view = button
        return item
    default:
        return nil
    }
}
```

- [ ] **Step 5: Run the shell tests to verify they pass**

Run:

```bash
swift test --filter WorkspaceShellLayoutTests
```

Expected:
- PASS with `Executed 2 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Layout/WorkspaceShellLayoutState.swift \
        Sources/LungfishApp/Views/Layout/WorkspaceShellLayoutCoordinator.swift \
        Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift \
        Sources/LungfishApp/Views/MainWindow/MainWindowController.swift \
        Tests/LungfishAppTests/WorkspaceShellLayoutTests.swift
git commit -m "refactor: stabilize workspace shell layout"
```

## Task 2: Extract generic split math and tracked-divider primitives

**Files:**
- Create: `Sources/LungfishApp/Views/Layout/SplitGeometry.swift`
- Create: `Sources/LungfishApp/Views/Layout/TrackedSplitView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TrackedDividerSplitView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/MetagenomicsPaneSizing.swift`
- Test: `Tests/LungfishAppTests/MetagenomicsPaneSizingTests.swift`

- [ ] **Step 1: Write failing generic split-geometry tests**

```swift
// Tests/LungfishAppTests/MetagenomicsPaneSizingTests.swift
import XCTest
@testable import LungfishApp

final class MetagenomicsPaneSizingTests: XCTestCase {
    func testGenericDividerClampPreservesTrailingMinimum() {
        XCTAssertEqual(
            SplitGeometry.clampedDividerPosition(
                proposed: 1180,
                containerExtent: 1200,
                minimumLeadingExtent: 240,
                minimumTrailingExtent: 320
            ),
            880
        )
    }

    func testTrackedSplitViewRecordsRequestedPosition() {
        let splitView = TrackedSplitView(frame: .init(x: 0, y: 0, width: 1200, height: 700))
        splitView.isVertical = true
        splitView.addArrangedSubview(NSView(frame: .init(x: 0, y: 0, width: 300, height: 700)))
        splitView.addArrangedSubview(NSView(frame: .init(x: 301, y: 0, width: 899, height: 700)))

        splitView.setPosition(260, ofDividerAt: 0)

        XCTAssertEqual(splitView.requestedDividerPosition(at: 0), 260)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter MetagenomicsPaneSizingTests
```

Expected:
- FAIL because `SplitGeometry` and `TrackedSplitView` do not exist yet

- [ ] **Step 3: Implement the generic split helpers**

```swift
// Sources/LungfishApp/Views/Layout/SplitGeometry.swift
import CoreGraphics

enum SplitGeometry {
    static func clampedDividerPosition(
        proposed: CGFloat,
        containerExtent: CGFloat,
        minimumLeadingExtent: CGFloat,
        minimumTrailingExtent: CGFloat
    ) -> CGFloat {
        let maximumDividerPosition = max(minimumLeadingExtent, containerExtent - minimumTrailingExtent)
        return min(max(proposed, minimumLeadingExtent), maximumDividerPosition)
    }

    static func clampedDrawerExtent(
        proposed: CGFloat,
        containerExtent: CGFloat,
        minimumDrawerExtent: CGFloat,
        minimumSiblingExtent: CGFloat
    ) -> CGFloat {
        let maximumDrawerExtent = max(0, containerExtent - minimumSiblingExtent)
        if maximumDrawerExtent < minimumDrawerExtent {
            return min(max(proposed, 0), maximumDrawerExtent)
        }
        return min(max(proposed, minimumDrawerExtent), maximumDrawerExtent)
    }
}

// Sources/LungfishApp/Views/Layout/TrackedSplitView.swift
import AppKit

final class TrackedSplitView: NSSplitView {
    private var requestedDividerPositions: [Int: CGFloat] = [:]

    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        requestedDividerPositions[dividerIndex] = position
        super.setPosition(position, ofDividerAt: dividerIndex)
    }

    func requestedDividerPosition(at dividerIndex: Int) -> CGFloat? {
        requestedDividerPositions[dividerIndex]
    }

    func recordObservedDividerPosition(_ position: CGFloat, at dividerIndex: Int = 0) {
        requestedDividerPositions[dividerIndex] = position
    }
}
```

- [ ] **Step 4: Reduce metagenomics-specific helpers to wrappers**

```swift
// Sources/LungfishApp/Views/Metagenomics/MetagenomicsPaneSizing.swift
import CoreGraphics

enum MetagenomicsPaneSizing {
    static func clampedDrawerExtent(
        proposed: CGFloat,
        containerExtent: CGFloat,
        minimumDrawerExtent: CGFloat,
        minimumSiblingExtent: CGFloat
    ) -> CGFloat {
        SplitGeometry.clampedDrawerExtent(
            proposed: proposed,
            containerExtent: containerExtent,
            minimumDrawerExtent: minimumDrawerExtent,
            minimumSiblingExtent: minimumSiblingExtent
        )
    }
}

// Sources/LungfishApp/Views/Metagenomics/TrackedDividerSplitView.swift
typealias TrackedDividerSplitView = TrackedSplitView
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
swift test --filter MetagenomicsPaneSizingTests
```

Expected:
- PASS with all split-geometry tests green

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Layout/SplitGeometry.swift \
        Sources/LungfishApp/Views/Layout/TrackedSplitView.swift \
        Sources/LungfishApp/Views/Metagenomics/TrackedDividerSplitView.swift \
        Sources/LungfishApp/Views/Metagenomics/MetagenomicsPaneSizing.swift \
        Tests/LungfishAppTests/MetagenomicsPaneSizingTests.swift
git commit -m "refactor: extract generic split geometry"
```

## Task 3: Build a generic viewer-pane layout engine

**Files:**
- Create: `Sources/LungfishApp/Views/Layout/ViewerLayoutMode.swift`
- Create: `Sources/LungfishApp/Views/Layout/ViewerPaneLayoutState.swift`
- Create: `Sources/LungfishApp/Views/Layout/ViewerPaneLayoutCoordinator.swift`
- Create: `Sources/LungfishApp/Views/Layout/SplitPaneHostView.swift`
- Create: `Sources/LungfishApp/Views/Layout/ScrollViewSplitPaneHostView.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Test: `Tests/LungfishAppTests/ViewerPaneLayoutCoordinatorTests.swift`

- [ ] **Step 1: Write the failing viewer-layout tests**

```swift
// Tests/LungfishAppTests/ViewerPaneLayoutCoordinatorTests.swift
import XCTest
@testable import LungfishApp

final class ViewerPaneLayoutCoordinatorTests: XCTestCase {
    func testListLeadingModeUsesVerticalSplit() {
        let coordinator = ViewerPaneLayoutCoordinator(
            primaryMinimumExtent: 260,
            secondaryMinimumExtent: 320
        )

        let layout = coordinator.layout(
            mode: .listLeading,
            containerSize: .init(width: 1400, height: 900),
            lastUserDividerPosition: nil
        )

        XCTAssertTrue(layout.isVertical)
        XCTAssertEqual(layout.leadingRole, .list)
    }

    func testListOverDetailUsesStackedSplit() {
        let coordinator = ViewerPaneLayoutCoordinator(
            primaryMinimumExtent: 260,
            secondaryMinimumExtent: 320
        )

        let layout = coordinator.layout(
            mode: .listOverDetail,
            containerSize: .init(width: 1400, height: 900),
            lastUserDividerPosition: nil
        )

        XCTAssertFalse(layout.isVertical)
        XCTAssertEqual(layout.leadingRole, .list)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter ViewerPaneLayoutCoordinatorTests
```

Expected:
- FAIL because `ViewerPaneLayoutCoordinator` and `ViewerLayoutMode` do not exist yet

- [ ] **Step 3: Implement the generic viewer coordinator and pane hosts**

```swift
// Sources/LungfishApp/Views/Layout/ViewerLayoutMode.swift
enum ViewerLayoutMode: String, CaseIterable {
    case detailLeading
    case listLeading
    case listOverDetail
}

enum ViewerPaneRole { case list, detail }

// Sources/LungfishApp/Views/Layout/ViewerPaneLayoutState.swift
import AppKit
import CoreGraphics

protocol ViewerLayoutSupporting: AnyObject {
    var supportedLayoutModes: Set<ViewerLayoutMode> { get }
}

protocol ViewerPaneProviding: ViewerLayoutSupporting {
    func makeListPaneView() -> NSView
    func makeDetailPaneView() -> NSView
    func paneMinimumExtents(for mode: ViewerLayoutMode) -> (leading: CGFloat, trailing: CGFloat)
}

struct ViewerPaneLayoutState: Equatable {
    var selectedMode: ViewerLayoutMode = .detailLeading
    var lastDividerPositionByMode: [ViewerLayoutMode: CGFloat] = [:]
}

// Sources/LungfishApp/Views/Layout/ViewerPaneLayoutCoordinator.swift
import AppKit

struct ViewerPaneLayout {
    var isVertical: Bool
    var leadingRole: ViewerPaneRole
    var dividerPosition: CGFloat
}

@MainActor
final class ViewerPaneLayoutCoordinator {
    private let primaryMinimumExtent: CGFloat
    private let secondaryMinimumExtent: CGFloat

    init(primaryMinimumExtent: CGFloat, secondaryMinimumExtent: CGFloat) {
        self.primaryMinimumExtent = primaryMinimumExtent
        self.secondaryMinimumExtent = secondaryMinimumExtent
    }

    func layout(mode: ViewerLayoutMode, containerSize: NSSize, lastUserDividerPosition: CGFloat?) -> ViewerPaneLayout {
        switch mode {
        case .detailLeading:
            return ViewerPaneLayout(isVertical: true, leadingRole: .detail, dividerPosition: lastUserDividerPosition ?? 520)
        case .listLeading:
            return ViewerPaneLayout(isVertical: true, leadingRole: .list, dividerPosition: lastUserDividerPosition ?? 420)
        case .listOverDetail:
            return ViewerPaneLayout(isVertical: false, leadingRole: .list, dividerPosition: lastUserDividerPosition ?? 360)
        }
    }
}

// Sources/LungfishApp/Views/Layout/SplitPaneHostView.swift
import AppKit

final class SplitPaneHostView: NSView {
    weak var fillSubview: NSView?

    override func layout() {
        super.layout()
        fillSubview?.frame = bounds
    }
}
```

- [ ] **Step 4: Add a reusable hosted-content root to `ViewerViewController`**

```swift
// Sources/LungfishApp/Views/Viewer/ViewerViewController.swift
@MainActor
public class ViewerViewController: NSViewController {
    private var hostedResultContainerView: NSView!
    private(set) var viewerPaneCoordinator: ViewerPaneLayoutCoordinator?

    public override func loadView() {
        let containerView = NSView()
        hostedResultContainerView = NSView()
        hostedResultContainerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostedResultContainerView)

        NSLayoutConstraint.activate([
            hostedResultContainerView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostedResultContainerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostedResultContainerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostedResultContainerView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        self.view = containerView
    }

    func installHostedViewer(
        _ controller: NSViewController & ViewerPaneProviding,
        layoutMode: ViewerLayoutMode,
        paneProvider: ViewerPaneProviding
    ) {
        viewerPaneCoordinator = ViewerPaneLayoutCoordinator(
            primaryMinimumExtent: paneProvider.paneMinimumExtents(for: layoutMode).leading,
            secondaryMinimumExtent: paneProvider.paneMinimumExtents(for: layoutMode).trailing
        )

        let hostedView = controller.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        hostedResultContainerView.addSubview(hostedView)

        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: hostedResultContainerView.topAnchor),
            hostedView.leadingAnchor.constraint(equalTo: hostedResultContainerView.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: hostedResultContainerView.trailingAnchor),
            hostedView.bottomAnchor.constraint(equalTo: hostedResultContainerView.bottomAnchor),
        ])
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run:

```bash
swift test --filter ViewerPaneLayoutCoordinatorTests
```

Expected:
- PASS with both layout-mode tests green

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Layout/ViewerLayoutMode.swift \
        Sources/LungfishApp/Views/Layout/ViewerPaneLayoutState.swift \
        Sources/LungfishApp/Views/Layout/ViewerPaneLayoutCoordinator.swift \
        Sources/LungfishApp/Views/Layout/SplitPaneHostView.swift \
        Sources/LungfishApp/Views/Layout/ScrollViewSplitPaneHostView.swift \
        Sources/LungfishApp/Views/Viewer/ViewerViewController.swift \
        Tests/LungfishAppTests/ViewerPaneLayoutCoordinatorTests.swift
git commit -m "feat: add reusable viewer pane layout engine"
```

## Task 4: Migrate metagenomics viewers onto the shared pane engine

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+NaoMgs.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituDetailPane.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
- Test: `Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift`
- Test: `Tests/LungfishAppTests/TaxonomyViewControllerTests.swift`

- [ ] **Step 1: Write failing framework-level migration tests**

```swift
// Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift
@MainActor
func testEsVirituUsesSharedViewerPaneCoordinator() {
    let controller = EsVirituResultViewController()
    _ = controller.view

    XCTAssertEqual(controller.supportedLayoutModes, [.detailLeading, .listLeading, .listOverDetail])
}

@MainActor
func testNvdDeclaresSharedPaneMinimums() {
    let controller = NvdResultViewController()
    _ = controller.view

    let minimums = controller.paneMinimumExtents(for: .listOverDetail)
    XCTAssertGreaterThan(minimums.leading, 0)
    XCTAssertGreaterThan(minimums.trailing, 0)
}
```

- [ ] **Step 2: Run the metagenomics layout tests to verify they fail**

Run:

```bash
swift test --filter MetagenomicsLayoutModeTests
```

Expected:
- FAIL because the result controllers do not expose shared layout state or coordinated divider application yet

- [ ] **Step 3: Convert result controllers into pane-content providers**

```swift
// Sources/LungfishApp/Views/Layout/ViewerPaneLayoutState.swift
import AppKit

protocol ViewerPaneProviding: AnyObject {
    var supportedLayoutModes: Set<ViewerLayoutMode> { get }
    func makeListPaneView() -> NSView
    func makeDetailPaneView() -> NSView
    func paneMinimumExtents(for mode: ViewerLayoutMode) -> (leading: CGFloat, trailing: CGFloat)
}

// Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift
extension EsVirituResultViewController: ViewerPaneProviding {
    var supportedLayoutModes: Set<ViewerLayoutMode> { [.detailLeading, .listLeading, .listOverDetail] }

    func makeListPaneView() -> NSView { resultsScrollView }
    func makeDetailPaneView() -> NSView { detailPaneContainerView }
}
```

- [ ] **Step 4: Route each viewer extension through the shared host**

```swift
// Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift
func displayEsVirituFromDatabase(db: EsVirituDatabase, resultURL: URL) {
    let controller = EsVirituResultViewController()
    addChild(controller)
    _ = controller.view
    controller.configureFromDatabase(db, resultURL: resultURL)

    installHostedViewer(
        controller,
        layoutMode: .detailLeading,
        paneProvider: controller
    )
}

// Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift
public func displayNvdResult(_ controller: NvdResultViewController) {
    installHostedViewer(
        controller,
        layoutMode: .listOverDetail,
        paneProvider: controller
    )
}
```

- [ ] **Step 5: Re-run the metagenomics tests and the targeted controller tests**

Run:

```bash
swift test --filter MetagenomicsLayoutModeTests
swift test --filter TaxonomyViewControllerTests
```

Expected:
- PASS with existing live-window split tests green
- No snapback regressions in EsViritu, TaxTriage, NAO-MGS, or NVD

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift \
        Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift \
        Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift \
        Sources/LungfishApp/Views/Viewer/ViewerViewController+NaoMgs.swift \
        Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift \
        Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift \
        Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift \
        Sources/LungfishApp/Views/Metagenomics/EsVirituDetailPane.swift \
        Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift \
        Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift \
        Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift \
        Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift \
        Tests/LungfishAppTests/TaxonomyViewControllerTests.swift
git commit -m "refactor: migrate metagenomics viewers to shared pane layout"
```

## Task 5: Build a shared bottom drawer host

**Files:**
- Create: `Sources/LungfishApp/Views/Layout/DrawerHostState.swift`
- Create: `Sources/LungfishApp/Views/Layout/DrawerHostView.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+FASTQDrawer.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/MetagenomicsDrawerView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/BlastResultsDrawerContainerView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxaCollectionsDrawerView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/SampleFilterDrawerTab.swift`
- Test: `Tests/LungfishAppTests/DrawerHostTests.swift`
- Test: `Tests/LungfishAppTests/BlastResultsDrawerTests.swift`
- Test: `Tests/LungfishAppTests/TaxaCollectionsDrawerTests.swift`
- Test: `Tests/LungfishAppTests/SampleFilterDrawerTests.swift`

- [ ] **Step 1: Write the failing drawer-host tests**

```swift
// Tests/LungfishAppTests/DrawerHostTests.swift
import XCTest
@testable import LungfishApp

final class DrawerHostTests: XCTestCase {
    func testDrawerHostClampsHeightAndPreservesViewportMinimum() {
        let state = DrawerHostState(minimumDrawerHeight: 180, minimumSiblingHeight: 220)
        let resolved = state.clampedHeight(proposed: 760, containerHeight: 800)
        XCTAssertEqual(resolved, 580)
    }

    func testDrawerHostRestoresLastUserHeightWhenReopened() {
        var state = DrawerHostState(minimumDrawerHeight: 180, minimumSiblingHeight: 220)
        state.recordUserHeight(260)
        XCTAssertEqual(state.restoredHeight(defaultHeight: 320), 260)
    }
}
```

- [ ] **Step 2: Run the drawer tests to verify they fail**

Run:

```bash
swift test --filter DrawerHostTests
```

Expected:
- FAIL because `DrawerHostState` does not exist yet

- [ ] **Step 3: Implement the shared drawer host**

```swift
// Sources/LungfishApp/Views/Layout/DrawerHostState.swift
import CoreGraphics

struct DrawerHostState: Equatable {
    let minimumDrawerHeight: CGFloat
    let minimumSiblingHeight: CGFloat
    private(set) var lastUserHeight: CGFloat?

    mutating func recordUserHeight(_ height: CGFloat) {
        lastUserHeight = max(height, minimumDrawerHeight)
    }

    func clampedHeight(proposed: CGFloat, containerHeight: CGFloat) -> CGFloat {
        SplitGeometry.clampedDrawerExtent(
            proposed: proposed,
            containerExtent: containerHeight,
            minimumDrawerExtent: minimumDrawerHeight,
            minimumSiblingExtent: minimumSiblingHeight
        )
    }

    func restoredHeight(defaultHeight: CGFloat) -> CGFloat {
        lastUserHeight ?? defaultHeight
    }
}

// Sources/LungfishApp/Views/Layout/DrawerHostView.swift
import AppKit

@MainActor
final class DrawerHostView: NSView {
    private(set) var state: DrawerHostState
    private weak var embeddedContentView: NSView?

    init(state: DrawerHostState = DrawerHostState(minimumDrawerHeight: 180, minimumSiblingHeight: 220)) {
        self.state = state
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func embed(contentView: NSView) {
        embeddedContentView?.removeFromSuperview()
        embeddedContentView = contentView
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func toggle() {
        isHidden.toggle()
    }
}
```

- [ ] **Step 4: Migrate genomics and metagenomics drawers to the host**

```swift
// Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift
private var annotationDrawerHost: DrawerHostView?

func toggleAnnotationDrawer() {
    if annotationDrawerHost == nil {
        annotationDrawerHost = DrawerHostView()
        annotationDrawerHost?.embed(contentView: annotationDrawerView ?? AnnotationTableDrawerView())
    }
    annotationDrawerHost?.toggle()
}

// Sources/LungfishApp/Views/Metagenomics/MetagenomicsDrawerView.swift
final class MetagenomicsDrawerView: NSView {
    let drawerHost = DrawerHostView()
}
```

- [ ] **Step 5: Run shared and existing drawer tests**

Run:

```bash
swift test --filter DrawerHostTests
swift test --filter BlastResultsDrawerTests
swift test --filter TaxaCollectionsDrawerTests
swift test --filter SampleFilterDrawerTests
```

Expected:
- PASS with shared drawer host tests green
- Existing drawer suites continue to pass using the new host

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Layout/DrawerHostState.swift \
        Sources/LungfishApp/Views/Layout/DrawerHostView.swift \
        Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift \
        Sources/LungfishApp/Views/Viewer/ViewerViewController+FASTQDrawer.swift \
        Sources/LungfishApp/Views/Metagenomics/MetagenomicsDrawerView.swift \
        Sources/LungfishApp/Views/Metagenomics/BlastResultsDrawerContainerView.swift \
        Sources/LungfishApp/Views/Metagenomics/TaxaCollectionsDrawerView.swift \
        Sources/LungfishApp/Views/Metagenomics/SampleFilterDrawerTab.swift \
        Tests/LungfishAppTests/DrawerHostTests.swift \
        Tests/LungfishAppTests/BlastResultsDrawerTests.swift \
        Tests/LungfishAppTests/TaxaCollectionsDrawerTests.swift \
        Tests/LungfishAppTests/SampleFilterDrawerTests.swift
git commit -m "feat: unify bottom drawer layout behavior"
```

## Task 6: Add adoption seams for assembly, alignment, and future viewers

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Alignment/AlignmentResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Results/Taxonomy/TaxonomyResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Test: `Tests/LungfishAppTests/ViewerPaneLayoutCoordinatorTests.swift`

- [ ] **Step 1: Write failing future-adoption tests**

```swift
// Tests/LungfishAppTests/ViewerPaneLayoutCoordinatorTests.swift
@MainActor
func testAssemblyResultCanDeclareListDetailLayoutModes() {
    let controller = AssemblyResultViewController()
    XCTAssertTrue(controller.supportedLayoutModes.contains(.listLeading))
}

@MainActor
func testAlignmentResultCanDeclareListOverDetailLayoutMode() {
    let controller = AlignmentResultViewController()
    XCTAssertTrue(controller.supportedLayoutModes.contains(.listOverDetail))
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run:

```bash
swift test --filter ViewerPaneLayoutCoordinatorTests
```

Expected:
- FAIL because the result controllers do not expose shared viewer-layout metadata yet

- [ ] **Step 3: Add lightweight protocol conformances without changing current UX**

```swift
// Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift
extension AssemblyResultViewController: ViewerLayoutSupporting {
    var supportedLayoutModes: Set<ViewerLayoutMode> { [.listLeading, .detailLeading, .listOverDetail] }
}

// Sources/LungfishApp/Views/Results/Alignment/AlignmentResultViewController.swift
extension AlignmentResultViewController: ViewerLayoutSupporting {
    var supportedLayoutModes: Set<ViewerLayoutMode> { [.listLeading, .detailLeading, .listOverDetail] }
}
```

- [ ] **Step 4: Re-run the targeted viewer-layout tests**

Run:

```bash
swift test --filter ViewerPaneLayoutCoordinatorTests
```

Expected:
- PASS with future-adoption tests green
- No requirement yet to switch the assembly/alignment viewers live in the UI

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Results/Alignment/AlignmentResultViewController.swift \
        Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift \
        Sources/LungfishApp/Views/Results/Taxonomy/TaxonomyResultViewController.swift \
        Sources/LungfishApp/Views/Viewer/ViewerViewController.swift \
        Tests/LungfishAppTests/ViewerPaneLayoutCoordinatorTests.swift
git commit -m "refactor: add generic pane adoption seams"
```

## Task 7: Full verification and cleanup

**Files:**
- Modify: `Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift`
- Modify: `Tests/LungfishAppTests/WorkspaceShellLayoutTests.swift`
- Modify: `Tests/LungfishAppTests/ViewerPaneLayoutCoordinatorTests.swift`
- Modify: `Tests/LungfishAppTests/DrawerHostTests.swift`

- [ ] **Step 1: Add the regression coverage for the known failures from the review**

```swift
// Tests/LungfishAppTests/WorkspaceShellLayoutTests.swift
func testUserDragDecisionNeverRequestsSynchronousShellRestore() {
    let coordinator = WorkspaceShellLayoutCoordinator(
        sidebarMinWidth: 180,
        sidebarMaxWidth: 420,
        inspectorMinWidth: 240,
        inspectorMaxWidth: 450,
        viewerMinWidth: 400
    )

    coordinator.recordUserSidebarWidth(220)
    let decision = coordinator.resizeDecision(
        event: .userDraggedSidebar,
        currentSidebarWidth: 220,
        currentInspectorWidth: 300,
        totalWidth: 1400
    )

    XCTAssertFalse(decision.shouldSetSidebarDividerSynchronously)
}

// Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift
@MainActor
func testTaxonomyControllerDeclaresGenericLayoutModes() {
    let controller = TaxonomyViewController()
    _ = controller.view

    XCTAssertEqual(controller.supportedLayoutModes, [.detailLeading, .listLeading, .listOverDetail])
}
```

- [ ] **Step 2: Run the focused regression suites**

Run:

```bash
swift test --filter WorkspaceShellLayoutTests
swift test --filter ViewerPaneLayoutCoordinatorTests
swift test --filter DrawerHostTests
swift test --filter MetagenomicsLayoutModeTests
```

Expected:
- PASS in all four suites
- No AppKit recursion crash
- TaxTriage warning either removed or documented as the only remaining non-failing issue

- [ ] **Step 3: Run the final app verification**

Run:

```bash
bash scripts/build-app.sh --configuration debug
```

Expected:
- PASS with a fresh debug app at `build/Debug/Lungfish.app`

- [ ] **Step 4: Commit**

```bash
git add Tests/LungfishAppTests/WorkspaceShellLayoutTests.swift \
        Tests/LungfishAppTests/ViewerPaneLayoutCoordinatorTests.swift \
        Tests/LungfishAppTests/DrawerHostTests.swift \
        Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift
git commit -m "test: harden window pane layout regressions"
```

## Manual QA Checklist

- Drag the main left sidebar narrower and wider in Kraken2, NVD, NAO-MGS, EsViritu, TaxTriage, and plain genomics viewer states; verify no snapback.
- Toggle the new left sidebar toolbar button repeatedly and confirm it stays in sync with `View > Hide Sidebar`.
- Resize the right inspector while metagenomics viewers are active; verify the center viewport keeps changing width.
- Switch among `Detail | List`, `List | Detail`, and `List Over Detail` in all metagenomics viewers and verify divider positions persist appropriately.
- Confirm EsViritu and TaxTriage miniBAM detail panes resize to the pane bounds after divider drag release, not only during the drag gesture.
- Confirm NAO-MGS list-over-detail miniBAM spans the visible reference length after pane resize.
- Open and close bottom drawers in genomics, FASTQ, Kraken2, EsViritu, and TaxTriage viewers; verify drawer height persists and viewport minimums are preserved.

## Notes for the Implementer

- Do not call `splitView.setPosition` from `splitViewDidResizeSubviews(_:)`, `viewDidLayout()`, or other active AppKit relayout callbacks. Schedule reconciliation after the layout turn if a divider move is still required.
- Keep all new type names generic. Avoid `Metagenomics` in shared abstractions.
- Prefer adapter-style migrations. The result controllers should own content; the new layout framework should own geometry.
- Preserve existing viewer-specific business logic such as BLAST workflows and sample filtering. This project is layout hardening, not feature redesign.
