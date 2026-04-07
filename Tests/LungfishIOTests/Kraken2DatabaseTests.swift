// Kraken2DatabaseTests.swift - Unit tests for Kraken2Database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class Kraken2DatabaseTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kraken2DatabaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCreateAndOpen() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [makeTestRow(sample: "s1", taxonName: "Virus A", taxId: 12345)]
        let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: ["tool": "kraken2"])
        XCTAssertEqual(try db.fetchRows(samples: ["s1"]).count, 1)
    }

    func testFetchRowsFiltersBySample() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "s1", taxonName: "Virus A", taxId: 111),
            makeTestRow(sample: "s2", taxonName: "Virus B", taxId: 222),
            makeTestRow(sample: "s3", taxonName: "Virus C", taxId: 333),
        ]
        let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [:])

        let s1Only = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(s1Only.count, 1)
        XCTAssertEqual(s1Only[0].taxonName, "Virus A")

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
            makeTestRow(sample: "s1", taxonName: "Virus A", taxId: 101),
            makeTestRow(sample: "s1", taxonName: "Virus B", taxId: 102),
            makeTestRow(sample: "s2", taxonName: "Virus A", taxId: 101),
        ]
        let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [:])

        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.count, 2)
        let s1 = samples.first { $0.sample == "s1" }
        XCTAssertEqual(s1?.taxonCount, 2)
    }

    func testMetadataRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try Kraken2Database.create(at: dbURL, rows: [], metadata: [
            "tool_version": "2.1.3",
            "created_at": "2026-04-07",
        ])
        let meta = try db.fetchMetadata()
        XCTAssertEqual(meta["tool_version"], "2.1.3")
        XCTAssertEqual(meta["created_at"], "2026-04-07")
    }

    func testRankStored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let row = makeTestRow(sample: "s1", taxonName: "Homo sapiens", taxId: 9606,
                              rank: "S", rankDisplayName: "Species")
        let db = try Kraken2Database.create(at: dbURL, rows: [row], metadata: [:])
        let fetched = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(fetched[0].rank, "S")
        XCTAssertEqual(fetched[0].rankDisplayName, "Species")
    }

    func testCladeReadsStored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let row = makeTestRow(sample: "s1", taxonName: "SARS-CoV-2", taxId: 2697049,
                              readsDirect: 120, readsClade: 450, percentage: 3.75)
        let db = try Kraken2Database.create(at: dbURL, rows: [row], metadata: [:])
        let fetched = try db.fetchRows(samples: ["s1"])
        XCTAssertEqual(fetched[0].readsDirect, 120)
        XCTAssertEqual(fetched[0].readsClade, 450)
        XCTAssertEqual(fetched[0].percentage, 3.75, accuracy: 0.0001)
    }

    func testEmptyDatabase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let db = try Kraken2Database.create(at: dbURL, rows: [], metadata: [:])
        XCTAssertEqual(try db.fetchRows(samples: []).count, 0)
        XCTAssertEqual(try db.fetchSamples().count, 0)
    }

    // MARK: - Helpers

    private func makeTestRow(
        sample: String,
        taxonName: String,
        taxId: Int,
        rank: String? = nil,
        rankDisplayName: String? = nil,
        readsDirect: Int = 50,
        readsClade: Int = 100,
        percentage: Double = 1.0
    ) -> Kraken2ClassificationRow {
        Kraken2ClassificationRow(
            sample: sample,
            taxonName: taxonName,
            taxId: taxId,
            rank: rank,
            rankDisplayName: rankDisplayName,
            readsDirect: readsDirect,
            readsClade: readsClade,
            percentage: percentage
        )
    }
}
