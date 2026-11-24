// ViewSwitchViewStateDrivers+Inspector.swift - The Inspector keeps its tab and subsection per item, and Reset View (VS-INSP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each case picks a tab or a subsection as the Inspector's own control does (the tab grid and the subsection grid write
// the model's bindings, `InspectorView.swift`), switches to another kind and back or relaunches on the same store, and
// reads what the control shows. Reset View runs through the View menu's action with the window as its sender, as a click
// on the item does. Every window keeps its views in a store under the test's own folder (QA 6).

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishGenotypeUI
@testable import LungfishKit
import LungfishTestSupport

/// An Inspector tab a kind offers that is not the tab its content opens on.
struct InspectorTabCase {
    let driver: any ViewStateDriver
    let tab: InspectorTab
}

extension ViewSwitchViewStateTests {
    /// One case for each tab a person can pick away from the content's own tab, on the kinds that offer it.
    static var inspectorTabCases: [InspectorTabCase] {
        [
            InspectorTabCase(driver: ReferenceViewStateDriver(route: .reference), tab: .view),
            InspectorTabCase(driver: ReferenceViewStateDriver(route: .reference), tab: .analysis),
            InspectorTabCase(driver: ReferenceViewStateDriver(route: .reference), tab: .provenance),
            InspectorTabCase(driver: ReferenceViewStateDriver(route: .mapping), tab: .view),
            InspectorTabCase(driver: GenotypeViewStateDriver(), tab: .annotations),
            InspectorTabCase(driver: GenotypeViewStateDriver(), tab: .view),
        ]
    }

    /// The tab the Inspector's tab control shows, which its selection binding reads from the model.
    func shownTab(in harness: ViewSwitchWindowHarness) -> InspectorTab {
        harness.split.inspectorController.viewModel.selectedTab
    }

    /// Picks a tab as a click on the Inspector's tab control does, through the binding the control writes.
    func pick(_ tab: InspectorTab, in harness: ViewSwitchWindowHarness) {
        harness.split.inspectorController.viewModel.selectedTab = tab
    }

