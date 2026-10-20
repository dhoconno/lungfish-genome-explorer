// TaxonomyMetadataCacheRefreshTests.swift - Opening a Kraken2 result again leaves kraken2.sqlite as it was
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.35, REFRESH-SAMPLE-CACHE (M865). The view refreshes the database's sample metadata cache
// whenever it is handed the result's metadata. That rewrote `kraken2.sqlite` on the main actor at every open, so a
// verify or replay made afterwards saw another input digest for the same payload. The refresh now reads the cache
// rows first, writes only on a difference, and runs off the main actor behind a handle the tests await.

import CryptoKit
import XCTest
import LungfishCore
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class TaxonomyMetadataCacheRefreshTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxonomyMetadataCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private static let samples = ["sample-A", "sample-B"]

    private func writeMetadataTable(groups: [String], in folder: URL) throws {
        let table = zip(Self.samples, groups).map { "\($0)\t\($1)\n" }.joined()
        try Data("Sample\tGroup\n\(table)".utf8)
            .write(to: folder.appendingPathComponent("metadata/sample_metadata.tsv"))
    }

    /// Opens the result again, as the sidebar does when it installs the folder's metadata on the view.
    private func open(_ view: TaxonomyViewController, _ folder: URL) {
        view.applySampleMetadata(SampleMetadataStore.load(from: folder, knownSampleIds: Set(Self.samples)))
    }

    /// A folder with a two-sample Kraken2 database and a metadata table, shown and opened once.
    private func makeShownResult() throws -> (view: TaxonomyViewController, folder: URL, database: URL) {
        let folder = scratch.appendingPathComponent("kraken2-batch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("metadata", isDirectory: true), withIntermediateDirectories: true
        )
        var rows: [Kraken2ClassificationRow] = []
        for (sample, name, reads) in [("sample-A", "Virus A", 40), ("sample-B", "Virus B", 20)] {
            rows.append(Kraken2ClassificationRow(
                sample: sample, taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root",
                readsDirect: 0, readsClade: reads, percentage: 100, parentTaxId: nil, depth: 0
            ))
            rows.append(Kraken2ClassificationRow(
                sample: sample, taxonName: name, taxId: reads, rank: "S", rankDisplayName: "Species",
                readsDirect: reads, readsClade: reads, percentage: 100, parentTaxId: 1, depth: 1
            ))
        }
        let databaseURL = folder.appendingPathComponent("kraken2.sqlite")
        let database = try Kraken2Database.create(
            at: databaseURL,
            rows: rows,
            metadata: ["total_reads_sample-A": "40", "total_reads_sample-B": "20"]
        )
        try writeMetadataTable(groups: ["case", "control"], in: folder)
        let view = TaxonomyViewController()
        _ = view.view
        view.configureFromDatabase(database)
        open(view, folder)
        return (view, folder, databaseURL)
    }

    private static func digest(of url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url))
    }

    /// Opening a result a second time sets the same metadata, and the database already holds those cache rows, so
    /// `kraken2.sqlite` keeps its SHA-256 and a record that named it still matches (UX walk, `votes/UX.md:67`).
    func testOpeningAKraken2ResultTwiceLeavesItsDatabaseBytesUnchanged() async throws {
        let shown = try makeShownResult()
        await shown.view.sampleMetadataCacheRefresh?.value
        let afterFirstOpen = try Self.digest(of: shown.database)

        open(shown.view, shown.folder)
        await shown.view.sampleMetadataCacheRefresh?.value

        XCTAssertEqual(try Self.digest(of: shown.database), afterFirstOpen)
    }

    /// The guard of the pin above. Metadata that changed between two opens still reaches the database.
    func testChangingTheSampleMetadataStillRewritesTheCacheRows() async throws {
        let shown = try makeShownResult()
        await shown.view.sampleMetadataCacheRefresh?.value
        let database = try Kraken2Database(at: shown.database)
        XCTAssertEqual(try database.fetchMetadataValues(field: "Group"), ["sample-A": "case", "sample-B": "control"])

        try writeMetadataTable(groups: ["control", "case"], in: shown.folder)
        open(shown.view, shown.folder)
        await shown.view.sampleMetadataCacheRefresh?.value

        XCTAssertEqual(try database.fetchMetadataValues(field: "Group"), ["sample-A": "control", "sample-B": "case"])
    }
}

