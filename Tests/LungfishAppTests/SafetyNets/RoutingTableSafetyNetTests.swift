// RoutingTableSafetyNetTests.swift - Every sidebar kind through the real router
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Safety net for architecture review finding R1. Selecting a sidebar row runs
// `MainSplitViewController.displayContent(for:)`, a chain of type checks that
// decides which viewport opens and what it binds. The architecture program
// replaces that chain with a registry, so this suite freezes what the chain
// does today, one table row per routed sidebar kind (RoutingSafetyNetTable).
//
// Each row builds its fixture under a fresh scratch root, selects the row on
// a fresh split controller with no window, waits for the asynchronous loads to
// settle and compares the full RoutingObservation with the row's expected
// value. A failure prints both observations, so the changed binding is the
// differing line. Every `SidebarItemType` case has at least one row.
//
// No window is attached, so failure paths never raise a sheet. The document
// loader is wrapped to record what reaches it and then calls the real loader.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishTestSupport

@MainActor
final class RoutingTableSafetyNetTests: XCTestCase {
    /// How long a row may take to settle. Reference and mapping viewports
    /// install on the next run-loop turn and several results load in a task
    /// that reads files off the main actor. A row ends as soon as it matches,
    /// so the margin costs nothing when the machine is idle. The NAO-MGS rows
    /// open their SQLite database on the main actor, and under the unit gate's
    /// own load (load average 126 on 14 cores) they and the genotype workbook
    /// preview row took more than 30 seconds. On 2026-10-12 the unit tier ran
    /// beside four lane builds. Tests that touched files stalled for two to
    /// three minutes at a time (unrelated tests took 139 to 181 seconds) and
    /// the NVD analysis row ran out of 120 seconds before its load published.
    /// The ceiling now sits well above the longest stall seen.
    private static let settleCeiling: Duration = .seconds(300)

    /// What a row may wait once an earlier row of the same test ran out of
    /// time. A stall ends for every row at once, so a later row either settles
    /// in moments or its route is broken. This keeps a change that breaks
    /// many rows from costing the full ceiling for each of them.
    private static let settleAfterTimeout: Duration = .seconds(30)

    /// A further look after a row runs out of time. When a stall ends, the
    /// poll that finds the deadline gone can run before the load it waits for,
    /// which then publishes a moment later.
    private static let settleGrace: Duration = .seconds(10)

    /// The wait between two looks. Each look reads the whole window and runs on
    /// the main actor beside the load it waits for.
    private static let settlePoll: Duration = .milliseconds(25)

    private var settleTimeout: Duration = RoutingTableSafetyNetTests.settleCeiling

    // MARK: - Coverage

    func testCatalogNamesEveryDeclaredSidebarItemType() throws {
        let declared = try XCTUnwrap(
            SidebarItemTypeCatalog.declaredCaseCount,
            "SidebarItemType is no longer a one-byte payload-free enum, so its case count cannot be read"
        )
        XCTAssertEqual(
            SidebarItemTypeCatalog.all.count,
            declared,
            "SidebarItemType declares \(declared) cases but SidebarItemTypeCatalog.all lists \(SidebarItemTypeCatalog.all.count)"
        )
        XCTAssertEqual(
            SidebarItemTypeCatalog.all.map(SidebarItemTypeCatalog.layoutTag(of:)),
            Array(0..<SidebarItemTypeCatalog.all.count),
            "SidebarItemTypeCatalog.all must list the cases in declaration order"
        )
    }

    func testTableHasARowForEverySidebarItemType() {
        let covered = Set(RoutingSafetyNetTable.rows.map(\.type))
        let missing = SidebarItemTypeCatalog.all.filter { !covered.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "Routing table has no row for \(missing.map(SidebarItemTypeCatalog.caseName))"
        )
        let names = RoutingSafetyNetTable.rows.map { "\($0.family.rawValue)/\($0.name)" }
        XCTAssertEqual(names.count, Set(names).count, "Row names must be unique within a family")
    }

    // MARK: - Families

    func testContainerAndBatchGroupRows() async throws {
        try await runRows(in: .containers)
    }

