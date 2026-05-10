# Metagenomics UI Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the metagenomics drawer/layout limits, add the new stacked classifier layout, refresh first-run tool/database readiness in place, and fix the EsViritu unique-read overcount bug without pulling the deferred Kraken2 BLAST-refresh issue into scope.

**Architecture:** Add two small shared App-layer helpers: one for persisted metagenomics layout preference and one for clamping drawer/split positions. Then wire the metagenomics controllers, welcome/setup flow, plugin manager, and wizard sheets onto those helpers and a new managed-resource refresh notification. Finish with a localized EsViritu aggregation fix and narrow regression tests.

**Tech Stack:** Swift, AppKit, SwiftUI, XCTest, NotificationCenter, UserDefaults

---

## File Structure

### New Files

- `Sources/LungfishApp/Views/Metagenomics/MetagenomicsLayoutPreference.swift`
  - Stores the enum-backed `detailLeading` / `listLeading` / `stacked` preference, migrates from `metagenomicsTableOnLeft`, and centralizes write/post behavior.
- `Sources/LungfishApp/Views/Metagenomics/MetagenomicsPaneSizing.swift`
  - Pure clamp helpers for drawer heights and split positions, leaving a minimum visible sibling strip.
- `Sources/LungfishApp/Views/Metagenomics/BlastResultsDrawerContainerView.swift`
  - Shared resizable wrapper for BLAST-only drawers used by EsViritu, NVD, and NAO-MGS.
- `Tests/LungfishAppTests/MetagenomicsLayoutPreferenceTests.swift`
  - Covers legacy-bool migration and persisted enum behavior.
- `Tests/LungfishAppTests/MetagenomicsPaneSizingTests.swift`
  - Covers drawer/split clamp math.
- `Tests/LungfishAppTests/ManagedResourceRefreshTests.swift`
  - Covers the new `.managedResourcesDidChange` notification producers/observers that are hard to express in the existing test files.
- `Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift`
  - Covers stacked/list/detail layout application and BLAST-drawer container wiring.

### Existing Files To Modify

- `Sources/LungfishCore/Models/Notifications.swift`
  - Add `.managedResourcesDidChange`.
- `Sources/LungfishCore/Models/AppSettings.swift`
  - Post `.managedResourcesDidChange` whenever managed database storage location changes.
- `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
  - Replace the boolean layout state with the enum-backed layout preference.
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
  - Replace the two-choice layout radio group with three choices and persist via the helper.
- `Sources/LungfishApp/Views/Viewer/MultiSequenceSupport.swift`
  - Keep `.metagenomicsLayoutSwapRequested` but update comments/usage to mean “layout preference changed”.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift`
  - Replace the `70%` cap with shared clamp logic.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+FASTQDrawer.swift`
  - Replace the `70%` cap with shared clamp logic.
- `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController+Collections.swift`
  - Replace the `50%` cap with shared clamp logic.
- `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
  - Apply all three layout modes and use shared split clamping.
- `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
  - Apply all three layout modes, replace the fixed-height BLAST drawer with the new container, and fix the batch unique-read mapping.
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
  - Apply all three layout modes and use shared split clamping.
- `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
  - Apply all three layout modes, replace the fixed-height BLAST drawer, and use shared split clamping.
- `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
  - Apply all three layout modes, replace the fixed-height BLAST drawer, and use shared split clamping.
- `Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift`
  - Observe `.managedResourcesDidChange` and rerun `loadDatabases()`.
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift`
  - Observe `.managedResourcesDidChange` and rerun `checkPrerequisites()`.
- `Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift`
  - Observe `.managedResourcesDidChange` and rerun `checkDatabaseStatus()`.
- `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift`
  - Post `.managedResourcesDidChange` after successful pack install/remove, DB download/remove, and storage-location change.
