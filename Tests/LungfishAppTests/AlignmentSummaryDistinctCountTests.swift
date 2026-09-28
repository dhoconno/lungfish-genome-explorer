// AlignmentSummaryDistinctCountTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

/// After Mark Duplicates the reads Inspector's Alignment Summary showed
/// "Mapped 182.0K" for 91,148 reads: it summed the [unmarked] source track
/// and its [dup-marked] copy, which hold the same reads.
@MainActor
final class AlignmentSummaryDistinctCountTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alignment-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDistinctDataTrackIDsDropsCopiesDerivedFromAPresentTrack() {
        XCTAssertEqual(
            ReadStyleSectionViewModel.distinctDataTrackIDs(
                trackIDs: ["unmarked", "marked", "other"],
                derivationSourceByTrackID: ["marked": "unmarked"]
            ),
            ["unmarked", "other"]
        )
        XCTAssertEqual(
            ReadStyleSectionViewModel.distinctDataTrackIDs(
                trackIDs: ["marked"],
                derivationSourceByTrackID: ["marked": "deleted-source"]
            ),
            ["marked"],
            "a derived track whose source was removed is the only copy and counts"
        )
    }

    func testSummaryCountsMarkedAndUnmarkedCopiesOnce() throws {
        let bundleURL = tempDir.appendingPathComponent("Mapped.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("alignments/marked", isDirectory: true),
            withIntermediateDirectories: true
        )

        let unmarkedDB = try AlignmentMetadataDatabase.create(
            at: bundleURL.appendingPathComponent("alignments/sample.stats.db")
        )
        unmarkedDB.addChromosomeStats(chromosome: "chr1", length: 29_903, mapped: 91_148, unmapped: 1_000)
        unmarkedDB.addReadGroup(id: "RG1", sample: "S1", library: nil, platform: "ILLUMINA")

        let markedDB = try AlignmentMetadataDatabase.create(
            at: bundleURL.appendingPathComponent("alignments/marked/sample.stats.db")
        )
        markedDB.addChromosomeStats(chromosome: "chr1", length: 29_903, mapped: 91_148, unmapped: 1_000)
        markedDB.addReadGroup(id: "RG1", sample: "S1", library: nil, platform: "ILLUMINA")
        markedDB.setFileInfo("derivation_source_track_id", value: "aln_unmarked")

        let manifest = BundleManifest(
            name: "Mapped",
            identifier: "bundle.mapped",
            source: SourceInfo(organism: "Virus", assembly: "Test", database: "Test"),
            genome: GenomeInfo(
                path: "genome/reference.fa.gz",
                indexPath: "genome/reference.fa.gz.fai",
                totalLength: 29_903,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 29_903, offset: 0, lineBases: 60, lineWidth: 61),
                ]
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln_unmarked", name: "S1 [unmarked]",
                    sourcePath: "alignments/sample.sorted.bam",
                    indexPath: "alignments/sample.sorted.bam.bai",
                    metadataDBPath: "alignments/sample.stats.db"
                ),
                AlignmentTrackInfo(
                    id: "aln_marked", name: "S1 [dup-marked]",
                    sourcePath: "alignments/marked/sample.sorted.bam",
                    indexPath: "alignments/marked/sample.sorted.bam.bai",
                    metadataDBPath: "alignments/marked/sample.stats.db"
                ),
            ]
        )
        let viewModel = ReadStyleSectionViewModel()
        viewModel.loadStatistics(from: ReferenceBundle(url: bundleURL, manifest: manifest))

        XCTAssertEqual(viewModel.totalMappedReads, 91_148)
        XCTAssertEqual(viewModel.totalUnmappedReads, 1_000)
        XCTAssertEqual(viewModel.chromosomeStats.count, 1)
        XCTAssertEqual(viewModel.readGroups.map(\.id), ["RG1"])
        XCTAssertEqual(viewModel.trackNames, ["S1 [unmarked]", "S1 [dup-marked]"], "both tracks are still listed")
    }
}
