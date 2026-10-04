// MainSplitCrossProjectCopyOperationTests.swift - begin() site in MainSplitViewController+CrossProjectCopy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A Lungfish item dropped into an open project is copied by
// CrossProjectItemCopier, one row per item (R4). No lungfish-cli command copies
// an item between projects, so the row records no command, a CLI parity gap
// (R3) the tests pin. The row locks no bundle, so a reporter that refuses every
// begin stands in for a refusal.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class MainSplitCrossProjectCopyOperationTests: XCTestCase {
    private let itemURL = URL(
        fileURLWithPath: "/tmp/lane 1k2/Other.lungfish/Imports/Sample 1.lungfishfastq",
        isDirectory: true
    )
    private let projectURL = URL(fileURLWithPath: "/tmp/lane 1k2/Project.lungfish", isDirectory: true)
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 1k2/Project.lungfish"),
        windowStateScopeID: UUID()
    )

    func testCopyRowRecordsItsRowAndNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()

        let result = MainSplitViewController.beginCrossProjectCopyOperation(
            itemURL: itemURL,
            projectURL: projectURL,
            routeContext: routeContext,
            reporter: reporter
        )

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(item.title, "Copy Sample 1.lungfishfastq")
        XCTAssertEqual(item.initialDetail, "Copying into Project...")
        XCTAssertEqual(item.operationType, .ingestion)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // CLI parity gap. No lungfish-cli command copies an item into another
        // project with its links rewritten. When one exists, record it and
        // replace this pin with a parse test.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "cross-project-copy")
    }

    func testRefusedCopyReturnsTheRefusalSoTheItemIsSkipped() {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")

        let result = MainSplitViewController.beginCrossProjectCopyOperation(
            itemURL: itemURL,
            projectURL: projectURL,
            routeContext: nil,
            reporter: reporter
        )

        XCTAssertNil(result.startedID)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}
