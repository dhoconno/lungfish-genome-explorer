// Kraken2ReportsAvailableTests.swift - Whether a Kraken2 result folder still holds the reports its database was built from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.35, BIO-R1 item 8. The check moved from the app's sidebar to LungfishWorkflow so the
// `kraken2 export table` leaf can choose between its two stale-database messages with it.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class Kraken2ReportsAvailableTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "Kraken2ReportsAvailable")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    private func manifest(sampleFolders: [String]) -> ClassificationBatchResultManifest {
        ClassificationBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(schemaVersion: 2, createdAt: Date(), sampleCount: sampleFolders.count),
            goal: "classify",
            databaseName: "test-db",
            databaseVersion: "1",
            summaryTSV: "summary.tsv",
            samples: sampleFolders.map {
                MetagenomicsBatchSampleRecord(sampleId: $0, resultDirectory: $0, inputFiles: [], isPairedEnd: false)
            }
        )
    }

    /// True for a folder with `classification.kreport`, true for a batch manifest whose sample folder holds one,
    /// and false for neither, or for a manifest whose sample folders hold none.
    func testTheReportsCheckFindsASingleReportAndABatchManifestsReports() throws {
        XCTAssertFalse(Kraken2TaxonomyTableExport.reportsAvailable(in: folder), "an empty folder holds no report")

        let single = folder.appendingPathComponent("single", isDirectory: true)
        try FileManager.default.createDirectory(at: single, withIntermediateDirectories: true)
        try Data("report".utf8).write(to: single.appendingPathComponent("classification.kreport"))
        XCTAssertTrue(Kraken2TaxonomyTableExport.reportsAvailable(in: single))

        let batch = folder.appendingPathComponent("batch", isDirectory: true)
        let sampleFolder = batch.appendingPathComponent("sample-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleFolder, withIntermediateDirectories: true)
        try MetagenomicsBatchResultStore.saveClassification(manifest(sampleFolders: ["sample-1"]), to: batch)
        XCTAssertFalse(
            Kraken2TaxonomyTableExport.reportsAvailable(in: batch),
            "the manifest names a sample folder that holds no report"
        )

        try Data("report".utf8).write(to: sampleFolder.appendingPathComponent("classification.kreport"))
        XCTAssertTrue(Kraken2TaxonomyTableExport.reportsAvailable(in: batch))
    }
}
