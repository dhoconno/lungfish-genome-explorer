// Kraken2DatabaseTests.swift - Unit tests for Kraken2Database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
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

    func testParentTaxIdAndDepthStored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "s1", taxonName: "root", taxId: 1, rank: "R",
                        readsDirect: 10, readsClade: 1000, percentage: 100.0,
                        parentTaxId: nil, depth: 0, fractionDirect: 0.01),
            makeTestRow(sample: "s1", taxonName: "Bacteria", taxId: 2, rank: "D",
                        readsDirect: 500, readsClade: 800, percentage: 80.0,
                        parentTaxId: 1, depth: 1, fractionDirect: 0.5),
        ]
        let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [:])

        let fetched = try db.fetchRows(samples: ["s1"])
        let bacteria = fetched.first { $0.taxId == 2 }!
        XCTAssertEqual(bacteria.parentTaxId, 1)
        XCTAssertEqual(bacteria.depth, 1)
        XCTAssertEqual(bacteria.fractionDirect, 0.5, accuracy: 0.001)

        let root = fetched.first { $0.taxId == 1 }!
        XCTAssertNil(root.parentTaxId)
        XCTAssertEqual(root.depth, 0)
    }

    func testFetchTree() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "s1", taxonName: "root", taxId: 1, rank: "R",
                        readsDirect: 10, readsClade: 1000, percentage: 100.0,
                        parentTaxId: nil, depth: 0, fractionDirect: 0.01),
            makeTestRow(sample: "s1", taxonName: "Bacteria", taxId: 2, rank: "D",
                        readsDirect: 500, readsClade: 800, percentage: 80.0,
                        parentTaxId: 1, depth: 1, fractionDirect: 0.5),
            makeTestRow(sample: "s1", taxonName: "Viruses", taxId: 10239, rank: "D",
                        readsDirect: 100, readsClade: 200, percentage: 20.0,
                        parentTaxId: 1, depth: 1, fractionDirect: 0.1),
        ]
        let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [
            "total_reads_s1": "1100",
            "classified_reads_s1": "1000",
            "unclassified_reads_s1": "100",
        ])

        let tree = try db.fetchTree(sample: "s1")
        XCTAssertEqual(tree.root.taxId, 1)
        XCTAssertEqual(tree.root.children.count, 2)
        XCTAssertEqual(tree.totalReads, 1100)
        XCTAssertEqual(tree.classifiedReads, 1000)
        XCTAssertEqual(tree.unclassifiedReads, 100)

        let bacteria = tree.root.children.first { $0.taxId == 2 }!
        XCTAssertEqual(bacteria.name, "Bacteria")
        XCTAssertEqual(bacteria.readsClade, 800)
        XCTAssertEqual(bacteria.parent?.taxId, 1)
    }

    func testRefreshSampleMetadataCacheStoresTSVFieldsBySample() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "S1", taxonName: "root", taxId: 1, rank: "R", parentTaxId: nil, depth: 0),
            makeTestRow(sample: "S2", taxonName: "root", taxId: 1, rank: "R", parentTaxId: nil, depth: 0),
        ]
        let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [:])
        let store = try SampleMetadataStore(
            csvData: Data("sample_id\tcity\tcollection_date\nS1\tDallas\t2024-01-05\nS2\tAustin\t2024-02-01\n".utf8),
            knownSampleIds: Set(["S1", "S2"])
        )

        try db.refreshSampleMetadataCache(store: store)

        let cities = try db.fetchMetadataValues(field: "city")
        XCTAssertEqual(cities["S1"], "Dallas")
        XCTAssertEqual(cities["S2"], "Austin")

        let dates = try db.fetchMetadataValues(field: "collection_date")
        XCTAssertEqual(dates["S1"], "2024-01-05")
        XCTAssertEqual(dates["S2"], "2024-02-01")
    }

    func testMetadataFilterReturnsMatchingSamples() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = [
            makeTestRow(sample: "S1", taxonName: "root", taxId: 1, rank: "R", parentTaxId: nil, depth: 0),
            makeTestRow(sample: "S2", taxonName: "root", taxId: 1, rank: "R", parentTaxId: nil, depth: 0),
            makeTestRow(sample: "S3", taxonName: "root", taxId: 1, rank: "R", parentTaxId: nil, depth: 0),
        ]
        let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [:])
        let store = try SampleMetadataStore(
            csvData: Data("sample_id\tcity\nS1\tDallas\nS2\tAustin\nS3\tDallas\n".utf8),
            knownSampleIds: Set(["S1", "S2", "S3"])
        )

        try db.refreshSampleMetadataCache(store: store)

        let sampleIds = try db.filterSamplesByMetadata([
            .init(field: "city", op: .contains, value: "Dallas")
        ])

        XCTAssertEqual(Set(sampleIds), Set(["S1", "S3"]))
    }

    func testSearchPrunedHierarchyReturnsMatchingTaxaAndAncestors() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = makeCoronavirusRows()
        let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [:])

        let result = try db.searchPrunedHierarchy(taxonQuery: "coronavirus", sampleIds: ["S1", "S2", "S3"])

        XCTAssertEqual(Set(result.matchingSamples), Set(["S1", "S3"]))
        XCTAssertTrue(result.rows.contains(where: { $0.sample == "S1" && $0.taxonName == "Coronaviridae" }))
        XCTAssertTrue(result.rows.contains(where: { $0.sample == "S1" && $0.taxonName == "root" }))
        XCTAssertTrue(result.rows.contains(where: { $0.sample == "S3" && $0.taxonName == "Betacoronavirus" }))
        XCTAssertFalse(result.rows.contains(where: { $0.sample == "S2" && $0.taxonName == "Influenza A virus" }))
    }

    func testSearchPrunedHierarchyRespectsMetadataFilteredSamples() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        let rows = makeCoronavirusRows()
        let db = try Kraken2Database.create(at: dbURL, rows: rows, metadata: [:])
        let store = try SampleMetadataStore(
            csvData: Data("sample_id\tcity\nS1\tDallas\nS2\tAustin\nS3\tHouston\n".utf8),
            knownSampleIds: Set(["S1", "S2", "S3"])
        )

        try db.refreshSampleMetadataCache(store: store)
        let filtered = try db.filterSamplesByMetadata([
            .init(field: "city", op: .equal, value: "Dallas")
        ])
        let result = try db.searchPrunedHierarchy(taxonQuery: "coronavirus", sampleIds: filtered)

        XCTAssertEqual(result.matchingSamples, ["S1"])
        XCTAssertTrue(result.rows.allSatisfy { $0.sample == "S1" })
    }

    // MARK: - Helpers

    private func makeCoronavirusRows() -> [Kraken2ClassificationRow] {
        [
            makeTestRow(sample: "S1", taxonName: "root", taxId: 1, rank: "R", readsDirect: 0, readsClade: 1000, percentage: 100, parentTaxId: nil, depth: 0),
            makeTestRow(sample: "S1", taxonName: "Viruses", taxId: 10239, rank: "D", readsDirect: 0, readsClade: 400, percentage: 40, parentTaxId: 1, depth: 1),
            makeTestRow(sample: "S1", taxonName: "Riboviria", taxId: 2559587, rank: "K", readsDirect: 0, readsClade: 300, percentage: 30, parentTaxId: 10239, depth: 2),
            makeTestRow(sample: "S1", taxonName: "Coronaviridae", taxId: 11118, rank: "F", readsDirect: 20, readsClade: 200, percentage: 20, parentTaxId: 2559587, depth: 3),
            makeTestRow(sample: "S1", taxonName: "Betacoronavirus", taxId: 694002, rank: "G", readsDirect: 10, readsClade: 120, percentage: 12, parentTaxId: 11118, depth: 4),
            makeTestRow(sample: "S1", taxonName: "Influenza A virus", taxId: 11320, rank: "S", readsDirect: 40, readsClade: 40, percentage: 4, parentTaxId: 2559587, depth: 3),

            makeTestRow(sample: "S2", taxonName: "root", taxId: 1, rank: "R", readsDirect: 0, readsClade: 900, percentage: 100, parentTaxId: nil, depth: 0),
            makeTestRow(sample: "S2", taxonName: "Viruses", taxId: 10239, rank: "D", readsDirect: 0, readsClade: 200, percentage: 22.2, parentTaxId: 1, depth: 1),
            makeTestRow(sample: "S2", taxonName: "Riboviria", taxId: 2559587, rank: "K", readsDirect: 0, readsClade: 150, percentage: 16.7, parentTaxId: 10239, depth: 2),
            makeTestRow(sample: "S2", taxonName: "Influenza A virus", taxId: 11320, rank: "S", readsDirect: 50, readsClade: 50, percentage: 5.6, parentTaxId: 2559587, depth: 3),

            makeTestRow(sample: "S3", taxonName: "root", taxId: 1, rank: "R", readsDirect: 0, readsClade: 700, percentage: 100, parentTaxId: nil, depth: 0),
            makeTestRow(sample: "S3", taxonName: "Viruses", taxId: 10239, rank: "D", readsDirect: 0, readsClade: 300, percentage: 42.8, parentTaxId: 1, depth: 1),
            makeTestRow(sample: "S3", taxonName: "Riboviria", taxId: 2559587, rank: "K", readsDirect: 0, readsClade: 200, percentage: 28.6, parentTaxId: 10239, depth: 2),
            makeTestRow(sample: "S3", taxonName: "Coronaviridae", taxId: 11118, rank: "F", readsDirect: 15, readsClade: 150, percentage: 21.4, parentTaxId: 2559587, depth: 3),
            makeTestRow(sample: "S3", taxonName: "Betacoronavirus", taxId: 694002, rank: "G", readsDirect: 8, readsClade: 80, percentage: 11.4, parentTaxId: 11118, depth: 4),
        ]
    }

    private func makeTestRow(
        sample: String,
        taxonName: String,
        taxId: Int,
        rank: String? = nil,
        rankDisplayName: String? = nil,
        readsDirect: Int = 50,
        readsClade: Int = 100,
        percentage: Double = 1.0,
        parentTaxId: Int? = nil,
        depth: Int = 0,
        fractionDirect: Double = 0.0
    ) -> Kraken2ClassificationRow {
        Kraken2ClassificationRow(
            sample: sample,
            taxonName: taxonName,
            taxId: taxId,
            rank: rank,
            rankDisplayName: rankDisplayName,
            readsDirect: readsDirect,
            readsClade: readsClade,
            percentage: percentage,
            parentTaxId: parentTaxId,
            depth: depth,
            fractionDirect: fractionDirect
        )
    }
}
