// UniversalProjectSearchServiceTests.swift - App-layer tests for universal project search orchestration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os
import XCTest
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishApp

/// The batches an observer saw, safe to read from the test while the service writes it.
private final class BatchLog: Sendable {
    private let batches = OSAllocatedUnfairLock<[[URL]]>(initialState: [])
    func append(_ paths: [URL]) { batches.withLock { $0.append(paths) } }
    var snapshot: [[URL]] { batches.withLock { $0 } }
    var count: Int { snapshot.count }
}

final class UniversalProjectSearchServiceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniversalProjectSearchServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testSearchBuildsIndexOnDemandFromManifestMetadata() async throws {
        let projectURL = try makeProject(named: "project-a.lungfish")
        try writeManifest(
            [
                "sample_name": "Air Sample 01",
                "collection_date": "2025-01-12",
                "notes": "north wing",
            ],
            to: projectURL.appendingPathComponent("manifest.json")
        )

        let service = UniversalProjectSearchService()
        let results = try await service.search(
            projectURL: projectURL,
            query: "sample:air date>=2025-01-01 date<=2025-01-31",
            limit: 50,
            ensureIndexed: true
        )

        XCTAssertTrue(results.contains(where: { $0.kind == "manifest_document" }))

        let stats = try await service.indexStats(projectURL: projectURL)
        XCTAssertGreaterThan(stats.entityCount, 0)
        XCTAssertGreaterThan(stats.attributeCount, 0)
    }

    func testRebuildIndexesFastqMetadataForRoleAndDateQueries() async throws {
        let projectURL = try makeProject(named: "project-b.lungfish")
        _ = try makeFASTQBundle(
            in: projectURL,
            name: "AirSampleA",
            metadataRows: [
                ("sample_name", "Air Sample 01"),
                ("sample_role", "test_sample"),
                ("metadata_template", "air_sample"),
                ("collection_date", "2025-01-15"),
            ]
        )

        let service = UniversalProjectSearchService()
        let build = try await service.rebuild(projectURL: projectURL)
        XCTAssertGreaterThanOrEqual(build.indexedEntities, 1)

        let results = try await service.search(
            projectURL: projectURL,
            query: "type:fastq_dataset role:test_sample date>=2025-01-01 date<=2025-01-31",
            limit: 20,
            ensureIndexed: true
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.kind, "fastq_dataset")
    }

    /// The index is a derived cache that opening a project builds again (plan row S12), so a
    /// rebuild leaves the database and no provenance record beside it. `lungfish-cli
    /// universal-search --reindex` keeps its record, and `UniversalSearchCommandTests` pins that.
    func testRebuildBuildsTheIndexAndWritesNoProvenanceRecord() async throws {
        let projectURL = try makeProject(named: "project-provenance.lungfish")
        try writeManifest(
            [
                "sample_name": "Air Sample 01",
                "collection_date": "2026-03-01",
            ],
            to: projectURL.appendingPathComponent("manifest.json")
        )

        let service = UniversalProjectSearchService()
        let stats = try await service.rebuild(projectURL: projectURL)

        let databaseURL = projectURL.appendingPathComponent(".universal-search.db")
        XCTAssertGreaterThan(stats.indexedEntities, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        assertNoProvenanceRecord(for: databaseURL, in: projectURL)
    }

    func testSearchBuildsTheIndexOnDemandAndWritesNoProvenanceRecord() async throws {
        let projectURL = try makeProject(named: "project-on-demand.lungfish")
        try writeManifest(
            ["sample_name": "Air Sample 02", "collection_date": "2026-03-02"],
            to: projectURL.appendingPathComponent("manifest.json")
        )

        let service = UniversalProjectSearchService()
        let results = try await service.search(projectURL: projectURL, query: "sample:air", ensureIndexed: true)

        XCTAssertFalse(results.isEmpty)
        assertNoProvenanceRecord(for: projectURL.appendingPathComponent(".universal-search.db"), in: projectURL)
    }

    func testScheduledUpdatesCoalesceChangedPathsIntoOneBoundedBatch() async throws {
        let projectURL = try makeProject(named: "project-update-burst.lungfish")
        let firstBundle = try makeFASTQBundle(
            in: projectURL,
            name: "FirstSample",
            metadataRows: [("sample_name", "First Sample")]
        )
        let secondBundle = try makeFASTQBundle(
            in: projectURL,
            name: "SecondSample",
            metadataRows: [("sample_name", "Second Sample")]
        )

        // The debounce window is wide enough that the second call lands inside
        // it even under the parallel unit tier's load.
        let service = UniversalProjectSearchService()
        let batches = BatchLog()
        await service.setOnUpdate { _, paths in batches.append(paths) }
        await service.scheduleUpdate(
            projectURL: projectURL,
            changedPaths: [firstBundle],
            delaySeconds: 1
        )
        await service.scheduleUpdate(
            projectURL: projectURL,
            changedPaths: [secondBundle, firstBundle],
            delaySeconds: 1
        )

        let flushed = await waitUntil(timeout: .seconds(30)) { batches.count >= 1 }
        XCTAssertTrue(flushed, "The debounced update never ran.")
        // Wait out another debounce window, so a second batch would have shown by now.
        try await Task.sleep(for: .milliseconds(1_500))

        XCTAssertEqual(batches.snapshot.count, 1, "The two calls make one batch.")
        XCTAssertEqual(
            batches.snapshot.first.map { Set($0.map(\.standardizedFileURL.path)) },
            Set([firstBundle.standardizedFileURL.path, secondBundle.standardizedFileURL.path]),
            "The batch holds each changed path once."
        )
        assertNoProvenanceRecord(for: projectURL.appendingPathComponent(".universal-search.db"), in: projectURL)

        let firstResults = try await service.search(
            projectURL: projectURL,
            query: "sample:first",
            ensureIndexed: false
        )
        let secondResults = try await service.search(
            projectURL: projectURL,
            query: "sample:second",
            ensureIndexed: false
        )
        XCTAssertEqual(firstResults.count, 1)
        XCTAssertEqual(secondResults.count, 1)
    }

    func testSearchLimitRestrictsReturnedRows() async throws {
        let projectURL = try makeProject(named: "project-c.lungfish")
        for index in 1...3 {
            try writeManifest(
                [
                    "sample_name": "Air Sample \(index)",
                    "collection_date": "2025-01-\(String(format: "%02d", index))",
                ],
                to: projectURL.appendingPathComponent("manifest-\(index)-result.json")
            )
        }

        let service = UniversalProjectSearchService()
        let results = try await service.search(
            projectURL: projectURL,
            query: "sample:air",
            limit: 2,
            ensureIndexed: true
        )

        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Fixtures

    private func makeProject(named name: String) throws -> URL {
        let projectURL = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        return projectURL
    }

    private func writeManifest(_ payload: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url)
    }

    /// The index is a derived cache. Nothing beside the project holds a record of it, whatever the
    /// record's name, so the check lists the project folder as well as the one sidecar name.
    private func assertNoProvenanceRecord(
        for databaseURL: URL,
        in projectURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: databaseURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sidecar.path),
            "The search index is a derived cache, but \(sidecar.lastPathComponent) records it.",
            file: file, line: line
        )
        let cacheFiles = ["", "-wal", "-shm"].map { databaseURL.lastPathComponent + $0 }
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: projectURL.path)) ?? [])
            .filter { $0.hasPrefix(databaseURL.lastPathComponent) && !cacheFiles.contains($0) }
        XCTAssertEqual(leftovers, [], "Only the database and its write-ahead log belong beside the project.", file: file, line: line)
    }

    @discardableResult
    private func makeFASTQBundle(
        in projectURL: URL,
        name: String,
        metadataRows: [(String, String)]
    ) throws -> URL {
        let bundleURL = projectURL.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fastqText = """
        @read1
        ACGTACGT
        +
        IIIIIIII
        """
        try fastqText.write(
            to: bundleURL.appendingPathComponent("reads.fastq"),
            atomically: true,
            encoding: .utf8
        )

        var csv = "key,value\n"
        for (key, value) in metadataRows {
            csv += "\(key),\(value)\n"
        }
        try csv.write(
            to: bundleURL.appendingPathComponent("metadata.csv"),
            atomically: true,
            encoding: .utf8
        )

        return bundleURL
    }
}