- `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
  - Refresh required-setup state when `.managedResourcesDidChange` arrives.
- `Sources/LungfishApp/Views/Metagenomics/ViralDetectionTableView.swift`
  - Keep assembly-level and contig-level unique-read display logic separate.
- `Tests/LungfishAppTests/TaxonomyViewControllerTests.swift`
  - Add layout-mode coverage for stacked/top-bottom arrangement.
- `Tests/LungfishAppTests/TaxaCollectionsDrawerTests.swift`
  - Update drawer-limit expectations to the new minimum-visible-host model.
- `Tests/LungfishAppTests/ClassificationWizardTests.swift`
  - Add regression coverage for ready-database selection helper behavior after refresh.
- `Tests/LungfishAppTests/DatabasesTabTests.swift`
  - Add managed-resource notification coverage for successful DB download/remove.
- `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`
  - Add managed-resource notification coverage for successful pack install/remove.
- `Tests/LungfishAppTests/WelcomeSetupTests.swift`
  - Add refresh-on-managed-resource-change coverage.
- `Tests/LungfishAppTests/BatchAggregatedViewTests.swift`
  - Add EsViritu batch unique-read regression coverage.

## Task 1: Add The Enum-Backed Metagenomics Layout Preference

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/MetagenomicsLayoutPreference.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/MultiSequenceSupport.swift`
- Test: `Tests/LungfishAppTests/MetagenomicsLayoutPreferenceTests.swift`

- [ ] **Step 1: Write the failing layout-preference migration tests**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class MetagenomicsLayoutPreferenceTests: XCTestCase {
    func testCurrentLayoutFallsBackToLegacyBoolWhenEnumKeyIsMissing() {
        let suite = "layout-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)

        XCTAssertEqual(
            MetagenomicsPanelLayout.current(defaults: defaults),
            .listLeading
        )
    }

    func testPersistWritesEnumRawValueAndPostsLayoutChangeNotification() {
        let suite = "layout-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let center = NotificationCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        let exp = expectation(
            forNotification: .metagenomicsLayoutSwapRequested,
            object: nil,
            handler: nil
        )

        MetagenomicsPanelLayout.stacked.persist(
            defaults: defaults,
            notificationCenter: center
        )

        wait(for: [exp], timeout: 0.2)
        XCTAssertEqual(
            defaults.string(forKey: MetagenomicsPanelLayout.defaultsKey),
            MetagenomicsPanelLayout.stacked.rawValue
        )
    }
}
```

- [ ] **Step 2: Run the new layout-preference tests and verify they fail**

Run: `swift test --filter MetagenomicsLayoutPreferenceTests`

Expected: FAIL with missing `MetagenomicsPanelLayout`, missing `defaultsKey`, and no `persist(defaults:notificationCenter:)` API.

- [ ] **Step 3: Implement the shared layout-preference helper**

```swift
import Foundation

@MainActor
enum MetagenomicsPanelLayout: String, CaseIterable, Sendable {
    case detailLeading
    case listLeading
    case stacked

    static let defaultsKey = "metagenomicsPanelLayout"
    static let legacyTableOnLeftKey = "metagenomicsTableOnLeft"

    static func current(defaults: UserDefaults = .standard) -> Self {
        if let raw = defaults.string(forKey: defaultsKey),
           let value = Self(rawValue: raw) {
            return value
        }
        return defaults.bool(forKey: legacyTableOnLeftKey) ? .listLeading : .detailLeading
    }

    func persist(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
        notificationCenter.post(name: .metagenomicsLayoutSwapRequested, object: nil)
    }
}
```

- [ ] **Step 4: Update the inspector and document section to use the enum**

```swift
// DocumentSection.swift
var metagenomicsPanelLayout: MetagenomicsPanelLayout = .current()

// InspectorViewController.swift
Picker("Layout", selection: Binding(
    get: { viewModel.metagenomicsPanelLayout },
    set: { newValue in
        viewModel.metagenomicsPanelLayout = newValue
        newValue.persist()
    }
)) {
    Label("Detail | List", systemImage: "sidebar.left").tag(MetagenomicsPanelLayout.detailLeading)
    Label("List | Detail", systemImage: "sidebar.right").tag(MetagenomicsPanelLayout.listLeading)
    Label("List Over Detail", systemImage: "rectangle.split.1x2").tag(MetagenomicsPanelLayout.stacked)
}
.pickerStyle(.radioGroup)
```

- [ ] **Step 5: Re-run the layout-preference tests**

Run: `swift test --filter MetagenomicsLayoutPreferenceTests`

Expected: PASS with the enum migration and persistence behavior covered.

- [ ] **Step 6: Commit the layout-preference helper**

```bash
git add Sources/LungfishApp/Views/Metagenomics/MetagenomicsLayoutPreference.swift \
        Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift \
        Sources/LungfishApp/Views/Inspector/InspectorViewController.swift \
        Sources/LungfishApp/Views/Viewer/MultiSequenceSupport.swift \
        Tests/LungfishAppTests/MetagenomicsLayoutPreferenceTests.swift
