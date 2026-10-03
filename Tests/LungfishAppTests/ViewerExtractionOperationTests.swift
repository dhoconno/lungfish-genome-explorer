// ViewerExtractionOperationTests.swift - begin() site in ViewerViewController+Extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Building a bundle from an extracted sequence registers its row through a
// static begin helper on SequenceViewerView (R4). The row locks no bundle and
// records no command, because no lungfish-cli command builds a bundle from an
// extraction result, so the test pins that gap. A command added later fails
// the pin and prompts a parse test in its place. A reporter that refuses every
// begin proves the launch closure sits behind the `.started` case.

import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class ViewerExtractionOperationTests: XCTestCase {
    func testExtractionBundleRecordsItsRowAndNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish", isDirectory: true),
            windowStateScopeID: UUID()
        )
        var launchedID: UUID?

        SequenceViewerView.beginExtractionBundleOperation(
            sourceName: "NC_045512.2:100-200",
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Extracting NC_045512.2:100-200")
        XCTAssertEqual(item.initialDetail, "Preparing...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // CLI parity gap. `lungfish-cli extract sequence` writes a FASTA file
        // or standard output, and no command builds a `.lungfishref` bundle
        // with annotation and variant tracks from an extraction result.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "region-bundle-extraction")
    }

    func testExtractionBundleLaunchesNothingWhenTheBeginIsRefused() throws {
        // The row requests no lock, so no real center refuses it. A reporter
        // that refuses every begin proves the launch closure sits behind the
        // `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = SequenceViewerView.beginExtractionBundleOperation(
            sourceName: "NC_045512.2:100-200",
            routeContext: nil,
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("The refusal must be reported") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}
