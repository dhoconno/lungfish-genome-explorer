// TaxonomyReopenBrackenTests.swift - A reopened Kraken 2 result shows Kraken 2's tree with a Bracken column
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SQLite3
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class TaxonomyReopenBrackenTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxonomyReopenBracken-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeResultFolder() throws -> URL {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LungfishAppViewTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/kraken2-bracken-reopen")
        let resultDir = tempRoot.appendingPathComponent("kraken2-2026-09-24T23-36-28")
        try FileManager.default.copyItem(at: fixture, to: resultDir)
        return resultDir
    }

    /// Builds kraken2.sqlite the way `build-db kraken2` now does: the
    /// post-run tree (Kraken 2's report with Bracken merged) keyed by the
    /// recorded sample name.
    @discardableResult
    private func buildDatabase(in resultDir: URL) throws -> Kraken2Database {
        let result = try ClassificationResult.load(from: resultDir)
        let sample = try XCTUnwrap(result.config.sampleDisplayName)
        return try Kraken2Database.create(
            at: resultDir.appendingPathComponent("kraken2.sqlite"),
            rows: Kraken2Database.rows(from: result.tree, sample: sample),
            metadata: Kraken2Database.sampleMetadata(for: result.tree, sample: sample)
        )
    }

    func testReopenedResultShowsKrakenTreeBrackenColumnAndSampleName() throws {
        let resultDir = try makeResultFolder()
        let db = try buildDatabase(in: resultDir)

        let vc = TaxonomyViewController()
        _ = vc.view
        vc.batchURL = resultDir
        vc.configureFromDatabase(db)

        // Sample column and Inspector Sample Filter use the recorded name.
        XCTAssertEqual(vc.sampleEntries.map(\.id), ["SRRTEST1"])
        XCTAssertEqual(vc.samplePickerState.selectedSamples, ["SRRTEST1"])
        XCTAssertEqual(vc.testTableView.currentSampleID, "SRRTEST1")

        let tree = try XCTUnwrap(vc.testTableView.tree)
        XCTAssertEqual(tree.node(taxId: 10298)?.readsClade, 370, "the S1 row below species is shown")
        XCTAssertNotNil(tree.node(taxId: 1982251), "a genus Bracken drops is shown")
        XCTAssertEqual(tree.node(taxId: 3044472)?.readsClade, 382, "Kraken 2's count, not Bracken's 386")
        XCTAssertEqual(tree.node(taxId: 3050292)?.brackenReads, 376)
        XCTAssertTrue(vc.testTableView.testingIsBrackenColumnVisible)

        // % is a share of all 1,000 pairs.
        XCTAssertEqual(tree.totalReads, 1_000)
        XCTAssertEqual(tree.node(taxId: 3044472)?.fractionClade ?? 0, 0.382, accuracy: 1e-9)

        // The reopened tree matches what the post-run view shows.
        let postRun = try ClassificationResult.load(from: resultDir).tree
        XCTAssertEqual(
            Set(tree.allNodes().filter { $0.rank != .unclassified }.map(\.taxId)),
            Set(postRun.allNodes().filter { $0.rank != .unclassified }.map(\.taxId))
        )
    }

    func testStaleDatabaseIsRebuiltOnceWhenReportsArePresent() throws {
        let resultDir = try makeResultFolder()
        let db = try buildDatabase(in: resultDir)
        XCTAssertFalse(MainSplitViewController.shouldRebuildStaleKraken2Database(db, resultURL: resultDir))

        let dbURL = resultDir.appendingPathComponent("kraken2.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            handle,
            "DELETE FROM metadata WHERE key = '\(Kraken2Database.formatVersionMetadataKey)'",
            nil, nil, nil
        ), SQLITE_OK)
        sqlite3_close(handle)

        let legacy = try Kraken2Database(at: dbURL)
        XCTAssertTrue(MainSplitViewController.kraken2DatabaseSourcesAvailable(in: resultDir))
        XCTAssertTrue(MainSplitViewController.shouldRebuildStaleKraken2Database(legacy, resultURL: resultDir))

        Kraken2StaleDatabaseRebuilds.markAttempted(resultDir)
        XCTAssertFalse(
            MainSplitViewController.shouldRebuildStaleKraken2Database(legacy, resultURL: resultDir),
            "a folder is rebuilt at most once per session"
        )

        let noReports = tempRoot.appendingPathComponent("kraken2-no-reports")
        try FileManager.default.createDirectory(at: noReports, withIntermediateDirectories: true)
        XCTAssertFalse(MainSplitViewController.kraken2DatabaseSourcesAvailable(in: noReports))
    }

    func testInspectorDetailsForReopenedSingleResultNameTheDatabase() throws {
        let resultDir = try makeResultFolder()
        let details = try XCTUnwrap(MainSplitViewController.singleKraken2ResultInspectorDetails(resultURL: resultDir))
        XCTAssertEqual(details.parameters["Database"], "Viral 20260626")
        XCTAssertEqual(details.parameters["Tool Version"], "Kraken2 2.17.1")
        XCTAssertEqual(details.parameters["Bracken Version"], "3.0.1")
        XCTAssertEqual(details.parameters["Confidence"], "0.20")
        XCTAssertEqual(details.sourceSamples.map(\.sampleId), ["SRRTEST1"])
        XCTAssertNotNil(details.timestamp)
    }
}
