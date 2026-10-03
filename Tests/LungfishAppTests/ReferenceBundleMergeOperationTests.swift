// ReferenceBundleMergeOperationTests.swift - The merge service's Operations panel row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `ReferenceBundleMergeService.merge` takes its reporter as a parameter (R4),
// so these tests watch the row without touching `OperationCenter.shared`.
// The merge has no lungfish-cli equivalent yet, so its row records no command
// and the test pins that.

import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class ReferenceBundleMergeOperationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = try TestTempDirectory.make(prefix: "reference-merge-operation")
    }

    override func tearDown() {
        if let tempDirectory {
            TestTempDirectory.cleanup(tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    func testMergeRecordsABundleBuildRowWithNoCommandAsAParityGap() async throws {
        let reporter = RecordingOperationReporter()
        let onlyBundle = tempDirectory.appendingPathComponent("A.lungfishref", isDirectory: true)

        do {
            _ = try await ReferenceBundleMergeService.merge(
                sourceBundleURLs: [onlyBundle],
                outputDirectory: tempDirectory,
                bundleName: "Merged",
                reporter: reporter
            )
            XCTFail("a one-bundle merge must fail")
        } catch ReferenceBundleMergeServiceError.requiresAtLeastTwoBundles {
            // Expected. The merge fails before it touches disk.
        }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(item.title, "Merge Reference Bundles")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        // CLI parity gap. No lungfish-cli command merges reference bundles.
        // The closest is `bundle create`. When a merge command exists, record
        // it and replace this pin with a parse test.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "reference-bundle-merge")
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.failure?.errorMessage, "Select at least two reference bundles to merge.")
        XCTAssertEqual(item.logs.first?.message, "Merging 1 reference bundles into \"Merged\".")
    }

    func testRefusedMergeThrowsAndWritesNothing() async throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        let sources = ["A", "B"].map {
            tempDirectory.appendingPathComponent("\($0).lungfishref", isDirectory: true)
        }
        let outputDirectory = tempDirectory.appendingPathComponent("Output", isDirectory: true)

        do {
            _ = try await ReferenceBundleMergeService.merge(
                sourceBundleURLs: sources,
                outputDirectory: outputDirectory,
                bundleName: "Merged",
                reporter: reporter
            )
            XCTFail("a refused begin must stop the merge")
        } catch let error as OperationRefusedError {
            XCTAssertEqual(error.refusal.blockingOperationTitle, "Importing BAM")
        }

        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        XCTAssertTrue(reporter.items[0].logs.isEmpty, "a refused merge reports nothing further")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path), "a refused merge writes nothing")
    }
}