git commit -m "feat: add metagenomics layout preference model"
```

## Task 2: Add Shared Pane-Sizing Helpers And Remove The Hard Caps

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/MetagenomicsPaneSizing.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+FASTQDrawer.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController+Collections.swift`
- Test: `Tests/LungfishAppTests/MetagenomicsPaneSizingTests.swift`
- Test: `Tests/LungfishAppTests/TaxaCollectionsDrawerTests.swift`

- [ ] **Step 1: Write the failing clamp-logic tests**

```swift
import XCTest
@testable import LungfishApp

final class MetagenomicsPaneSizingTests: XCTestCase {
    func testClampedDrawerExtentLeavesVisibleHostStrip() {
        let height = MetagenomicsPaneSizing.clampedDrawerExtent(
            proposed: 960,
            containerExtent: 1000,
            minimumDrawerExtent: 140,
            minimumSiblingExtent: 120
        )

        XCTAssertEqual(height, 880)
    }

    func testClampedDrawerExtentHonorsMinimumDrawerHeight() {
        let height = MetagenomicsPaneSizing.clampedDrawerExtent(
            proposed: 50,
            containerExtent: 1000,
            minimumDrawerExtent: 140,
            minimumSiblingExtent: 120
        )

        XCTAssertEqual(height, 140)
    }

    func testClampedDividerPositionLeavesVisibleTrailingPane() {
        let position = MetagenomicsPaneSizing.clampedDividerPosition(
            proposed: 980,
            containerExtent: 1000,
            minimumLeadingExtent: 120,
            minimumTrailingExtent: 120
        )

        XCTAssertEqual(position, 880)
    }
}
```

- [ ] **Step 2: Run the sizing tests and verify they fail**

Run: `swift test --filter 'MetagenomicsPaneSizingTests|TaxaCollectionsDrawerTests'`

Expected: FAIL with missing `MetagenomicsPaneSizing` APIs and the old `maxTaxaDrawerFraction` expectation still present in `TaxaCollectionsDrawerTests`.

- [ ] **Step 3: Implement the shared clamp helper**

```swift
import CoreGraphics

enum MetagenomicsPaneSizing {
    static func clampedDrawerExtent(
        proposed: CGFloat,
        containerExtent: CGFloat,
        minimumDrawerExtent: CGFloat,
        minimumSiblingExtent: CGFloat
    ) -> CGFloat {
        let maximumDrawerExtent = max(minimumDrawerExtent, containerExtent - minimumSiblingExtent)
        return min(max(proposed, minimumDrawerExtent), maximumDrawerExtent)
    }

    static func clampedDividerPosition(
        proposed: CGFloat,
        containerExtent: CGFloat,
        minimumLeadingExtent: CGFloat,
        minimumTrailingExtent: CGFloat
    ) -> CGFloat {
        let minimum = minimumLeadingExtent
        let maximum = max(minimum, containerExtent - minimumTrailingExtent)
        return min(max(proposed, minimum), maximum)
    }
}
```

- [ ] **Step 4: Replace the percentage caps with the helper**

```swift
// TaxonomyViewController+Collections.swift
let proposedHeight = taxaCollectionsDrawerHeightConstraint.constant - deltaY
taxaCollectionsDrawerHeightConstraint.constant = MetagenomicsPaneSizing.clampedDrawerExtent(
    proposed: proposedHeight,
    containerExtent: view.bounds.height,
    minimumDrawerExtent: Self.minTaxaDrawerHeight,
    minimumSiblingExtent: Self.minVisibleViewportHeight
)

// ViewerViewController+AnnotationDrawer.swift / FASTQDrawer.swift
let proposed = currentDrawerHeight - deltaY
drawerHeightConstraint.constant = MetagenomicsPaneSizing.clampedDrawerExtent(
    proposed: proposed,
    containerExtent: view.bounds.height,
    minimumDrawerExtent: minimumDrawerHeight,
    minimumSiblingExtent: minimumVisibleViewportHeight
)
```

- [ ] **Step 5: Re-run the clamp and drawer tests**

Run: `swift test --filter 'MetagenomicsPaneSizingTests|TaxaCollectionsDrawerTests'`

Expected: PASS with the new clamp math and updated drawer-limit expectations.

