// InspectorMetadataImportOperationTests.swift - begin() sites in InspectorViewController+MetadataImport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Removing a derived alignment registers its row through a static begin
// helper (R4). A held bundle lock must refuse the row and launch nothing, and
// the recorded row must carry its type and its lock. No lungfish-cli command
// removes an alignment track yet, so the test pins that the row records no
// command and fails when a command is added.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class InspectorMetadataImportOperationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a2/Sample.lungfishref", isDirectory: true)

    /// A fresh center whose bundle lock is already held, as when another
    /// operation is running on the same bundle.
    private func centerHoldingBundleLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Calling variants with LoFreq",
            detail: "Running",
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli variants call"
        ).startedID)
        return center
    }

    func testRemoveDerivedAlignmentRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = InspectorViewController.beginRemoveDerivedAlignmentOperation(
            trackName: "Sample 1 filtered",
            bundleURL: bundleURL,
            routeContext: nil,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the removal row")
        }
        XCTAssertFalse(launched, "a refused row must not remove the track")
        XCTAssertEqual(refusal.blockingOperationTitle, "Calling variants with LoFreq")
    }

    func testRemoveDerivedAlignmentRecordsItsTypeAndLockAndNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish"),
            windowStateScopeID: UUID()
        )
        var launchedID: UUID?

        InspectorViewController.beginRemoveDerivedAlignmentOperation(
            trackName: "Sample 1 filtered",
            bundleURL: bundleURL,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Remove Derived Alignment")
        XCTAssertEqual(item.initialDetail, "Removing Sample 1 filtered...")
        XCTAssertEqual(item.operationType, .bamImport)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // CLI parity gap. No lungfish-cli command removes an alignment track.
        // The closest is `bam filter`, which creates the derived tracks. When
        // a removal command exists, record it and replace this pin with a
        // parse test.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "alignment-track-remove")
    }
}
