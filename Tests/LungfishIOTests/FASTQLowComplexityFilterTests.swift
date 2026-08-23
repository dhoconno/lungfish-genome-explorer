// FASTQLowComplexityFilterTests.swift - Entropy filter operation model + stderr parsing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Covers the entropy-filter operation kind, its Codable parameter round trip,
/// and the bbduk stderr summary parser used for the operation summary and
/// provenance record.
final class FASTQLowComplexityFilterTests: XCTestCase {

    func testLowComplexityFilterOperationKindClassification() {
        // Entropy filtering discards whole reads, so it is a subset operation
        // exactly like the contaminant filter.
        XCTAssertTrue(FASTQDerivativeOperationKind.lowComplexityFilter.isSubsetOperation)
        XCTAssertFalse(FASTQDerivativeOperationKind.lowComplexityFilter.isFullOperation)
        XCTAssertFalse(FASTQDerivativeOperationKind.lowComplexityFilter.isOrientOperation)
        XCTAssertTrue(FASTQDerivativeOperationKind.lowComplexityFilter.supportsFASTA)
    }

    func testLowComplexityFilterLabels() {
        let op = FASTQDerivativeOperation(
            kind: .lowComplexityFilter,
            entropyThreshold: 0.6,
            entropyWindow: 50,
            entropyKmer: 5
        )
        XCTAssertEqual(op.shortLabel, "entropy-0.60")
        XCTAssertTrue(op.displaySummary.contains("0.60"))
        XCTAssertTrue(op.displaySummary.contains("50"))
        XCTAssertTrue(op.displaySummary.contains("Low-complexity"))
    }

    func testLowComplexityFilterDefaultsWhenParametersAbsent() {
        let op = FASTQDerivativeOperation(kind: .lowComplexityFilter)
        XCTAssertEqual(op.shortLabel, "entropy-0.60")
        XCTAssertTrue(op.displaySummary.contains("0.60"))
    }

    func testLowComplexityFilterMethodsSentence() {
        let op = FASTQDerivativeOperation(
            kind: .lowComplexityFilter,
            entropyThreshold: 0.7,
            entropyWindow: 40,
            entropyKmer: 4,
            toolUsed: "bbduk",
            toolVersion: "39.06"
        )
        let sentence = op.methodsSentence
        XCTAssertTrue(sentence.contains("bbduk"))
        XCTAssertTrue(sentence.contains("0.70"))
        XCTAssertTrue(sentence.contains("40"))
        XCTAssertTrue(sentence.contains("4"))
    }

    func testLowComplexityFilterOperationCodableRoundTrip() throws {
        let original = FASTQDerivativeOperation(
            kind: .lowComplexityFilter,
            entropyThreshold: 0.65,
            entropyWindow: 45,
            entropyKmer: 6,
            toolUsed: "bbduk",
            toolVersion: "39.06",
            toolCommand: "bbduk.sh entropy=0.65 entropywindow=45 entropyk=6"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FASTQDerivativeOperation.self, from: data)

        XCTAssertEqual(decoded.kind, .lowComplexityFilter)
        XCTAssertEqual(decoded.entropyThreshold, 0.65)
        XCTAssertEqual(decoded.entropyWindow, 45)
        XCTAssertEqual(decoded.entropyKmer, 6)
        XCTAssertEqual(decoded.toolUsed, "bbduk")
        XCTAssertEqual(decoded.toolCommand, original.toolCommand)
        XCTAssertEqual(decoded, original)
    }

    func testLowComplexityFilterOperationContract() {
        let input = OperationContract.input(for: .lowComplexityFilter)
        XCTAssertTrue(input.acceptedFormats.contains(.fastq))
        XCTAssertTrue(input.acceptedFormats.contains(.fasta))
        XCTAssertNil(input.requiredPairing)
    }

    // MARK: - bbduk stderr summary parsing

    /// Captured from a real bbduk entropy-filter run on the benchmark readset.
    private static let capturedStderr = """
    java -ea -Xmx8g -cp /opt/bbmap/current/ jgi.BBDuk in=reads.fastq out=clean.fastq entropy=0.6
    Executing jgi.BBDuk [in=reads.fastq, out=clean.fastq, entropy=0.6]

    Input is being processed as unpaired
    Input:                    49621316 reads          5725838608 bases.
    Low entropy discards:       913960 reads (1.84%)    91699335 bases (1.60%)
    Result:                   48707356 reads (98.16%) 5634139273 bases (98.40%)

    Time:                         123.456 seconds.
    """

    func testParsesInputDiscardAndResultCounts() throws {
        let summary = try XCTUnwrap(BBDukEntropySummary(stderr: Self.capturedStderr))
        XCTAssertEqual(summary.inputReads, 49_621_316)
        XCTAssertEqual(summary.inputBases, 5_725_838_608)
        XCTAssertEqual(summary.discardedReads, 913_960)
        XCTAssertEqual(summary.discardedBases, 91_699_335)
        XCTAssertEqual(summary.outputReads, 48_707_356)
        XCTAssertEqual(summary.outputBases, 5_634_139_273)
    }

    func testComputesDiscardPercentageFromCounts() throws {
        let summary = try XCTUnwrap(BBDukEntropySummary(stderr: Self.capturedStderr))
        XCTAssertEqual(summary.discardedReadPercentage, 1.84, accuracy: 0.01)
        XCTAssertEqual(summary.discardedBasePercentage, 1.60, accuracy: 0.01)
    }

    /// Some bbduk invocations report "Total Removed" instead of the
    /// entropy-specific line; the parser must accept either.
    func testParsesTotalRemovedFallbackLine() throws {
        let stderr = """
        Input:                       1000 reads             100000 bases.
        Total Removed:                 40 reads (4.00%)       4000 bases (4.00%)
        Result:                       960 reads (96.00%)     96000 bases (96.00%)
        """
        let summary = try XCTUnwrap(BBDukEntropySummary(stderr: stderr))
        XCTAssertEqual(summary.inputReads, 1000)
        XCTAssertEqual(summary.discardedReads, 40)
        XCTAssertEqual(summary.outputReads, 960)
    }

    func testPrefersLowEntropyLineOverTotalRemoved() throws {
        let stderr = """
        Input:                       1000 reads             100000 bases.
        Low entropy discards:          25 reads (2.50%)       2500 bases (2.50%)
        Total Removed:                 40 reads (4.00%)       4000 bases (4.00%)
        Result:                       960 reads (96.00%)     96000 bases (96.00%)
        """
        let summary = try XCTUnwrap(BBDukEntropySummary(stderr: stderr))
        XCTAssertEqual(summary.discardedReads, 25)
        XCTAssertEqual(summary.discardedBases, 2500)
    }

    func testReturnsNilWhenStderrHasNoSummary() {
        XCTAssertNil(BBDukEntropySummary(stderr: "bbduk.sh: command not found"))
        XCTAssertNil(BBDukEntropySummary(stderr: ""))
    }

    func testDisplaySummaryTextIsHumanReadable() throws {
        let summary = try XCTUnwrap(BBDukEntropySummary(stderr: Self.capturedStderr))
        let text = summary.displaySummary
        XCTAssertTrue(text.contains("48,707,356") || text.contains("48707356"))
        XCTAssertTrue(text.contains("913,960") || text.contains("913960"))
    }
}