- [ ] **Step 6: Commit the shared clamp logic**

```bash
git add Sources/LungfishApp/Views/Metagenomics/MetagenomicsPaneSizing.swift \
        Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift \
        Sources/LungfishApp/Views/Viewer/ViewerViewController+FASTQDrawer.swift \
        Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController+Collections.swift \
        Tests/LungfishAppTests/MetagenomicsPaneSizingTests.swift \
        Tests/LungfishAppTests/TaxaCollectionsDrawerTests.swift
git commit -m "feat: relax metagenomics drawer size limits"
```

## Task 3: Apply The Three Layout Modes And Replace Fixed BLAST Drawers

**Files:**
- Create: `Sources/LungfishApp/Views/Metagenomics/BlastResultsDrawerContainerView.swift`
- Create: `Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
- Test: `Tests/LungfishAppTests/TaxonomyViewControllerTests.swift`
- Test: `Tests/LungfishAppTests/BatchAggregatedViewTests.swift`
- Test: `Tests/LungfishAppTests/BlastResultsDrawerTests.swift`

- [ ] **Step 1: Write the failing controller-layout tests**

```swift
@MainActor
final class MetagenomicsLayoutModeTests: XCTestCase {
    func testTaxonomyViewAppliesStackedLayoutWithTableAboveSunburst() {
        MetagenomicsPanelLayout.stacked.persist()

        let vc = TaxonomyViewController()
        vc.loadViewIfNeeded()
        vc.testApplyLayoutPreference()

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testTopPane.subviews.contains(vc.testTableView))
        XCTAssertTrue(vc.testBottomPane.subviews.contains(vc.testSunburstView))
    }

    func testEsVirituBlastDrawerUsesResizableContainerInsteadOfFixedHeightTab() {
        let vc = EsVirituResultViewController()
        vc.loadViewIfNeeded()
        vc.testEnsureBlastDrawer()

        XCTAssertNotNil(vc.testBlastDrawerContainer)
        XCTAssertNotNil(vc.testBlastDrawerContainer?.dividerView.superview)
    }
}
```

- [ ] **Step 2: Run the metagenomics controller tests and verify they fail**

Run: `swift test --filter 'MetagenomicsLayoutModeTests|TaxonomyViewControllerTests|BatchAggregatedViewTests|BlastResultsDrawerTests'`

Expected: FAIL because the controllers still read `metagenomicsTableOnLeft`, stacked mode does not exist, and EsViritu/NVD/NAO-MGS still create fixed-height `BlastResultsDrawerTab` instances directly.

- [ ] **Step 3: Implement the resizable BLAST drawer container and three-mode layout switch**

```swift
@MainActor
final class BlastResultsDrawerContainerView: NSView {
    let dividerView = MetagenomicsDividerView()
    let resultsView = BlastResultsDrawerTab()
}

private func applyLayoutPreference() {
    switch MetagenomicsPanelLayout.current() {
    case .detailLeading:
        applyHorizontalLayout(tableFirst: false)
    case .listLeading:
        applyHorizontalLayout(tableFirst: true)
    case .stacked:
        applyStackedLayout(listOnTop: true)
    }
}

// TaxonomyViewController.swift / EsVirituResultViewController.swift
func testApplyLayoutPreference() { applyLayoutPreference() }
var testTopPane: NSView { splitView.arrangedSubviews[0] }
var testBottomPane: NSView { splitView.arrangedSubviews[1] }
func testEnsureBlastDrawer() { _ = ensureBlastDrawer() }
var testBlastDrawerContainer: BlastResultsDrawerContainerView? { blastDrawerContainer }
```

- [ ] **Step 4: Wire the split delegates and fixed BLAST drawers onto the shared helpers**

```swift
override func splitView(
    _ splitView: NSSplitView,
    constrainMinCoordinate proposedMinimumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
) -> CGFloat {
    MetagenomicsPaneSizing.clampedDividerPosition(
        proposed: proposedMinimumPosition,
        containerExtent: splitView.bounds.width,
        minimumLeadingExtent: Self.minimumLeadingPaneWidth,
        minimumTrailingExtent: Self.minimumTrailingPaneWidth
    )
}

