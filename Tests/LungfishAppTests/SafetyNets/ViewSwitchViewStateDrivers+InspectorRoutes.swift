// ViewSwitchViewStateDrivers+InspectorRoutes.swift - The Inspector's view per item on every route, and Reset View's
// enabled state on every kind that keeps a view (VS-INSP fix round)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The cases the three reviews of VS-INSP asked for: a tab the app forces is never kept (UX B1, SWIFT SF-1), every route
// that shows an item begins the Inspector's visit (SWIFT B1, UX SF-1, BIO SF-1), the item's enabled state on every
// kind (UX SF-2), and the cases the brief names (UX SF-3, SWIFT SF-3). Each window keeps its views in a store under
// the test's own folder (QA 6).

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishKit
import LungfishTestSupport

extension ViewSwitchViewStateTests {
    /// Waits until the Inspector read the entry of the item on show.
    func waitForInspectorRead(in harness: ViewSwitchWindowHarness) async {
        let read = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            harness.split.inspectorController.viewMemoryIsSettled
        }
        XCTAssertTrue(read, "the Inspector read the item's entry")
    }

    /// Shows `fixture` and waits for the Inspector's read, so a pick lands on the item's own visit.
    func settledShow(_ fixture: ViewSwitchFixture, in harness: ViewSwitchWindowHarness, driver: any ViewStateDriver)
        async throws {
        try await show(fixture, in: harness, driver: driver)
        await waitForInspectorRead(in: harness)
    }

    /// Waits until the Inspector shows `tab` and says which tab showed instead.
    func assertShownTab(_ tab: InspectorTab, in harness: ViewSwitchWindowHarness, _ message: String) async {
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { self.shownTab(in: harness) == tab }
        XCTAssertTrue(shown, "\(message): \(tab.rawValue), not \(shownTab(in: harness).rawValue)")
    }

    /// A TaxTriage batch folder in the project's Analyses and its sidebar row, a `.batchGroup` row.
    func makeTaxTriageBatchRow() throws -> SidebarItem {
        let analyses = try SafetyNetFiles.makeDirectory(project.appendingPathComponent("Analyses", isDirectory: true))
        let batch = try SafetyNetFiles.makeDirectory(
            analyses.appendingPathComponent("taxtriage-batch-2026-01-16T12-00-00", isDirectory: true))
        try TaxTriageViewStateDriver.build(in: batch, stamp: "2026-01-16T12:30:00Z")
        for sample in ["HG002", "MMU-17"] {
            try SafetyNetFiles.makeDirectory(batch.appendingPathComponent(sample, isDirectory: true))
        }
        try RoutingSafetyNetTable.metadata("taxtriage", isBatch: true, in: batch)
        return SidebarItem(title: batch.lastPathComponent, type: .batchGroup, url: batch)
    }

    /// Shows a sidebar row and waits until `driver` shows it and the Inspector read its entry.
    func showRow(_ row: SidebarItem, in harness: ViewSwitchWindowHarness, driver: any ViewStateDriver) async {
        harness.select(row)
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
            driver.isShown(in: harness) && harness.split.inspectorController.viewMemoryIsSettled
        }
        XCTAssertTrue(shown, "\(row.title) did not show")
        await driver.settle(in: harness)
    }

    // MARK: - A tab the app forces is never kept (UX B1, BIO SF-3, SWIFT SF-1)

    func testInspectorTabTheAppForcesIsNeverKept() async throws {
        let driver = AlignmentViewStateDriver()
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        let model = harness.split.inspectorController.viewModel
        model.setAppTab(.view)
        XCTAssertNil(model.currentViewMemory.tab, "a tab the app sets is not a person's pick (SWIFT SF-1)")

        try await settledShow(fixture, in: harness, driver: driver)
        pick(.view, in: harness)
        let inspector = harness.split.inspectorController!
        let selection = MultipleSequenceAlignmentSelectionState(title: "MN908947", subtitle: nil, detailRows: [])
        // The first selection after an open can be held, so the second one forces the Selected Item tab.
        inspector.updateMultipleSequenceAlignmentSelection(selection)
        inspector.updateMultipleSequenceAlignmentSelection(selection)
        XCTAssertEqual(shownTab(in: harness), .selectedItem, "a selection in the alignment shows Selected Item")
        XCTAssertEqual(model.currentViewMemory.tab, InspectorTab.view.rawValue, "the forced tab is not the person's")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        await assertShownTab(.view, in: harness, "the alignment opens on the tab the person picked")
    }

    // MARK: - Every route begins the Inspector's visit (SWIFT B1, UX SF-1, BIO SF-1)

    func testInspectorTabPickedOnABatchGroupIsKeptForTheBatchAndNotForTheItemBefore() async throws {
        let reference = ReferenceViewStateDriver(route: .reference)
        let (fixture, other) = try await fixtures(for: reference)
        let batchRow = try makeTaxTriageBatchRow()
        let batch = TaxTriageViewStateDriver()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await settledShow(fixture, in: harness, driver: reference)
        await showRow(batchRow, in: harness, driver: batch)
        XCTAssertTrue(harness.split.inspectorController.viewModel.availableTabs.contains(.provenance))
        pick(.provenance, in: harness)

        try await leave(for: other, in: harness, driver: batch)
        try await settledShow(fixture, in: harness, driver: reference)
        XCTAssertEqual(shownTab(in: harness), .bundle, "the batch's pick is not the reference's")
        await showRow(batchRow, in: harness, driver: batch)
        await assertShownTab(.provenance, in: harness, "the batch keeps its own tab")
    }

    /// A project sequence's URL is its file's, which every sequence of that file shares, so it keeps no tab of its own
    /// and a pick there is never kept under the item shown before (UX SF-1).
    func testInspectorTabPickedOnAProjectSequenceIsNotKeptForTheItemBefore() async throws {
        let reference = ReferenceViewStateDriver(route: .reference)
        let (fixture, _) = try await fixtures(for: reference)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await settledShow(fixture, in: harness, driver: reference)
        pick(.provenance, in: harness)

        let document = LoadedDocument(url: project.appendingPathComponent("sequences.fasta"), type: .fasta)
        document.projectSequenceID = UUID()
        let registered = harness.split.projectSession.registerDocument(document, makeActive: false)
        let row = SidebarItem(title: "project sequence", type: .sequence)
        row.userInfo["documentID"] = registered.id.uuidString
        harness.select(row)
        pick(.analysis, in: harness)

        try await show(fixture, in: harness, driver: reference)
        await assertShownTab(.provenance, in: harness, "the reference opens on its own tab")
    }

    // MARK: - The enabled state on every kind (UX SF-2)

    /// For each kind that keeps a view: off at a first visit, on after a person's change, and off again after Reset
    /// View, which shows the starting view.
    func testResetViewIsEnabledOnlyWhileTheViewDiffersFromItsStartOnEveryKindThatKeepsAView() async throws {
        for driver in ViewStateDrivers.all {
            let fixture = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: driver.kind), in: project)
            try driver.prepare(fixture)
            let harness = try ViewSwitchWindowHarness()
            defer { harness.close() }
            harness.keepViews(in: loadedStore())
            try await show(fixture, in: harness, driver: driver)
            let inspector = harness.split.inspectorController!
            let start = try driver.read(in: harness)
            XCTAssertFalse(inspector.openViewDiffersFromItsStart, "\(driver.kind): a first visit shows its starting view")
            try await driver.change(in: harness)
            await driver.settle(in: harness)
            let enabled = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
                inspector.openViewDiffersFromItsStart
            }
            XCTAssertTrue(enabled, "\(driver.kind): a person's change enables Reset View")

            chooseResetView(in: harness)
            let reset = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
                (try? driver.read(in: harness)) == start
            }
            let shown = (try? driver.read(in: harness)) ?? []
            XCTAssertTrue(reset, "\(driver.kind): Reset View shows the starting view \(start), not \(shown)")
            let disabled = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) {
                !inspector.openViewDiffersFromItsStart
            }
            XCTAssertTrue(disabled, "\(driver.kind): Reset View disables the item")
        }
    }

    /// The View menu reads the same state through `AppDelegate.validateMenuItem`, and a changed reference left for a
    /// kind that keeps no view does not enable the item there.
    func testResetViewMenuItemFollowsTheViewOnShow() async throws {
        let driver = ReferenceViewStateDriver(route: .reference)
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        let app = AppDelegate()
        app.mainWindowController = harness.controller
        let item = NSMenuItem(
            title: ResetViewWords.menuTitle, action: #selector(AppDelegate.resetViewSettingsToDefaults(_:)),
            keyEquivalent: "")
        try await show(fixture, in: harness, driver: driver)
        XCTAssertFalse(app.validateMenuItem(item), "the menu item is off at a first visit")
        try await driver.change(in: harness)
        XCTAssertTrue(app.validateMenuItem(item), "the menu item is on after a zoom")

        try await leave(for: other, in: harness, driver: driver)
        XCTAssertFalse(
            harness.split.inspectorController.openViewDiffersFromItsStart,
            "a changed reference left for a kind that keeps no view does not enable the item")
        XCTAssertFalse(app.validateMenuItem(item), "the menu item is off on a kind that keeps no view")
    }
}
