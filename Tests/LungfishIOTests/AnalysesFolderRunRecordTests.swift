// AnalysesFolderRunRecordTests.swift - Analysis directories stay hidden until their run completes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishIO

final class AnalysesFolderRunRecordTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyses-run-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    func testCreatedAnalysisDirectoryCarriesARunRecordFromTheStart() throws {
        let dir = try AnalysesFolder.createAnalysisDirectory(
            tool: "taxtriage", in: projectURL, isBatch: true, command: "lungfish-cli taxtriage --input a.fastq"
        )
        XCTAssertTrue(AnalysesFolder.isAnalysisIncomplete(dir))
        let record = try XCTUnwrap(AnalysisRunRecord.load(from: dir))
        XCTAssertEqual(record.analysisName, "TaxTriage")
        XCTAssertEqual(record.command, "lungfish-cli taxtriage --input a.fastq")
        XCTAssertNotNil(AnalysesFolder.readAnalysisMetadata(from: dir))
    }

    func testCreateLeavesNoStagingEntriesBehind() throws {
        _ = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL)
        let analyses = projectURL.appendingPathComponent(AnalysesFolder.directoryName)
        let names = try FileManager.default.contentsOfDirectory(atPath: analyses.path)
        XCTAssertEqual(names.count, 1, "unexpected entries: \(names)")
        XCTAssertTrue(names[0].hasPrefix("kraken2-"))
    }

    func testCollisionStillGetsASuffix() throws {
        let date = Date(timeIntervalSince1970: 1_775_398_200)
        let first = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL, date: date)
        let second = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL, date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, first.lastPathComponent + "-2")
        XCTAssertTrue(AnalysesFolder.isAnalysisIncomplete(second))
    }

    func testListAnalysesSkipsIncompleteRunsUntilMarkedComplete() throws {
        let dir = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL)
        XCTAssertTrue(try AnalysesFolder.listAnalyses(in: projectURL).isEmpty)

        XCTAssertTrue(AnalysesFolder.markAnalysisComplete(dir))
        let listed = try AnalysesFolder.listAnalyses(in: projectURL)
        XCTAssertEqual(listed.map(\.url.lastPathComponent), [dir.lastPathComponent])
    }

    func testLegacyDirectoryWithoutRecordIsListed() throws {
        let analyses = try AnalysesFolder.url(for: projectURL)
        let legacy = analyses.appendingPathComponent("kraken2-2026-01-01T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertFalse(AnalysesFolder.isAnalysisIncomplete(legacy))
        XCTAssertEqual(try AnalysesFolder.listAnalyses(in: projectURL).count, 1)
    }

    func testIncompleteRunsAreEnumeratedWithTheirRecords() throws {
        let running = try AnalysesFolder.createAnalysisDirectory(tool: "taxtriage", in: projectURL, isBatch: true)
        let done = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL)
        AnalysesFolder.markAnalysisComplete(done)

        let grouping = try AnalysesFolder.url(for: projectURL).appendingPathComponent("My Group", isDirectory: true)
        try FileManager.default.createDirectory(at: grouping, withIntermediateDirectories: true)
        let nested = grouping.appendingPathComponent("esviritu-batch-2026-01-01T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try AnalysisRunRecord.begin(AnalysisRunRecord(analysisName: "EsViritu"), in: nested)

        let incomplete = AnalysesFolder.incompleteAnalysisRuns(in: projectURL)
        XCTAssertEqual(
            Set(incomplete.map { $0.directory.standardizedFileURL.path }),
            Set([running.standardizedFileURL.path, nested.standardizedFileURL.path])
        )
        XCTAssertEqual(incomplete.first { $0.directory.lastPathComponent == nested.lastPathComponent }?.record?.analysisName, "EsViritu")
    }

    func testEnclosingIncompleteDirectoryFindsTheBatchRoot() throws {
        let batch = try AnalysesFolder.createAnalysisDirectory(tool: "spades", in: projectURL, isBatch: true)
        let sample = try AnalysesFolder.batchSampleDirectory(named: "S1", in: batch)
        XCTAssertFalse(AnalysesFolder.isAnalysisIncomplete(sample))
        XCTAssertEqual(
            AnalysesFolder.enclosingIncompleteAnalysisDirectory(for: sample)?.standardizedFileURL.path,
            batch.standardizedFileURL.path
        )
        AnalysesFolder.markAnalysisComplete(batch)
        XCTAssertNil(AnalysesFolder.enclosingIncompleteAnalysisDirectory(for: sample))
    }

    func testDiscardingAFailedRunStillRemovesIt() throws {
        let dir = try AnalysesFolder.createAnalysisDirectory(tool: "minimap2", in: projectURL)
        XCTAssertTrue(AnalysesFolder.discardFailedAnalysisDirectory(dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