private func ensureBlastDrawer() -> BlastResultsDrawerContainerView {
    if let existing = blastDrawerContainer { return existing }
    let container = BlastResultsDrawerContainerView()
    container.resultsView.onRerun = { [weak self] in self?.rerunBlast() }
    blastDrawerContainer = container
    return container
}
```

- [ ] **Step 5: Run the controller tests, then do the manual AppKit verification**

Run: `swift test --filter 'MetagenomicsLayoutModeTests|TaxonomyViewControllerTests|BatchAggregatedViewTests|BlastResultsDrawerTests'`

Expected: PASS for the new layout-mode and drawer-container tests.

Manual check:

```bash
open .build/debug/Lungfish.app
```

Expected:
- `Detail | List`, `List | Detail`, and `List Over Detail` all reflow correctly in classifier views.
- In stacked mode, the list sits above the detail pane and the drawer remains bottom-most where present.
- BLAST drawers in EsViritu, NVD, and NAO-MGS can be dragged near full height and then dragged back.

- [ ] **Step 6: Commit the layout-mode and BLAST-drawer work**

```bash
git add Sources/LungfishApp/Views/Metagenomics/BlastResultsDrawerContainerView.swift \
        Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift \
        Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift \
        Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift \
        Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift \
        Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift \
        Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift \
        Tests/LungfishAppTests/TaxonomyViewControllerTests.swift \
        Tests/LungfishAppTests/BatchAggregatedViewTests.swift \
        Tests/LungfishAppTests/BlastResultsDrawerTests.swift
git commit -m "feat: add stacked metagenomics layout and resizable blast drawers"
```

## Task 4: Broadcast Managed-Resource Changes And Refresh Open Surfaces

**Files:**
- Modify: `Sources/LungfishCore/Models/Notifications.swift`
- Modify: `Sources/LungfishCore/Models/AppSettings.swift`
- Modify: `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift`
- Modify: `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift`
- Create: `Tests/LungfishAppTests/ManagedResourceRefreshTests.swift`
- Modify: `Tests/LungfishAppTests/DatabasesTabTests.swift`
- Modify: `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`
- Modify: `Tests/LungfishAppTests/WelcomeSetupTests.swift`

- [ ] **Step 1: Write the failing notification and welcome-refresh tests**

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class ManagedResourceRefreshTests: XCTestCase {
    private actor StubPackProvider: PluginPackStatusProviding {
        let statuses: [PluginPackStatus]

        init(statuses: [PluginPackStatus]) {
            self.statuses = statuses
        }

        func visibleStatuses() async -> [PluginPackStatus] { statuses }
        func status(for pack: PluginPack) async -> PluginPackStatus {
            statuses.first(where: { $0.pack.id == pack.id })!
        }
        func invalidateVisibleStatusesCache() async {}
        func install(
            pack: PluginPack,
            reinstall: Bool,
            progress: (@Sendable (PluginPackInstallProgress) -> Void)?
        ) async throws {
            progress?(PluginPackInstallProgress(
                requirementID: nil,
                requirementDisplayName: nil,
                overallFraction: 1.0,
                itemFraction: 1.0,
                message: "Installed"
            ))
        }
    }

    private final class StatefulProvider: @unchecked Sendable, PluginPackStatusProviding {
        let initialStatuses: [PluginPackStatus]
        let refreshedStatuses: [PluginPackStatus]
        private let lock = NSLock()
        private var callCount = 0
        private var continuation: CheckedContinuation<[PluginPackStatus], Never>?

        init(initialStatuses: [PluginPackStatus], refreshedStatuses: [PluginPackStatus]) {
            self.initialStatuses = initialStatuses
            self.refreshedStatuses = refreshedStatuses
        }

        func visibleStatuses() async -> [PluginPackStatus] {
            lock.lock()
            callCount += 1
            let count = callCount
            lock.unlock()
            if count == 1 { return initialStatuses }
            return await withCheckedContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
            }
        }

        func status(for pack: PluginPack) async -> PluginPackStatus {
            refreshedStatuses.first(where: { $0.pack.id == pack.id })
                ?? initialStatuses.first(where: { $0.pack.id == pack.id })!
        }

        func invalidateVisibleStatusesCache() async {}
        func install(pack: PluginPack, reinstall: Bool, progress: (@Sendable (PluginPackInstallProgress) -> Void)?) async throws {}

        func release() {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: refreshedStatuses)
        }
    }

    func testInstallPackPostsManagedResourcesDidChange() async throws {
        let center = NotificationCenter()
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let provider = StubPackProvider(statuses: [required])
        let viewModel = PluginManagerViewModel(
            packStatusProvider: provider,
            notificationCenter: center
        )

        let exp = expectation(forNotification: .managedResourcesDidChange, object: nil)
        viewModel.installPack(.requiredSetupPack)
        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testWelcomeViewModelRefreshesWhenManagedResourcesChange() async {
        let center = NotificationCenter()
        let ready = PluginPackStatus(pack: .requiredSetupPack, state: .ready, toolStatuses: [], failureMessage: nil)
        let missing = PluginPackStatus(pack: .requiredSetupPack, state: .needsInstall, toolStatuses: [], failureMessage: nil)
        let provider = StatefulProvider(
            initialStatuses: [missing],
            refreshedStatuses: [ready]
        )

        let viewModel = WelcomeViewModel(
            statusProvider: provider,
            notificationCenter: center
        )
        await viewModel.refreshSetup()
        center.post(name: .managedResourcesDidChange, object: nil)
        await Task.yield()
        provider.release()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(viewModel.requiredSetupStatus?.state, .ready)
    }
}
```

