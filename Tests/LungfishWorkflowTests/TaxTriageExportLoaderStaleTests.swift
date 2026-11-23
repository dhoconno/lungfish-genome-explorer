// TaxTriageExportLoaderStaleTests.swift - The export refuses a TaxTriage database that an older Lungfish counted (3.2 TTREADS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli taxtriage export results` reads `taxtriage.sqlite` through `TaxTriageExportLoader.load`. A database that
// an older Lungfish built holds Reads counted on the first reference of each organism alone, so an organism with several
// references, such as the eight segments of Influenza A, can read 0 in the table that the export writes. The loader asks
// `isStale` as the viewer does, and refuses in words that name the command that rebuilds it (BIO review of lane TTREADS,
// finding F2, ARCH should-fix 2).

import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

final class TaxTriageExportLoaderStaleTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "TaxTriageExportLoaderStale")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(folder)
    }

    /// Red at 0ea86b0a9, where `load` returns the rows of the old database without a word.
    func testExportOfAnOldDatabaseRefusesWithWords() throws {
        let databaseURL = try makeBatch(metadata: ["tool": "taxtriage", "taxonomy_source": "organism_report"])

        XCTAssertThrowsError(try TaxTriageExportLoader.load(resultURL: folder, samples: [], searchText: nil)) { error in
            let words = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(words.contains("build-db taxtriage"), "the words name the command that rebuilds it: \(words)")
            XCTAssertTrue(words.contains("--force"), "the words name the flag: \(words)")
            XCTAssertTrue(words.contains(folder.path), "the words name the result folder: \(words)")
            XCTAssertEqual(
                error as? TaxTriageExportLoader.LoadError,
                .staleDatabase(path: databaseURL.path, resultPath: folder.path)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path), "the export leaves the database as it was")
    }

    /// TT-m2 BIO S-2. After TT-STRAIN-GROUP every database built before it is stale, and most of those read the right
    /// Reads, so the reason covers the counts of an organism with several references or strains. Red at the base.
    func testRefusalWordsNameStrainsAsWellAsReferences() {
        let words = TaxTriageExportLoader.LoadError.staleDatabase(path: "/r/taxtriage.sqlite", resultPath: "/r").errorDescription ?? ""

        XCTAssertTrue(words.contains("or strains"), "the reason covers organisms with several strains: \(words)")
    }

    /// A database that carries the current mark loads, so the refusal reaches only the old ones.
    func testExportOfADatabaseWithTheCurrentMarkLoads() throws {
        _ = try makeBatch(metadata: [
            "tool": "taxtriage",
            TaxTriageDatabase.taxonomySourceMetadataKey: "organism_report",
            TaxTriageDatabase.readCountMetadataKey: TaxTriageDatabase.currentReadCount,
        ])

        let source = try TaxTriageExportLoader.load(resultURL: folder, samples: [], searchText: nil)

        XCTAssertFalse(source.metrics.isEmpty, "the rows of the current database load")
    }

    /// Red at 8efd65b47 plus TT-m1, where `load` hands over the rows of S2, which a rebuild kept from an earlier database
    /// without recounting them, with their old numbers and no words (TT-m1-BIO, B1). The result folder has no `report/`
    /// folder, so `isStale` is false whatever the marks are and only the not-recounted key can refuse it.
    func testALoaderRefusesASampleARebuildDidNotRecount() throws {
        let databaseURL = folder.appendingPathComponent(TaxTriageExportLoader.databaseFileName)
        _ = try TaxTriageDatabase.create(
            at: databaseURL,
            rows: [Self.row(sample: "S1"), Self.row(sample: "S2")],
            metadata: ["tool": "taxtriage", "not_recounted_samples": "[\"S2\"]"]
        )

        XCTAssertThrowsError(try TaxTriageExportLoader.load(resultURL: folder, samples: [], searchText: nil)) { error in
            XCTAssertEqual(
                error as? TaxTriageExportLoader.LoadError,
                .notRecounted(path: databaseURL.path, samples: ["S2"])
            )
        }
        let source = try TaxTriageExportLoader.load(resultURL: folder, samples: ["S1"], searchText: nil)
        XCTAssertFalse(source.metrics.isEmpty, "the samples the rebuild did count still export")
    }

    /// A row of one sample, the helper of `TaxTriageNotRecountedNoticeTests`.
    private static func row(sample: String) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: "Alpha virus", taxId: 1001, status: nil, tassScore: 0.9, readsAligned: 40,
            uniqueReads: 20, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50, meanCoverage: nil, meanDepth: nil,
            confidence: "High", k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil, meanBaseQ: nil, meanMapQ: nil,
            mapqScore: nil, disparityScore: nil, minhashScore: nil, diamondIdentity: nil, k2DisparityScore: nil,
            siblingsScore: nil, breadthWeightScore: nil, hhsPercentile: nil, isAnnotated: nil, annClass: nil,
            microbialCategory: nil, highConsequence: nil, isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
            bamPath: "\(sample)/minimap2/\(sample).bam", bamIndexPath: "\(sample)/minimap2/\(sample).bam.bai",
            primaryAccession: "NC_1001", accessionLength: 10_000
        )
    }

    /// A batch folder with the sample folder of a TaxTriage 3.3.8 organism report and a database of its first row.
    private func makeBatch(metadata: [String: String]) throws -> URL {
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/taxtriage-odr-3.3.8/SRR12486983", isDirectory: true)
        try FileManager.default.copyItem(at: sample, to: folder.appendingPathComponent("SRR12486983", isDirectory: true))
        let report = try String(contentsOf: sample.appendingPathComponent("report/SRR12486983.odr.txt"), encoding: .utf8)
        let row = try XCTUnwrap(TaxTriageOrganismReport.parse(tsv: report).first, "the fixture report holds a row")
        let databaseURL = folder.appendingPathComponent(TaxTriageExportLoader.databaseFileName)
        _ = try TaxTriageDatabase.create(at: databaseURL, rows: [row], metadata: metadata)
        return databaseURL
    }
}
