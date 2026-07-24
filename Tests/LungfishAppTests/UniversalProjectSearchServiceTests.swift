// UniversalProjectSearchServiceTests.swift - App-layer tests for universal project search orchestration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishWorkflow
@testable import LungfishApp

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

    func testRebuildWritesIndexProvenanceSidecar() async throws {
        let projectURL = try makeProject(named: "project-provenance.lungfish")
        try writeManifest(
            [
                "sample_name": "Air Sample 01",
                "collection_date": "2026-03-01",
            ],
            to: projectURL.appendingPathComponent("manifest.json")
        )

        let service = UniversalProjectSearchService()
        _ = try await service.rebuild(projectURL: projectURL)

        let databaseURL = projectURL.appendingPathComponent(".universal-search.db")
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: databaseURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.workflowName, "lungfish app universal-search")
        XCTAssertEqual(envelope.toolName, "Lungfish.app universal-search")
        XCTAssertEqual(envelope.output?.path, databaseURL.path)
        XCTAssertEqual(envelope.output?.format, .sqlite)
        XCTAssertNotNil(envelope.output?.checksumSHA256)
        XCTAssertFalse(
            envelope.files.contains { $0.path == projectURL.path },
            "Search-cache provenance must not recursively hash the entire project"
        )
        XCTAssertEqual(envelope.options.resolvedDefaults["projectPath"]?.stringValue, projectURL.path)
        XCTAssertEqual(envelope.options.explicit["operation"]?.stringValue, "rebuild")
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

        let service = UniversalProjectSearchService()
        await service.scheduleUpdate(
            projectURL: projectURL,
            changedPaths: [firstBundle],
            delaySeconds: 0.05
        )
        await service.scheduleUpdate(
            projectURL: projectURL,
            changedPaths: [secondBundle, firstBundle],
            delaySeconds: 0.05
        )

        let sidecarURL = ProvenanceRecorder.fileSidecarURL(
            for: projectURL.appendingPathComponent(".universal-search.db")
        )
        try await waitForFile(at: sidecarURL)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.options.explicit["operation"]?.stringValue, "update")
        XCTAssertEqual(envelope.options.explicit["changedPathCount"]?.integerValue, 2)
        XCTAssertEqual(
            Set(envelope.options.explicit["changedPaths"]?.arrayValue?.compactMap(\.stringValue) ?? []),
            Set([firstBundle.standardizedFileURL.path, secondBundle.standardizedFileURL.path])
        )

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

    private func waitForFile(at url: URL, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(url.path)")
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
