// EsVirituReferenceResolverTests.swift - Recorded-version reference resolution for EsViritu evidence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishKit

/// EsViritu aligns against the pangenome FASTA of a managed EsViritu database.
/// The reference shown beside a detection must come from the database version the
/// *result* recorded, not from whatever happens to be installed today, and when
/// that version is gone the fallback must be visible rather than silent.
final class EsVirituReferenceResolverTests: XCTestCase {

    func testResolvesPangenomeFASTAFromTheDatabaseVersionRecordedByTheResult() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let recorded = try fixture.installDatabase(version: "v3.2.4")
        let newer = try fixture.installDatabase(version: "v9.9.9")
        try fixture.writeSampleSidecar(sample: "sample-a", databasePath: recorded)

        let resolver = EsVirituReferenceResolver(databaseRootURL: fixture.databaseRoot)
        let resolution = resolver.resolve(
            resultURL: fixture.batchRoot,
            sampleID: "sample-a",
            contig: "NC_REF.1",
            length: 4_200
        )

        let candidate = try XCTUnwrap(resolution.candidate)
        XCTAssertEqual(candidate.fastaURL, recorded.appendingPathComponent("virus_pathogen_database.fna"))
        XCTAssertNotEqual(candidate.fastaURL.deletingLastPathComponent(), newer)
        XCTAssertEqual(candidate.recordName, "NC_REF.1")
        XCTAssertEqual(candidate.expectedLength, 4_200)
        XCTAssertNil(resolution.reason, "an exact version match needs no explanation")
    }

    func testFallsBackToTheInstalledVersionWithAVisibleReason() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let installed = try fixture.installDatabase(version: "v9.9.9")
        // The result names a version that is no longer on disk.
        try fixture.writeSampleSidecar(
            sample: "sample-a",
            databasePath: fixture.databaseRoot
                .appendingPathComponent("esviritu/esviritu-viral-db/v3.2.4", isDirectory: true)
        )

        let resolver = EsVirituReferenceResolver(databaseRootURL: fixture.databaseRoot)
        let resolution = resolver.resolve(
            resultURL: fixture.batchRoot,
            sampleID: "sample-a",
            contig: "NC_REF.1",
            length: 4_200
        )

        let candidate = try XCTUnwrap(resolution.candidate)
        XCTAssertEqual(
            candidate.fastaURL.resolvingSymlinksInPath(),
            installed.appendingPathComponent("virus_pathogen_database.fna").resolvingSymlinksInPath()
        )
        let reason = try XCTUnwrap(resolution.reason, "a substituted database version must be explained")
        XCTAssertTrue(reason.contains("v3.2.4"), reason)
        XCTAssertTrue(reason.contains("v9.9.9"), reason)
    }

    func testMissingDatabaseYieldsNoCandidateAndDoesNotCrash() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeSampleSidecar(
            sample: "sample-a",
            databasePath: fixture.databaseRoot
                .appendingPathComponent("esviritu/esviritu-viral-db/v3.2.4", isDirectory: true)
        )

        let resolver = EsVirituReferenceResolver(databaseRootURL: fixture.databaseRoot)
        let resolution = resolver.resolve(
            resultURL: fixture.batchRoot,
            sampleID: "sample-a",
            contig: "NC_REF.1",
            length: 4_200
        )

        XCTAssertNil(resolution.candidate)
        XCTAssertNotNil(resolution.reason)
    }

    func testMissingSidecarStillResolvesTheInstalledDatabaseWithAReason() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let installed = try fixture.installDatabase(version: "v3.2.4")

        let resolver = EsVirituReferenceResolver(databaseRootURL: fixture.databaseRoot)
        let resolution = resolver.resolve(
            resultURL: fixture.batchRoot,
            sampleID: "sample-a",
            contig: "NC_REF.1",
            length: 4_200
        )

        let candidate = try XCTUnwrap(resolution.candidate)
        XCTAssertEqual(
            candidate.fastaURL.resolvingSymlinksInPath(),
            installed.appendingPathComponent("virus_pathogen_database.fna").resolvingSymlinksInPath()
        )
        XCTAssertNotNil(resolution.reason, "an unrecorded database version must be explained")
    }

    /// A single-sample result keeps its sidecar at the result root rather than in a
    /// per-sample subdirectory.
    func testResolvesFromASidecarAtTheResultRoot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let recorded = try fixture.installDatabase(version: "v3.2.4")
        try fixture.writeSidecar(in: fixture.batchRoot, sample: "sample-a", databasePath: recorded)

        let resolver = EsVirituReferenceResolver(databaseRootURL: fixture.databaseRoot)
        let resolution = resolver.resolve(
            resultURL: fixture.batchRoot,
            sampleID: "sample-a",
            contig: "NC_REF.1",
            length: 4_200
        )

        XCTAssertEqual(
            try XCTUnwrap(resolution.candidate).fastaURL,
            recorded.appendingPathComponent("virus_pathogen_database.fna")
        )
        XCTAssertNil(resolution.reason)
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let databaseRoot: URL
        let batchRoot: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("EsVirituReferenceResolver-\(UUID().uuidString)", isDirectory: true)
            databaseRoot = root.appendingPathComponent("databases", isDirectory: true)
            batchRoot = root.appendingPathComponent("esviritu-batch-abc123", isDirectory: true)
            try FileManager.default.createDirectory(at: databaseRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: batchRoot, withIntermediateDirectories: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func installDatabase(version: String) throws -> URL {
            let directory = databaseRoot
                .appendingPathComponent("esviritu/esviritu-viral-db/\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ">NC_REF.1\nACGT\n".write(
                to: directory.appendingPathComponent("virus_pathogen_database.fna"),
                atomically: true,
                encoding: .utf8
            )
            return directory
        }

        func writeSampleSidecar(sample: String, databasePath: URL) throws {
            let directory = batchRoot.appendingPathComponent(sample, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeSidecar(in: directory, sample: sample, databasePath: databasePath)
        }

        func writeSidecar(in directory: URL, sample: String, databasePath: URL) throws {
            let json: [String: Any] = [
                "config": [
                    "inputFiles": [directory.appendingPathComponent("\(sample).fastq").absoluteString],
                    "isPairedEnd": false,
                    "sampleName": sample,
                    "outputDirectory": directory.absoluteString,
                    "databasePath": databasePath.absoluteString,
                ],
                "detectionPath": "detections.tsv",
                "virusCount": 1,
                "runtime": 1.0,
                "toolVersion": "0.2.3",
                "savedAt": "2026-08-01T00:00:00Z",
            ]
            let data = try JSONSerialization.data(withJSONObject: json)
            try data.write(to: directory.appendingPathComponent("esviritu-result.json"))
        }
    }
}