    func testFileRows() async throws {
        try await runRows(in: .files)
    }

    func testBundleRows() async throws {
        try await runRows(in: .bundles)
    }

    func testClassifierResultRows() async throws {
        try await runRows(in: .classifiers)
    }

    func testAnalysisResultRows() async throws {
        try await runRows(in: .analyses)
    }

    // MARK: - Runner

    private func runRows(in family: RoutingRow.Family) async throws {
        let rows = RoutingSafetyNetTable.rows.filter { $0.family == family }
        XCTAssertFalse(rows.isEmpty, "Family \(family.rawValue) has no rows")
        for row in rows {
            try await run(row)
        }
    }

    private func run(_ row: RoutingRow) async throws {
        let label = "\(row.family.rawValue)/\(row.name)"
        let root = try TestTempDirectory.make(prefix: "RoutingSafetyNet")
        defer { TestTempDirectory.cleanup(root) }
        let context = RoutingRowContext(root: root, paths: SafetyNetPathRenderer(root: root))

        let fixture: RoutingRowFixture
        do {
            fixture = try await row.build(context)
        } catch {
            XCTFail("\(label): fixture failed to build: \(error)")
            return
        }
        XCTAssertEqual(
            SidebarItemTypeCatalog.caseName(fixture.item.type),
            SidebarItemTypeCatalog.caseName(row.type),
            "\(label): the sidebar row has a different type than the table states"
        )
        // Every outcome is a kind of the view-switch matrix, so a row that
        // opens a new viewport joins ViewSwitchMatrixTests in the same change.
        XCTAssertNotNil(
            ViewSwitchKinds.kind(of: fixture.expected),
            "\(label): the view-switch matrix has no kind for the outcome \(ViewSwitchKinds.outcome(of: fixture.expected)). Add one to ViewSwitchKinds.all"
        )

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        // A row routed to Quick Look is recorded rather than drawn, with the
        // status line a finished preview shows.
        RecordingFilePreviewRenderer.install(on: split.viewerController)
        let recorder = LoadedDocumentRecorder()
        let loader = split.externalDocumentLoader
        split.externalDocumentLoader = { url in
            recorder.urls.append(url)
            return try await loader(url)
        }

        split.displayContent(for: fixture.item)

        var observed = RoutingObserver.observe(split, paths: context.paths, loaded: recorder.urls)
        func isSettled() -> Bool {
            observed = RoutingObserver.observe(split, paths: context.paths, loaded: recorder.urls)
            return observed == fixture.expected
        }
        let waitStarted = ContinuousClock.now
        let settled = await waitUntil(timeout: settleTimeout, pollInterval: Self.settlePoll, isSettled)
        if !settled {
            settleTimeout = Self.settleAfterTimeout
            if await waitUntil(timeout: Self.settleGrace, pollInterval: Self.settlePoll, isSettled) {
                print("\(label) settled only in the grace look, after \(ContinuousClock.now - waitStarted) at load average \(Self.loadAverage). Later rows of this test wait \(Self.settleAfterTimeout).")
            }
        }
        XCTAssertEqual(
            observed.description,
            fixture.expected.description,
            "\(label) routed differently after \(ContinuousClock.now - waitStarted) at load average \(Self.loadAverage).\n--- observed\n\(observed)\n--- expected\n\(fixture.expected)"
        )

        tearDownRow(split)
    }

    /// The one-minute load average, written into a failure so a stalled machine
    /// reads differently from a changed route.
    private static var loadAverage: String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "unknown" }
        return String(format: "%.1f", loads[0])
    }

    /// Ends the row's display request and removes its viewport, so no load
    /// started by this row can publish into the next one.
    private func tearDownRow(_ split: MainSplitViewController) {
        split.invalidateDisplayRequest()
        split.cancelFASTQLoadIfNeeded(hideProgress: true, reason: "routing safety net row finished")
        split.viewerController.clearViewport()
        split.inspectorController.clearSelection()
    }
}

/// Records every URL handed to the external document loader.
@MainActor
final class LoadedDocumentRecorder {
    var urls: [URL] = []
}
