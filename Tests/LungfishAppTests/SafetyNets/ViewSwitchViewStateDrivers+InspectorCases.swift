// ViewSwitchViewStateDrivers+InspectorCases.swift - The cases of the Inspector's view per item the brief names (VS-INSP
// fix round, UX SF-3, SWIFT SF-3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Two items each as left, a kept tab the content does not offer, each tab through a switch and a relaunch, the window's
// tab as the fallback, and no write into the project. Each window keeps its views in a store under the test's own
// folder (QA 6).

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishKit
import LungfishTestSupport

/// A tab a person picks on a kind, after the picks that come first, such as a row for the 12S Detail tab.
struct InspectorTabKeepCase {
    let driver: any ViewStateDriver
    /// The picks in order, the last of which is the tab kept.
    let picks: [InspectorTab]
    /// Whether the driver's change runs before the picks, so the tab has something to show.
    let changeFirst: Bool
}

extension ViewSwitchViewStateTests {
    /// Each tab the brief names on a kind that offers it. A pick back to the content's own tab replaces a kept tab, so
    /// Bundle and Summary are picked after Provenance. Files, Sample Metadata and Assistant are offered by no kind the
    /// harness shows with the app's settings as the tests run (report, item 6).
    static var inspectorTabKeepCases: [InspectorTabKeepCase] {
        [
            InspectorTabKeepCase(
                driver: ReferenceViewStateDriver(route: .reference), picks: [.provenance, .bundle], changeFirst: false),
            InspectorTabKeepCase(driver: TwelveSViewStateDriver(), picks: [.provenance, .resultSummary], changeFirst: false),
            InspectorTabKeepCase(driver: TwelveSViewStateDriver(), picks: [.twelveSDetail], changeFirst: true),
        ]
    }

