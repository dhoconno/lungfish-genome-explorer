// EsVirituDatabaseTests.swift - Unit tests for EsVirituDatabase
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class EsVirituDatabaseTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituDatabaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCreateAndOpen() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [makeTestRow(sample: "s1", virusName: "SARS-CoV-2", accession: "NC_045512.2",
                                assembly: "GCF_009858895.2", readCount: 1000)]
        let db = try EsVirituDatabase.create(at: dbURL, rows: rows, metadata: ["tool": "test"])
        XCTAssertEqual(try db.fetchRows(samples: ["s1"]).count, 1)
    }

    func testFetchRowsFiltersBySample() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "s1", virusName: "Virus A", accession: "ACC001", assembly: "ASM001", readCount: 100),
            makeTestRow(sample: "s2", virusName: "Virus B", accession: "ACC002", assembly: "ASM002", readCount: 200),
            makeTestRow(sample: "s3", virusName: "Virus C", accession: "ACC003", assembly: "ASM003", readCount: 300),
        ]
        let db = try EsVirituDatabase.create(at: dbURL, rows: rows, metadata: [:])

        let s1Only = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(s1Only.count, 1)
        XCTAssertEqual(s1Only[0].virusName, "Virus A")

        let s1s2 = try db.fetchRows(samples: ["s1", "s2"])
        XCTAssertEqual(s1s2.count, 2)

        let all = try db.fetchRows(samples: ["s1", "s2", "s3"])
        XCTAssertEqual(all.count, 3)
    }

    func testFetchSamples() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "s1", virusName: "Virus A", accession: "ACC001", assembly: "ASM001", readCount: 100),
            makeTestRow(sample: "s1", virusName: "Virus B", accession: "ACC002", assembly: "ASM002", readCount: 200),
            makeTestRow(sample: "s2", virusName: "Virus A", accession: "ACC003", assembly: "ASM003", readCount: 300),
        ]
        let db = try EsVirituDatabase.create(at: dbURL, rows: rows, metadata: [:])

        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.count, 2)
        let s1 = samples.first { $0.sample == "s1" }
        XCTAssertEqual(s1?.detectionCount, 2)
    }

    func testMetadataRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try EsVirituDatabase.create(at: dbURL, rows: [], metadata: [
            "tool_version": "2.1.0",
            "created_at": "2026-04-07",
        ])
        let meta = try db.fetchMetadata()
        XCTAssertEqual(meta["tool_version"], "2.1.0")
        XCTAssertEqual(meta["created_at"], "2026-04-07")
    }

    func testUniqueReadsStored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let row = makeTestRow(sample: "s1", virusName: "SARS-CoV-2", accession: "NC_045512.2",
                              assembly: "GCF_009858895.2", readCount: 500, uniqueReads: 420)
        let db = try EsVirituDatabase.create(at: dbURL, rows: [row], metadata: [:])
        let fetched = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(fetched[0].uniqueReads, 420)
    }

    func testBAMPathStored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let row = makeTestRow(sample: "s1", virusName: "SARS-CoV-2", accession: "NC_045512.2",
                              assembly: "GCF_009858895.2", readCount: 500,
                              bamPath: "/path/to/sample.bam", bamIndexPath: "/path/to/sample.bam.csi")
        let db = try EsVirituDatabase.create(at: dbURL, rows: [row], metadata: [:])
        let fetched = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(fetched[0].bamPath, "/path/to/sample.bam")
        XCTAssertEqual(fetched[0].bamIndexPath, "/path/to/sample.bam.csi")
    }

    func testEmptyDatabase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try EsVirituDatabase.create(at: dbURL, rows: [], metadata: [:])
        XCTAssertEqual(try db.fetchRows(samples: []).count, 0)
        XCTAssertEqual(try db.fetchSamples().count, 0)
    }

    // MARK: - Helpers

    private func makeTestRow(
        sample: String,
        virusName: String,
        accession: String,
        assembly: String,
        readCount: Int,
        uniqueReads: Int? = nil,
        bamPath: String? = nil,
        bamIndexPath: String? = nil
    ) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample,
            virusName: virusName,
            description: nil,
            contigLength: nil,
            segment: nil,
            accession: accession,
            assembly: assembly,
            assemblyLength: nil,
            kingdom: nil,
            phylum: nil,
            tclass: nil,
            torder: nil,
            family: nil,
            genus: nil,
            species: nil,
            subspecies: nil,
            rpkmf: nil,
            readCount: readCount,
            uniqueReads: uniqueReads,
            coveredBases: nil,
            meanCoverage: nil,
            avgReadIdentity: nil,
            pi: nil,
            filteredReadsInSample: nil,
            bamPath: bamPath,
            bamIndexPath: bamIndexPath
        )
    }
}