    /// Shows a kind built after the case's own fixtures, such as a second kind to switch to.
    func showBuilt(_ kind: String, in harness: ViewSwitchWindowHarness, driver: any ViewStateDriver) async throws {
        let fixture = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: kind), in: project)
        try await show(fixture, in: harness, driver: driver)
    }

    // MARK: - The tab (VS U7)

    func testInspectorTabsKeepThroughASwitch() async throws {
        // Each kind and the kind to switch to are built once in the project.
        var built: [String: ViewSwitchFixture] = [:]
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        for tabCase in Self.inspectorTabCases {
            let driver = tabCase.driver
            if built[driver.kind] == nil {
                let fixture = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: driver.kind), in: project)
                try driver.prepare(fixture)
                built[driver.kind] = fixture
            }
            let fixture = try XCTUnwrap(built[driver.kind])
            let harness = try ViewSwitchWindowHarness()
            defer { harness.close() }
            harness.keepViews(in: loadedStore())
            try await show(fixture, in: harness, driver: driver)
            let model = harness.split.inspectorController.viewModel
            XCTAssertTrue(model.availableTabs.contains(tabCase.tab), "\(driver.kind) offers \(tabCase.tab.rawValue)")
            XCTAssertNotEqual(shownTab(in: harness), tabCase.tab, "\(driver.kind): the content opens on another tab")
            pick(tabCase.tab, in: harness)

            try await leave(for: other, in: harness, driver: driver)
            try await show(fixture, in: harness, driver: driver)
            let kept = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
                self.shownTab(in: harness) == tabCase.tab
            }
            XCTAssertTrue(kept, "\(driver.kind): the \(tabCase.tab.rawValue) tab as left, not \(shownTab(in: harness).rawValue)")
        }
    }

    func testInspectorTabKeepsThroughARelaunch() async throws {
        let driver = ReferenceViewStateDriver(route: .reference)
        let (fixture, _) = try await fixtures(for: driver)
        do {
            let store = loadedStore()
            let harness = try ViewSwitchWindowHarness()
            harness.keepViews(in: store)
            try await show(fixture, in: harness, driver: driver)
            pick(.provenance, in: harness)
            // The quit keeps the installed view with no switch and writes the store (VS S1).
            harness.split.viewerController.surfaceHost.captureActive()
            store.flushSynchronously()
            harness.close()
        }
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let kept = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            self.shownTab(in: harness) == .provenance
        }
        XCTAssertTrue(kept, "the item's entry wins at the relaunch, not \(shownTab(in: harness).rawValue)")
    }

    /// A tab picked on one item is that item's: another item with no entry opens on the tab its content sets, so the
    /// tab no longer carries over a switch (the matrix's INSPECTOR-STALE tab rows).
    func testInspectorTabOfAnotherItemIsTheTabItsContentOpensOn() async throws {
        let driver = ReferenceViewStateDriver(route: .reference)
        let (fixture, _) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        pick(.view, in: harness)
        try await showBuilt("Mapping result", in: harness, driver: ReferenceViewStateDriver(route: .mapping))
        XCTAssertEqual(shownTab(in: harness), .bundle, "the mapping result opens on its content's tab")
    }

    /// A Selected Item tab whose selection was not kept opens the tab the content sets, with no line (VS U7).
    func testInspectorSelectedItemTabWithNoSelectionOpensTheContentsTab() async throws {
        let driver = ReferenceViewStateDriver(route: .reference)
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        pick(.selectedItem, in: harness)
        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(shownTab(in: harness), .bundle)
        XCTAssertNil(driver.resetLineWords(in: harness))
    }

    // MARK: - The read style subsection

    func testInspectorReadStyleSubsectionKeepsThroughARelaunchAndStartsAtItsDefaultOnAnotherItem() async throws {
        let driver = ReferenceViewStateDriver(route: .mapping)
        let (fixture, _) = try await fixtures(for: driver)
        let picked = try XCTUnwrap(ReadStyleViewSubsection.allCases.first { $0 != .alignment })
        do {
            let store = loadedStore()
            let harness = try ViewSwitchWindowHarness()
            harness.keepViews(in: store)
            try await show(fixture, in: harness, driver: driver)
            XCTAssertEqual(harness.split.inspectorController.viewModel.selectedReadStyleViewSubsection, .alignment)
            harness.split.inspectorController.viewModel.selectedReadStyleViewSubsection = picked
            harness.split.viewerController.surfaceHost.captureActive()
            store.flushSynchronously()
            harness.close()
        }
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let model = harness.split.inspectorController.viewModel
        let kept = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            model.selectedReadStyleViewSubsection == picked
        }
        XCTAssertTrue(kept, "the subsection as left before the relaunch")
        try await showBuilt("Reference", in: harness, driver: ReferenceViewStateDriver(route: .reference))
        XCTAssertEqual(model.selectedReadStyleViewSubsection, .alignment, "another item starts at the default")
    }

    // MARK: - Reset View (VS U3)

    /// Runs View > Reset View as a click on the item does, with a view of the window as the sender, and puts the app's
    /// saved settings back as they were, since the base's item saved them.
    func chooseResetView(in harness: ViewSwitchWindowHarness) {
        let preferences = LungfishAppIdentity.current.preferences
        let saved = preferences.object(forKey: "com.lungfish.appSettings")
        let appearance = AppSettings.shared.sequenceAppearance
        defer {
            if let saved { preferences.set(saved, forKey: "com.lungfish.appSettings") }
            else { preferences.removeObject(forKey: "com.lungfish.appSettings") }
            AppSettings.shared.sequenceAppearance = appearance
        }
        AppDelegate().resetViewSettingsToDefaults(harness.split.viewerController.view)
    }

    /// Reset View returns this view to its starting view and leaves the app-wide look, which only the Appearance
    /// section's Reset changes (VS U3).
    func testResetViewReturnsTheReferenceToItsStartAndLeavesTheAppWideLook() async throws {
        let driver = ReferenceViewStateDriver(route: .reference)
        let (fixture, _) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let start = try driver.read(in: harness)
        try await driver.change(in: harness)
        XCTAssertNotEqual(try driver.read(in: harness), start)
        let appearance = harness.split.inspectorController.viewModel.appearanceSectionViewModel
        appearance.trackHeight = 42

        chooseResetView(in: harness)
        let reset = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            (try? driver.read(in: harness)) == start
        }
        XCTAssertTrue(reset, "the reference shows its starting view")
        XCTAssertEqual(appearance.trackHeight, 42, "Reset View leaves the app-wide track height")
    }

    /// Reset View on a genotype result returns its view to the open's (BIO review ruling 6).
    func testResetViewReturnsTheGenotypeResultToItsStart() async throws {
        let driver = GenotypeViewStateDriver()
        let (fixture, _) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let start = try driver.read(in: harness)
        try await driver.change(in: harness)
        await driver.settle(in: harness)
        XCTAssertNotEqual(try driver.read(in: harness), start)

        chooseResetView(in: harness)
        XCTAssertEqual(try driver.read(in: harness), start, "the genotype result shows its starting view")
    }

    /// Reset View returns a mapping result's read filters to the open's, in the Inspector's block, the viewer and the
    /// viewport's line (VS-MAP-2 UX ruling 5, BIO R9).
    func testResetViewReturnsTheMappingReadFiltersAndRemovesTheirLine() async throws {
        let driver = ReferenceViewStateDriver(route: .mapping)
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await show(fixture, in: harness, driver: driver)
        let block = harness.split.inspectorController.viewModel.readStyleSectionViewModel
        func viewport() throws -> ReferenceBundleViewportController {
            try XCTUnwrap((harness.split.viewerController.installedSurface as? ReferenceBundleSurface)?.controller)
        }
        let opened = try viewport().shownReadFilters
        XCTAssertEqual(opened, .defaults)
        block.minMapQ = 20
        block.onSettingsChanged?()
        XCTAssertEqual(try viewport().shownReadFilters?.minMapQ, 20, "the viewer reads the block's filter")
        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertNotNil(try viewport().readFilterLine, "the kept filter shows its line")

        chooseResetView(in: harness)
        XCTAssertEqual(block.minMapQ, 0, "the block reads the open's filter")
        XCTAssertEqual(try viewport().shownReadFilters, opened, "the viewer shows the open's reads")
        XCTAssertNil(try viewport().readFilterLine, "no filter line stays")
    }
}
