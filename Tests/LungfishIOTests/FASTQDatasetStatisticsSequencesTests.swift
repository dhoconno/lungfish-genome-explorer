// FASTQDatasetStatisticsSequencesTests.swift - Statistics measured from FASTA records, and the rules that read them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// Phase 3.0 lane ONT, review fix BIO F1. A FASTA record holds no quality scores, so `measuringFASTA` measures the
/// counts, lengths and GC and leaves the score fields at 0 with an empty score histogram. `isMeasured` tells statistics
/// that were measured from ones that counted reads and gave them no length, and `withoutQualities` clears the scores
/// of reads whose scores were made up. Before the lane a FASTA bundle stored 0 for every length.
final class FASTQDatasetStatisticsSequencesTests: XCTestCase {
    /// Three records of 12, 5 and 3 bases, 11 of the 20 bases G or C. The second record is lower case.
    private static let fasta = ">r1 first\nACGTAC\nGGCCAA\n>r2\nggcca\n>r3\nATA\n"

    private func makeFolder() throws -> URL {
        let folder = try TestTempDirectory.make(prefix: "fasta-statistics")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        return folder
    }

    func testMeasuringFASTAGivesCountsLengthsAndGC() throws {
        let measured = FASTQDatasetStatistics.measuringFASTA(text: Self.fasta)
        XCTAssertEqual(measured.readCount, 3)
        XCTAssertEqual(measured.baseCount, 20)
        XCTAssertEqual(measured.meanReadLength, 20.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(measured.minReadLength, 3)
        XCTAssertEqual(measured.maxReadLength, 12)
        XCTAssertEqual(measured.medianReadLength, 5)
        XCTAssertEqual(measured.n50ReadLength, 12)
        XCTAssertEqual(measured.gcContent, 0.55, accuracy: 0.0001)
        XCTAssertEqual(measured.meanQuality, 0, "a FASTA record holds no scores")
        XCTAssertTrue(measured.qualityScoreHistogram.isEmpty, "the empty histogram says no score was measured")
        XCTAssertEqual(measured.readLengthHistogram, [12: 1, 5: 1, 3: 1])

        XCTAssertEqual(
            FASTQDatasetStatistics.measuringFASTA(text: String(Self.fasta.dropLast())), measured, "no final newline"
        )
        // CRLF text is not asserted. `measuringFASTA(text:)` splits the text on a Character and Swift reads "\r\n" as
        // one Character, so the CRLF copy of this text measures as 1 record of 0 bases (ONT fix report, Finding 1).
        XCTAssertEqual(FASTQDatasetStatistics.measuringFASTA(text: ""), .empty)
    }

    func testMeasuringAFASTAFileGivesTheTextResult() throws {
        let measured = FASTQDatasetStatistics.measuringFASTA(text: Self.fasta)
        let folder = try makeFolder()
        let plain = folder.appendingPathComponent("reads.fasta")
        try Data(Self.fasta.utf8).write(to: plain)
        XCTAssertEqual(try FASTQDatasetStatistics.measuringFASTA(at: plain), measured, "plain file")

        let gzip = try GzipPinSupport.gzip(Self.fasta, in: folder, named: "reads-gz.fasta")
        XCTAssertEqual(gzip.lastPathComponent, "reads-gz.fasta.gz")
        XCTAssertEqual(try FASTQDatasetStatistics.measuringFASTA(at: gzip), measured, "gzip file")
    }

    func testIsMeasuredNeedsALongestRead() {
        XCTAssertTrue(FASTQDatasetStatistics.empty.isMeasured, "no reads, nothing to measure")
        XCTAssertFalse(
            FASTQDatasetStatistics.countsOnlyFixture(readCount: 5, baseCount: 50).isMeasured,
            "reads with no longest read are the retired counts-only shape"
        )
        XCTAssertTrue(FASTQDatasetStatistics.measuringFASTA(text: Self.fasta).isMeasured)
    }

    func testWithoutQualitiesClearsOnlyTheScores() {
        let measured = FASTQDatasetStatistics.measuringFASTA(text: Self.fasta)
        let scored = FASTQDatasetStatistics(
            readCount: measured.readCount, baseCount: measured.baseCount,
            meanReadLength: measured.meanReadLength, minReadLength: measured.minReadLength,
            maxReadLength: measured.maxReadLength, medianReadLength: measured.medianReadLength,
            n50ReadLength: measured.n50ReadLength,
            meanQuality: 31.5, q20Percentage: 95, q30Percentage: 80, gcContent: measured.gcContent,
            readLengthHistogram: measured.readLengthHistogram, qualityScoreHistogram: [32: 20],
            perPositionQuality: []
        )
        XCTAssertEqual(scored.meanQuality, 31.5)

        let cleared = scored.withoutQualities
        XCTAssertEqual(cleared.meanQuality, 0)
        XCTAssertEqual(cleared.q20Percentage, 0)
        XCTAssertEqual(cleared.q30Percentage, 0)
        XCTAssertTrue(cleared.qualityScoreHistogram.isEmpty)
        XCTAssertEqual(cleared.readCount, 3)
        XCTAssertEqual(cleared.baseCount, 20)
        XCTAssertEqual(cleared.minReadLength, 3)
        XCTAssertEqual(cleared.maxReadLength, 12)
        XCTAssertEqual(cleared.medianReadLength, 5)
        XCTAssertEqual(cleared.n50ReadLength, 12)
        XCTAssertEqual(cleared.gcContent, 0.55, accuracy: 0.0001)
        XCTAssertEqual(cleared.readLengthHistogram, [12: 1, 5: 1, 3: 1])
        XCTAssertEqual(cleared, measured, "only the scores differed")
    }
}
