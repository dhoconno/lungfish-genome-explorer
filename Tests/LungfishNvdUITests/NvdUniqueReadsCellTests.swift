// NvdUniqueReadsCellTests.swift - The NVD table shows a dash for a Unique Reads count that was never computed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane ESVUNIQUE, BIO review Blocker 2 (S1). The Unique Reads cell raised a count never computed to 1 when
// the contig had reads, so 40 mapped reads beside a Unique Reads of 1 read as nearly all duplicates. The cell now goes
// through `ClassifierUniqueReads.normalized` as the export does, and shows a dash for no count.

import AppKit
import XCTest
@testable import LungfishNvdUI
@testable import LungfishIO
import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class NvdUniqueReadsCellTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NvdUniqueReadsCell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NvdResultViewController.testMetadataUserDefaultsOverride =
            makeTestDefaultsSuite(prefix: "NvdUniqueReadsCellTests").defaults
    }

    override func tearDownWithError() throws {
        NvdResultViewController.testMetadataUserDefaultsOverride = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// Red at the base, where the cell for 40 mapped reads with no count shows 1. The two contigs are told apart by
    /// their mapped reads, 40 with no count and 50 with a count of 31.
    func testNvdCellShowsADashWhenUniqueReadsWasNeverCounted() throws {
        let vc = try configuredController()
        let table = vc.testOutlineView
        var uniqueByMapped: [String: String] = [:]
        for row in 0..<table.numberOfRows {
            uniqueByMapped[try Self.text(table, "mappedReads", row)] = try Self.text(table, "uniqueReads", row)
        }
        XCTAssertEqual(uniqueByMapped["40"], "\u{2014}", "a count never computed shows a dash, never 1")
        XCTAssertEqual(uniqueByMapped["50"], "31", "a computed count shows its number")
    }

    private static func text(_ table: NSOutlineView, _ identifier: String, _ row: Int) throws -> String {
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
        let index = try XCTUnwrap(column >= 0 ? column : nil, "the outline holds a \(identifier) column")
        let cell = table.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView
        return try XCTUnwrap(cell?.textField, "row \(row) holds a \(identifier) cell").stringValue
    }

    private func configuredController() throws -> NvdResultViewController {
        let bundleURL = folder.appendingPathComponent("fixture.nvd", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("manifest.json"))
        let database = try NvdDatabase.create(
            at: bundleURL.appendingPathComponent("hits.sqlite"),
            hits: [
                Self.hit(contig: "contig_1", mapped: 40, unique: nil),
                Self.hit(contig: "contig_2", mapped: 50, unique: 31),
            ],
            samples: [NvdSampleMetadata(
                sampleId: "sample1", bamPath: "sample1.bam", fastaPath: "sample1.fasta",
                totalReads: 1000, contigCount: 2, hitCount: 2
            )]
        )
        let manifest = NvdManifest(
            experiment: "exp-cell", sampleCount: 1, contigCount: 2, hitCount: 2, blastDbVersion: "db",
            snakemakeRunId: "run-1", sourceDirectoryPath: folder.path,
            samples: [NvdSampleSummary(
                sampleId: "sample1", contigCount: 2, hitCount: 2, totalReads: 1000,
                bamRelativePath: "sample1.bam", fastaRelativePath: "sample1.fasta"
            )],
            cachedTopContigs: nil
        )
        let vc = NvdResultViewController()
        _ = vc.view
        vc.configure(database: database, manifest: manifest, bundleURL: bundleURL)
        return vc
    }

    private static func hit(contig: String, mapped: Int, unique: Int?) -> NvdBlastHit {
        NvdBlastHit(
            experiment: "exp-cell", blastTask: "blastn", sampleId: "sample1", qseqid: contig, qlen: 120,
            sseqid: "NC_\(contig)", stitle: "Synthetic virus", taxRank: "species", length: 118, pident: 99.2,
            evalue: 0, bitscore: 50, sscinames: "Synthetic virus", staxids: "1234", blastDbVersion: "db",
            snakemakeRunId: "run-1", mappedReads: mapped, uniqueReads: unique, totalReads: 1000,
            statDbVersion: "stats-1", adjustedTaxid: "1234", adjustmentMethod: "dominant",
            adjustedTaxidName: "Synthetic virus", adjustedTaxidRank: "species", hitRank: 1,
            readsPerBillion: Double(mapped) * 1_000_000
        )
    }
}
