// SequenceExtractorFlankReadFailureTests.swift - A flank that cannot be read stops the extraction (FASTAREAD review, should-fix 1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// A concatenated extraction asks the provider for a flank on each side of the exons. A flank that was asked for and
/// answers nil is a failed read, as an exon is, so `extract` throws `sequenceNotAvailable` with the flank's range.
/// Before the lane the nil flank was dropped, and the FASTA header named the flank range while the sequence lacked
/// its bases. The control shows that no flank is asked for, and none refused, at a chromosome end.
final class SequenceExtractorFlankReadFailureTests: XCTestCase {
    private let genome = String(repeating: "ACGTTGCAAC", count: 10)   // 100 bases

    /// Reads `genome`, and answers nil for the one range in `missing`.
    private func provider(missing: (start: Int, end: Int)? = nil) -> SequenceExtractor.SequenceProvider {
        let genome = self.genome
        return { _, start, end in
            if let missing, start == missing.start, end == missing.end { return nil }
            let from = genome.index(genome.startIndex, offsetBy: start)
            let to = genome.index(genome.startIndex, offsetBy: end)
            return String(genome[from..<to])
        }
    }

    private func request(_ first: Int, _ last: Int) -> ExtractionRequest {
        let annotation = SequenceAnnotation(
            type: .mRNA, name: "TestmRNA", chromosome: "chr1",
            intervals: [AnnotationInterval(start: first, end: first + 10), AnnotationInterval(start: last, end: last + 10)],
            strand: .forward
        )
        return ExtractionRequest(source: .annotation(annotation), flank5Prime: 5, flank3Prime: 5, concatenateExons: true)
    }

    func testConcatenatedExtractionThrowsWhenALowFlankCannotBeRead() {
        XCTAssertThrowsError(try SequenceExtractor.extract(
            request: request(20, 40), sequenceProvider: provider(missing: (15, 20)), chromosomeLength: 100
        )) { error in
            guard case ExtractionError.sequenceNotAvailable(let detail) = error else { return XCTFail("Got \(error)") }
            XCTAssertEqual(detail, "chr1:15-20")
        }
    }

    func testConcatenatedExtractionThrowsWhenAHighFlankCannotBeRead() {
        XCTAssertThrowsError(try SequenceExtractor.extract(
            request: request(20, 40), sequenceProvider: provider(missing: (50, 55)), chromosomeLength: 100
        )) { error in
            guard case ExtractionError.sequenceNotAvailable(let detail) = error else { return XCTFail("Got \(error)") }
            XCTAssertEqual(detail, "chr1:50-55")
        }
    }

    /// Control. Exons at both ends of a 50-base chromosome leave no flank to read, and none is asked for.
    func testConcatenatedExtractionAsksForNoFlankPastTheChromosomeEnds() throws {
        let whole = provider()
        let strict: SequenceExtractor.SequenceProvider = { chromosome, start, end in
            XCTAssertLessThan(start, end, "an empty range must not be requested")
            return whole(chromosome, start, end)
        }
        let result = try SequenceExtractor.extract(request: request(0, 40), sequenceProvider: strict, chromosomeLength: 50)
        XCTAssertEqual(result.effectiveStart, 0)
        XCTAssertEqual(result.effectiveEnd, 50)
        XCTAssertEqual(result.nucleotideSequence.count, 20)
    }
}
