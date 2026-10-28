// ImportBAMPlainStatisticsTests.swift - the counts the plain route of import bam prints and records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishWorkflow
@testable import LungfishCLI

/// Row IMPORT-BAM-PLAIN-IDXSTATS-AS-READS (review of lane MAPPED, N1), on the text samtools gives for the supplementary
/// fixture. Its BAM holds 13 alignment records for 11 reads, 12 mapped records for 10 mapped reads, and one unmapped read that
/// no sequence holds, which idxstats lists on its `*` row. `ImportBAMPlainReadCountsLiveConformanceTests` is the live form,
/// with the real samtools.
final class ImportBAMPlainStatisticsTests: XCTestCase {
    private static let idxstats = "fixture1\t1000\t12\t0\n*\t0\t0\t1\n"

    private static let flagstat = """
        13 + 0 in total (QC-passed reads + QC-failed reads)
        11 + 0 primary
        0 + 0 secondary
        2 + 0 supplementary
        0 + 0 duplicates
        0 + 0 primary duplicates
        12 + 0 mapped (92.31% : N/A)
        10 + 0 primary mapped (90.91% : N/A)
        0 + 0 paired in sequencing
        """

    /// The flagstat of a samtools before 1.9, which prints no `primary` lines.
    private static let flagstatWithoutPrimaryLines = """
        13 + 0 in total (QC-passed reads + QC-failed reads)
        0 + 0 secondary
        2 + 0 supplementary
        0 + 0 duplicates
        12 + 0 mapped (92.31% : N/A)
        0 + 0 paired in sequencing
        """

    private func rows(_ statistics: BAMImportStatistics) -> [String] {
        statistics.summaryRows(formatNumber: { String($0) }).map { "\($0.0)=\($0.1)" }
    }

    func testFlagstatPrimaryLinesGiveTheReadsTheSummaryPrints() {
        let statistics = BAMImportStatistics(idxstats: Self.idxstats, flagstat: Self.flagstat)

        XCTAssertEqual(statistics.unit, .reads)
        XCTAssertEqual(
            rows(statistics),
            ["Total reads=11", "Mapped reads=10 (90.91%)", "Unmapped reads=1", "Reference contigs=1"],
            "10 of 11 reads, not the 12 of 13 alignment records that idxstats sums"
        )
        XCTAssertEqual(statistics.alignments, BAMImportStatistics.Counts(mapped: 12, unmapped: 1))
        XCTAssertNil(statistics.alignmentCountsNote, "reads need no note")
    }

    func testAFlagstatWithoutPrimaryLinesGivesAlignmentsAndTheSummaryNamesThem() throws {
        let statistics = BAMImportStatistics(idxstats: Self.idxstats, flagstat: Self.flagstatWithoutPrimaryLines)

        XCTAssertEqual(statistics.unit, .alignments)
        XCTAssertEqual(
            rows(statistics),
            ["Total alignments=13", "Mapped alignments=12 (92.31%)", "Unmapped alignments=1", "Reference contigs=1"],
            "alignment records are no reads, and the labels say so"
        )
        let note = try XCTUnwrap(statistics.alignmentCountsNote, "words say what the counts are and what to try")
        XCTAssertTrue(note.contains("more than one place"), note)
        XCTAssertTrue(note.contains("Run the import again"), note)
    }

    func testNoFlagstatGivesAlignmentsToo() {
        let statistics = BAMImportStatistics(idxstats: Self.idxstats, flagstat: nil)

        XCTAssertEqual(statistics.unit, .alignments)
        XCTAssertEqual(rows(statistics).first, "Total alignments=13")
        XCTAssertNotNil(statistics.alignmentCountsNote)
    }

    func testTheRecordKeepsTheReadKeysForReadsAndNeverHoldsAlignmentRecordsUnderThem() {
        let reads = BAMImportStatistics(idxstats: Self.idxstats, flagstat: Self.flagstat).provenanceValues()
        XCTAssertEqual(reads["countUnit"]?.stringValue, "reads")
        XCTAssertEqual(reads["totalReads"]?.integerValue, 11)
        XCTAssertEqual(reads["mappedReads"]?.integerValue, 10)
        XCTAssertEqual(reads["unmappedReads"]?.integerValue, 1)
        XCTAssertEqual(reads["totalAlignments"]?.integerValue, 13, "the alignment records are kept under keys of their own")
        XCTAssertEqual(reads["mappedAlignments"]?.integerValue, 12)
        XCTAssertEqual(reads["unmappedAlignments"]?.integerValue, 1)

        let alignments = BAMImportStatistics(idxstats: Self.idxstats, flagstat: nil).provenanceValues()
        XCTAssertEqual(alignments["countUnit"]?.stringValue, "alignments")
        XCTAssertEqual(alignments["totalReads"], ParameterValue.null, "no reads were counted, so the read keys hold no number")
        XCTAssertEqual(alignments["mappedReads"], ParameterValue.null)
        XCTAssertEqual(alignments["unmappedReads"], ParameterValue.null)
        XCTAssertEqual(alignments["mappedAlignments"]?.integerValue, 12)
    }
}