    func testEachInspectorTabKeepsThroughASwitchAndARelaunch() async throws {
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        var built: [String: ViewSwitchFixture] = [:]
        for keepCase in Self.inspectorTabKeepCases {
            let driver = keepCase.driver
            if built[driver.kind] == nil {
                let fixture = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: driver.kind), in: project)
                try driver.prepare(fixture)
                built[driver.kind] = fixture
            }
            let fixture = try XCTUnwrap(built[driver.kind])
            let tab = try XCTUnwrap(keepCase.picks.last)
            // Each case keeps into a store of its own, so one case's entry is not the next one's start.
            let store = ViewMemoryStore(root: root.appendingPathComponent("tabs-\(driver.kind)-\(tab.rawValue)"))
            store.loadProject(at: project)
            do {
                let harness = try ViewSwitchWindowHarness()
                harness.keepViews(in: store)
                try await settledShow(fixture, in: harness, driver: driver)
                if keepCase.changeFirst { try await driver.change(in: harness) }
                let model = harness.split.inspectorController.viewModel
                XCTAssertTrue(model.availableTabs.contains(tab), "\(driver.kind) offers \(tab.rawValue)")
                keepCase.picks.forEach { pick($0, in: harness) }
                try await leave(for: other, in: harness, driver: driver)
                try await settledShow(fixture, in: harness, driver: driver)
                await assertShownTab(tab, in: harness, "\(driver.kind): through a switch")
                harness.split.viewerController.surfaceHost.captureActive()
                store.flushSynchronously()
                harness.close()
            }
            let relaunched = ViewMemoryStore(root: root.appendingPathComponent("tabs-\(driver.kind)-\(tab.rawValue)"))
            relaunched.loadProject(at: project)
            let harness = try ViewSwitchWindowHarness()
            defer { harness.close() }
            harness.keepViews(in: relaunched)
            try await settledShow(fixture, in: harness, driver: driver)
            await assertShownTab(tab, in: harness, "\(driver.kind): through a relaunch")
        }
    }

    /// Two items each keep their own tab through A, B, A, B in one window (UX SF-3).
    func testInspectorTabsOfTwoItemsEachComeBackAsLeft() async throws {
        let reference = ReferenceViewStateDriver(route: .reference)
        let mapping = ReferenceViewStateDriver(route: .mapping)
        let (first, _) = try await fixtures(for: reference)
        let second = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: mapping.kind), in: project)
        try mapping.prepare(second)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await settledShow(first, in: harness, driver: reference)
        pick(.provenance, in: harness)
        try await settledShow(second, in: harness, driver: mapping)
        pick(.view, in: harness)
        for round in 1...2 {
            try await settledShow(first, in: harness, driver: reference)
            await assertShownTab(.provenance, in: harness, "round \(round): the reference as left")
            try await settledShow(second, in: harness, driver: mapping)
            await assertShownTab(.view, in: harness, "round \(round): the mapping result as left")
        }
    }

    /// A kept tab the content does not offer leaves the content's tab, with no line (UX SF-3).
    func testInspectorKeptTabTheContentDoesNotOfferOpensTheContentsTab() async throws {
        let driver = ReferenceViewStateDriver(route: .reference)
        let (fixture, _) = try await fixtures(for: driver)
        let store = loadedStore()
        let url = try XCTUnwrap(fixture.item.url).standardizedFileURL
        let item = InspectorViewMemoryVisit.inspectorItem(of: ViewMemoryItem.read(at: url))
        let key = try XCTUnwrap(store.key(for: item))
        store.keep(
            InspectorViewMemory(tab: InspectorTab.twelveSDetail.rawValue), startingView: .start, for: key, dataKey: nil,
            folder: item.folder)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: store)
        try await settledShow(fixture, in: harness, driver: driver)
        XCTAssertFalse(harness.split.inspectorController.viewModel.availableTabs.contains(.twelveSDetail))
        XCTAssertEqual(shownTab(in: harness), .bundle, "the content's tab")
        XCTAssertNil(driver.resetLineWords(in: harness), "no line")
    }

    /// The window's tab from `window-state.json` is the fallback of an item with no entry, and an item's entry wins
    /// over it (UX SF-3).
    func testInspectorWindowTabIsTheFallbackAndTheItemsEntryWins() async throws {
        let reference = ReferenceViewStateDriver(route: .reference)
        let mapping = ReferenceViewStateDriver(route: .mapping)
        let (first, _) = try await fixtures(for: reference)
        let second = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: mapping.kind), in: project)
        try mapping.prepare(second)
        do {
            let store = loadedStore()
            let harness = try ViewSwitchWindowHarness()
            harness.keepViews(in: store)
            try await settledShow(first, in: harness, driver: reference)
            pick(.provenance, in: harness)
            harness.split.viewerController.surfaceHost.captureActive()
            store.flushSynchronously()
            harness.close()
        }
        do {
            let harness = try ViewSwitchWindowHarness()
            defer { harness.close() }
            harness.keepViews(in: loadedStore())
            harness.split.inspectorController.restoreSelectedTabIdentifier(InspectorTab.analysis.rawValue)
            try await settledShow(first, in: harness, driver: reference)
            await assertShownTab(.provenance, in: harness, "the item's entry wins over the window's tab")
        }
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        harness.split.inspectorController.restoreSelectedTabIdentifier(InspectorTab.analysis.rawValue)
        try await settledShow(second, in: harness, driver: mapping)
        await assertShownTab(.analysis, in: harness, "an item with no entry opens on the window's tab")
    }

    /// The window's tab belongs to the content its snapshot restores. A snapshot with no active content leaves none for
    /// the next item shown, so that item opens on its own tab and keeps it (VS-INSP fix, SWIFT SF-1).
    func testInspectorWindowTabOfASnapshotWithNoActiveContentIsNotTheNextItemsTab() async throws {
        // Applying a snapshot can save the panels' state to the runner's defaults, so those keys go back as they were.
        let panelDefaults = HostDefaultsRestorer(keys: [
            MainSplitViewController.sidebarCollapsedDefaultsKey, MainSplitViewController.inspectorCollapsedDefaultsKey,
            MainSplitViewController.sidebarWidthDefaultsKey, MainSplitViewController.inspectorWidthDefaultsKey,
        ])
        defer { panelDefaults.restore() }
        let mapping = ReferenceViewStateDriver(route: .mapping)
        let second = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: mapping.kind), in: project)
        try mapping.prepare(second)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        harness.split.applyProjectWindowSnapshot(
            ProjectWindowSnapshot(
                id: UUID(), projectURL: project, windowOrdinal: 1, windowOrder: 0, windowTitleSuffix: nil, frame: nil,
                isFullScreen: false, selectedSidebarURL: nil, expandedSidebarURLs: [], sidebarSearchText: nil,
                activeContent: nil, inspectorTab: InspectorTab.analysis.rawValue, sidebarCollapsed: false,
                inspectorCollapsed: false, sidebarWidth: nil, inspectorWidth: nil, operationsPanelFilter: nil,
                operationsPanelVisible: false))
        try await settledShow(second, in: harness, driver: mapping)
        await assertShownTab(
            .bundle, in: harness, "an item opened after a snapshot with no active content opens on its own tab")
    }

    /// A tab pick, a person's change, Reset View, a switch away and back write nothing into the project (UX 6,
    /// SWIFT SF-3).
    func testATabChangeAndResetViewWriteNothingIntoTheProject() async throws {
        let driver = ReferenceViewStateDriver(route: .reference)
        let (fixture, other) = try await fixtures(for: driver)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: loadedStore())
        try await settledShow(fixture, in: harness, driver: driver)
        let before = try ProjectDigest(of: project)
        pick(.provenance, in: harness)
        try await driver.change(in: harness)
        chooseResetView(in: harness)
        try await leave(for: other, in: harness, driver: driver)
        try await settledShow(fixture, in: harness, driver: driver)
        XCTAssertEqual(try ProjectDigest(of: project).differences(from: before).map(\.summary), [])
    }
}
