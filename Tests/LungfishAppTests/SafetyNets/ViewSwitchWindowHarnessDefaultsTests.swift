// ViewSwitchWindowHarnessDefaultsTests.swift - A 12S viewer the view-switch window shows saves no layout in the runner's defaults
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `AssemblyResultSurfaceRouteTests.testEveryKindOfTheMatrixTakesTheAssemblyAway` (since 5026deea2) opens the 12S row in
// a `ViewSwitchWindowHarness` window, which used the App's own 12S factory. The two 12S tables keyed their layouts by
// the result's output name, `primate-12s`, in `UserDefaults.standard`. Both viewers outlived the window, and each
// text-size change of a later test (FASTQDashboardTests and the Genotype typography tests) resized their columns, so
// `...TwelveSTargetTableView:primate-12s` and `...TwelveSUnresolvedTableView:primate-12s` landed in the xctest tool's
// domain during those tests (FULL1-12S-LEAK, the full tier on 94266d11b). The harness now gives each 12S viewer it
// shows a suite of its own, and takes the tables' identity away when it closes, so a viewer that outlives the window
// saves nothing.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishKit
@testable import LungfishTwelveSUI

@MainActor
final class ViewSwitchWindowHarnessDefaultsTests: XCTestCase {
    private var root: URL!
    /// Puts the 12S layout keys of the runner's defaults back as they were, should a table save there.
    private var hostDefaults: HostDefaultsRestorer?

    private let layoutKeys = [
        "org.lungfish.metadata-column-layout.LungfishTwelveSUI.TwelveSTargetTableView:primate-12s",
        "org.lungfish.metadata-column-layout.LungfishTwelveSUI.TwelveSUnresolvedTableView:primate-12s",
    ]

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "view-switch-harness-defaults")
        hostDefaults = HostDefaultsRestorer(keysContaining: ":primate-12s")
    }

    override func tearDown() async throws {
        hostDefaults?.restore()
        hostDefaults = nil
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// The 12S tables of the window save to a suite, and once the window closes a column resize saves nothing.
    func testATwelveSViewerTheWindowShowedSavesNoLayoutInTheRunnerDefaults() async throws {
        let bundle = try RoutingSafetyNetFixtures.twelveSResultBundle(in: root).bundle
        let harness = try ViewSwitchWindowHarness()
        let viewer = try XCTUnwrap(harness.split.viewerController)
        harness.select(SidebarItem(title: bundle.lastPathComponent, type: .twelveSAmpliconResultBundle, url: bundle))
        let shown = await waitUntil(budget: .lookup) {
            viewer.twelveSAmpliconResultViewController?.unresolvedTable.resultIdentity != nil
        }
        XCTAssertTrue(shown, "the 12S row never opened in the window")
        let twelveS = try XCTUnwrap(viewer.twelveSAmpliconResultViewController)
        let target = twelveS.targetTable
        let unresolved = twelveS.unresolvedTable
        XCTAssertFalse(
            target.metadataColumns.userDefaults === UserDefaults.standard,
            "the 12S target table saves its layout in the runner's defaults"
        )
        XCTAssertFalse(
            unresolved.metadataColumns.userDefaults === UserDefaults.standard,
            "the 12S unresolved table saves its layout in the runner's defaults"
        )

        let before = layoutKeys.map { UserDefaults.standard.data(forKey: $0) }
        harness.close()
        XCTAssertNil(target.resultIdentity, "the 12S target table still keys its layout by the result after the window closed")
        XCTAssertNil(
            unresolved.resultIdentity,
            "the 12S unresolved table still keys its layout by the result after the window closed"
        )

        // A later test's text-size change resizes the columns of a viewer that outlived its window.
        for table in [target.tableView, unresolved.tableView] {
            for column in try XCTUnwrap(table).tableColumns {
                column.width += 7
            }
        }
        XCTAssertEqual(
            layoutKeys.map { UserDefaults.standard.data(forKey: $0) },
            before,
            "a 12S viewer that outlived the window saved its layout in the runner's defaults"
        )
    }
}
