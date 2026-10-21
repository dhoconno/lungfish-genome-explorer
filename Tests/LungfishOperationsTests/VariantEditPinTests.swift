// VariantEditPinTests.swift - What the three stored variant edits leave in a bundle today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A43 M1, plan decision C3 (BIO 1 and 4, SWIFT). The drawer's three stored variant
// edits are deleting selected variants, deleting all variants and importing sample metadata. Each
// test runs one edit on a fresh bundle and pins the sorted rows of the variant database (not its
// SQLite bytes) and the bundle's provenance record, with the clocks, checksums, sizes and the root
// path masked. The pins hold what the services write before they move to LungfishWorkflow and
// before `variants delete` and `variants import-sample-metadata` call them, so the later commits
// show every value they move. One more test pins the wall time of one metadata import, since the
// route launches a process for it (SWIFT).

import Foundation
import LungfishCore
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishOperations

final class VariantEditPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "variant-edit-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testSelectedDeletionLeavesTheseRowsAndRecord() throws {
        let fixture = try VariantEditFixture.make(in: root)
        let ids = try fixture.variantIDs()
        XCTAssertEqual(ids.count, 3)
        let result = try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteVariants(
            idsByTrack: ["trackA": [ids[1]]],
            bundleURL: fixture.bundleURL,
            targets: [VariantDeletionMutationTarget(trackId: "trackA", databaseURL: fixture.databaseURL, trackName: "Variants")]
        )
        XCTAssertEqual(result.totalDeleted, 1)
        try VariantEditPins.assertPin("selected-deletion-rows", actual: VariantEditDump.rows(of: fixture.databaseURL))
        try VariantEditPins.assertPin(
            "selected-deletion-record", actual: VariantEditDump.provenance(of: fixture.bundleURL, root: root)
        )
    }

    func testDeleteAllLeavesTheseRowsAndRecord() throws {
        let fixture = try VariantEditFixture.make(in: root)
        let result = try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteAllVariants(
            bundleURL: fixture.bundleURL,
            targets: [VariantDeletionMutationTarget(trackId: "trackA", databaseURL: fixture.databaseURL, trackName: "Variants")]
        )
        XCTAssertEqual(result.totalDeleted, 3)
        try VariantEditPins.assertPin("delete-all-rows", actual: VariantEditDump.rows(of: fixture.databaseURL))
        try VariantEditPins.assertPin(
            "delete-all-record", actual: VariantEditDump.provenance(of: fixture.bundleURL, root: root)
        )
    }

    func testSampleMetadataImportLeavesTheseRowsAndRecord() throws {
        let fixture = try VariantEditFixture.make(in: root)
        let metadata = try fixture.writeMetadata()
        let result = try VariantSampleMetadataImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).importMetadata(
            from: metadata,
            format: .tsv,
            bundleURL: fixture.bundleURL,
            targets: [VariantSampleMetadataImportTarget(databaseURL: fixture.databaseURL, trackName: "trackA")]
        )
        XCTAssertEqual(result.totalUpdated, 2)
        try VariantEditPins.assertPin("metadata-import-rows", actual: VariantEditDump.rows(of: fixture.databaseURL))
        try VariantEditPins.assertPin(
            "metadata-import-record", actual: VariantEditDump.provenance(of: fixture.bundleURL, root: root)
        )
    }

    /// The wall time of one in-process metadata import on the fixture. The route launches a
    /// process for the import, whose start the same measure then shows (SWIFT). The bound is wide,
    /// since the pin is the printed figure and the report quotes it.
    func testOneMetadataImportsWallTimeIsBounded() throws {
        let fixture = try VariantEditFixture.make(in: root)
        let metadata = try fixture.writeMetadata()
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            _ = try VariantSampleMetadataImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).importMetadata(
                from: metadata,
                format: .tsv,
                bundleURL: fixture.bundleURL,
                targets: [VariantSampleMetadataImportTarget(databaseURL: fixture.databaseURL, trackName: "trackA")]
            )
        }
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        print("VARIANT-EDIT-WALL in-process metadata import: \(milliseconds) ms")
        XCTAssertLessThan(elapsed, .seconds(10), "one metadata import of two samples took \(milliseconds) ms")
    }
}