- [ ] **Step 2: Run the notification tests and verify they fail**

Run: `swift test --filter 'ManagedResourceRefreshTests|PluginPackVisibilityTests|DatabasesTabTests|WelcomeSetupTests'`

Expected: FAIL because `.managedResourcesDidChange` does not exist, `PluginManagerViewModel` does not post it, and `WelcomeViewModel` does not observe it.

- [ ] **Step 3: Add the shared notification and post it from successful install/remove flows**

```swift
// Notifications.swift
public static let managedResourcesDidChange = Notification.Name("managedResourcesDidChange")

// PluginManagerViewModel.swift
private let notificationCenter: NotificationCenter

init(
    packStatusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared,
    notificationCenter: NotificationCenter = .default
) {
    self.packStatusProvider = packStatusProvider
    self.notificationCenter = notificationCenter
    refreshInstalled()
    refreshPackStatuses()
}

private func postManagedResourceRefresh() {
    notificationCenter.post(name: .managedResourcesDidChange, object: nil)
}
```

- [ ] **Step 4: Refresh the welcome/setup view model and the wizard sheets when the notification arrives**

```swift
// WelcomeWindowController.swift
init(
    statusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared,
    notificationCenter: NotificationCenter = .default
) {
    self.viewModel = WelcomeViewModel(statusProvider: statusProvider, notificationCenter: notificationCenter)
}

// WelcomeViewModel
notificationCenter.addObserver(
    forName: .managedResourcesDidChange,
    object: nil,
    queue: .main
) { [weak self] _ in
    Task { await self?.refreshSetup() }
}

// ClassificationWizardSheet.swift
.onReceive(NotificationCenter.default.publisher(for: .managedResourcesDidChange)) { _ in
    Task { await loadDatabases() }
}

// TaxTriageWizardSheet.swift / EsVirituWizardSheet.swift
.onReceive(NotificationCenter.default.publisher(for: .managedResourcesDidChange)) { _ in
    checkPrerequisites() // TaxTriage
    checkDatabaseStatus() // EsViritu
}
```

- [ ] **Step 5: Re-run the notification tests, then manually verify the live refresh flows**

Run: `swift test --filter 'ManagedResourceRefreshTests|PluginPackVisibilityTests|DatabasesTabTests|WelcomeSetupTests'`

Expected: PASS with pack/install/remove notification coverage and welcome refresh coverage.

Manual check:

```bash
open .build/debug/Lungfish.app
```

Expected:
- Required setup turns green in the welcome/setup flow immediately after install completes.
- A still-open Kraken2 or EsViritu wizard updates its database readiness without being closed and reopened.
- Downloading/removing a database from Plugin Manager updates any still-open wizard state.

- [ ] **Step 6: Commit the managed-resource refresh work**

```bash
git add Sources/LungfishCore/Models/Notifications.swift \
        Sources/LungfishCore/Models/AppSettings.swift \
        Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift \
        Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift \
        Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift \
        Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift \
        Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift \
        Tests/LungfishAppTests/ManagedResourceRefreshTests.swift \
        Tests/LungfishAppTests/DatabasesTabTests.swift \
        Tests/LungfishAppTests/PluginPackVisibilityTests.swift \
        Tests/LungfishAppTests/WelcomeSetupTests.swift
git commit -m "fix: refresh managed resource readiness in open views"
```

