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
    /// so the margin costs nothing when the machine is idle. Under heavy load
    /// the NAO-MGS rows took up to 8 seconds.
    private static let settleTimeout: Duration = .seconds(30)

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

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        let recorder = LoadedDocumentRecorder()
        let loader = split.externalDocumentLoader
        split.externalDocumentLoader = { url in
            recorder.urls.append(url)
            return try await loader(url)
        }

        split.displayContent(for: fixture.item)

        var observed = RoutingObserver.observe(split, paths: context.paths, loaded: recorder.urls)
        await waitUntil(timeout: Self.settleTimeout) {
            observed = RoutingObserver.observe(split, paths: context.paths, loaded: recorder.urls)
            return observed == fixture.expected
        }
        XCTAssertEqual(
            observed.description,
            fixture.expected.description,
            "\(label) routed differently.\n--- observed\n\(observed)\n--- expected\n\(fixture.expected)"
        )

        tearDownRow(split)
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
