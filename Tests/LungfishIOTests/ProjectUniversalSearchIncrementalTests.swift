// ProjectUniversalSearchIncrementalTests.swift - Tests for incremental index updates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class ProjectUniversalSearchIncrementalTests: XCTestCase {

    private var tempDir: URL!
    private var index: ProjectUniversalSearchIndex!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncrementalSearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        index = try ProjectUniversalSearchIndex(projectURL: tempDir)
    }

    override func tearDown() async throws {
        index = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDeleteByPath_removesMatchingEntities() throws {
        let bundleURL = tempDir.appendingPathComponent("SRR123.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let previewURL = bundleURL.appendingPathComponent("preview.fastq")
        try "@SEQ1\nACGT\n+\nIIII\n".write(to: previewURL, atomically: true, encoding: .utf8)

        let stats = try index.rebuild()
        XCTAssertGreaterThan(stats.indexedEntities, 0)

        let removed = try index.deleteEntities(matchingPathPrefix: "SRR123.lungfishfastq")
        XCTAssertGreaterThan(removed, 0)

        let results = try index.search(rawQuery: "SRR123")
        XCTAssertEqual(results.count, 0)
    }

    func testUpsertFASTQBundle_addsNewEntity() throws {
        let bundleURL = tempDir.appendingPathComponent("NEW456.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let previewURL = bundleURL.appendingPathComponent("preview.fastq")
        try "@SEQ1\nACGT\n+\nIIII\n".write(to: previewURL, atomically: true, encoding: .utf8)

        let initialStats = try index.indexStats()
        XCTAssertEqual(initialStats.entityCount, 0)

        try index.upsertArtifact(at: bundleURL)

        let afterStats = try index.indexStats()
        XCTAssertGreaterThan(afterStats.entityCount, 0)

        let results = try index.search(rawQuery: "NEW456")
        XCTAssertGreaterThan(results.count, 0)
    }

    func testUpdateChangedPaths_deletesRemovedFiles() throws {
        let bundleURL = tempDir.appendingPathComponent("DEL789.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let previewURL = bundleURL.appendingPathComponent("preview.fastq")
        try "@SEQ1\nACGT\n+\nIIII\n".write(to: previewURL, atomically: true, encoding: .utf8)
        try index.rebuild()

        let beforeResults = try index.search(rawQuery: "DEL789")
        XCTAssertGreaterThan(beforeResults.count, 0)

        try FileManager.default.removeItem(at: bundleURL)

        try index.update(changedPaths: [bundleURL])

        let afterResults = try index.search(rawQuery: "DEL789")
        XCTAssertEqual(afterResults.count, 0)
    }
}