## Task 5: Fix The EsViritu Unique-Read Overcount

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/ViralDetectionTableView.swift`
- Modify: `Tests/LungfishAppTests/BatchAggregatedViewTests.swift`

- [ ] **Step 1: Write the failing EsViritu regression tests**

```swift
@MainActor
func testBuildBatchUniqueReadMapsDoesNotSeedPerContigValuesFromAssemblyTotals() {
    let rows = [
        BatchEsVirituRow(
            sample: "SRR14420360",
            virusName: "Segmented virus",
            family: "Viridae",
            assembly: "ASM1",
            readCount: 100,
            uniqueReads: 80,
            rpkmf: 1.0,
            coverageBreadth: 0.5,
            coverageDepth: 2.0
        )
    ]
    let maps = EsVirituResultViewController.buildBatchUniqueReadMaps(
        rows: rows,
        selectedSamples: Set(["SRR14420360"])
    )

    XCTAssertEqual(maps.bySampleAssembly["SRR14420360\tASM1"], 80)
    XCTAssertTrue(maps.bySampleContig.isEmpty)
}
```

- [ ] **Step 2: Run the EsViritu batch tests and verify they fail**

Run: `swift test --filter BatchAggregatedViewTests`

Expected: FAIL because `applyBatchSampleFilter()` currently seeds each contig with the full assembly-level unique-read count.

- [ ] **Step 3: Remove the bad per-contig seeding and keep assembly/contig display separate**

```swift
// EsVirituResultViewController.swift
struct BatchUniqueReadMaps {
    let byAssembly: [String: Int]
    let bySampleAssembly: [String: Int]
    let bySampleContig: [String: Int]
}

static func buildBatchUniqueReadMaps(
    rows: [BatchEsVirituRow],
    selectedSamples: Set<String>
) -> BatchUniqueReadMaps {
    var byAssembly: [String: Int] = [:]
    var bySampleAssembly: [String: Int] = [:]

    for row in rows where selectedSamples.contains(row.sample) {
        byAssembly[row.assembly] = row.uniqueReads
        bySampleAssembly["\(row.sample)\t\(row.assembly)"] = row.uniqueReads
    }

    return BatchUniqueReadMaps(
        byAssembly: byAssembly,
        bySampleAssembly: bySampleAssembly,
        bySampleContig: [:]
    )
}

let maps = Self.buildBatchUniqueReadMaps(
    rows: allBatchRows,
    selectedSamples: selectedSet
)

// ViralDetectionTableView.swift
if let unique = uniqueReadCountsBySampleContig["\(detection.sampleId)\t\(detection.accession)"] {
    cell.textField?.stringValue = "\(unique)"
} else {
    cell.textField?.stringValue = "…"
}
```

- [ ] **Step 4: Re-run the EsViritu batch tests**

Run: `swift test --filter BatchAggregatedViewTests`

Expected: PASS with the per-contig map left empty until real contig-level counts exist.

- [ ] **Step 5: Manually verify the `SRR14420360` regression shape**

```bash
open .build/debug/Lungfish.app
```

Expected:
- Batch EsViritu results for segmented assemblies no longer show `Unique Reads` exceeding `Total Reads`.
- Assembly rows still show the assembly-level unique-read total.
- Contig rows show `…` until a real contig-level unique-read value is computed.

- [ ] **Step 6: Commit the EsViritu regression fix**

```bash
git add Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift \
        Sources/LungfishApp/Views/Metagenomics/ViralDetectionTableView.swift \
        Tests/LungfishAppTests/BatchAggregatedViewTests.swift
git commit -m "fix: stop duplicating esviritu unique read totals"
```

## Self-Review Checklist

- Spec coverage:
  - Drawer/split expansion with recoverability: Tasks 2 and 3
  - Top/bottom `List Over Detail` mode: Tasks 1 and 3
  - Immediate tool/database readiness refresh: Task 4
  - EsViritu overcount fix: Task 5
  - Deferred Kraken2 BLAST issue remains out of scope throughout the plan
- Placeholder scan:
  - No `TODO`/`TBD`
  - Every task includes explicit files, commands, and code seams
- Type consistency:
  - `MetagenomicsPanelLayout` is the single layout enum
  - `.managedResourcesDidChange` is the single broad refresh notification
  - `BlastResultsDrawerContainerView` is the shared BLAST-only drawer wrapper
