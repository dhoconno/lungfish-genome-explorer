// TranslationFrameClampTests.swift - Reading frame of a CDS that the end of the record clips
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// Phase 2.8 lane B6, decision G1 and row 418 of the Phase 2.7 plan.
///
/// Each case reads its bases through the viewer's single-sequence provider. A request that runs past
/// the end of the record returns the bases that exist, and a request that starts at or after the end
/// returns nil. One coding sequence is cut four ways. Its protein is M A K R W H E F P D Q Y G S.
///
/// These expectations state today's output. They pass at the base commit, and the fix commit of the
/// lane flips the three cases that lose the 5' end of a reverse-strand CDS. The forward case stays.
final class TranslationFrameClampTests: XCTestCase {

    // MARK: - Fixtures

    /// 14 codons and a 2 base tail, 44 bases in transcription order.
    private static let codingBases: [Character] = Array(
        (["ATG", "GCT", "AAA", "CGT", "TGG", "CAT", "GAA", "TTC", "CCG", "GAT", "CAG", "TAC", "GGT", "AGC"]
            .joined() + "GA")
    )

    /// Coding bases `range`, counted from the 5' end of the whole CDS.
    private func coding(_ range: Range<Int>) -> String {
        String(Self.codingBases[range])
    }

    /// The plus-strand bases that hold coding bases `range` of a reverse-strand CDS.
    private func plusStrand(ofCoding range: Range<Int>) -> String {
        TranslationEngine.reverseComplement(coding(range))
    }

    /// A record of `length` bases with `pieces` laid on it at their plus-strand starts. The rest is N.
    private func record(length: Int, _ pieces: [(start: Int, bases: String)]) -> String {
        var bases = [Character](repeating: "N", count: length)
        for piece in pieces {
            for (offset, base) in piece.bases.enumerated() {
                bases[piece.start + offset] = base
            }
        }
        return String(bases)
    }

    /// The viewer's single-sequence provider, clamped to the record.
    private func clamping(_ record: String) -> (Int, Int) -> String? {
        let bases = Array(record)
        return { start, end in
            let clampedStart = max(0, start)
            let clampedEnd = min(bases.count, end)
            guard clampedStart < clampedEnd else { return nil }
            return String(bases[clampedStart..<clampedEnd])
        }
    }

    /// The smallest span that holds the genomic ranges of one codon, as [start, end].
    private func span(of position: AminoAcidPosition) -> [Int] {
        [position.genomicRanges.map(\.start).min() ?? -1, position.genomicRanges.map(\.end).max() ?? -1]
    }

    // MARK: - The four cases of the translation frame rule

    /// Reverse, one segment [100,130), the record ends at 120. The 10 bases at the 5' end of the CDS
    /// are gone, so p is 0 and r is 10.
    func testReverseSingleSegmentClampedAtRecordEnd() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "case1",
            intervals: [AnnotationInterval(start: 100, end: 130, phase: 0)],
            strand: .reverse
        )
        let bases = record(length: 120, [(start: 100, bases: plusStrand(ofCoding: 10..<30))])

        let result = try XCTUnwrap(
            TranslationEngine.translateCDS(annotation: annotation, sequenceProvider: clamping(bases))
        )

        XCTAssertEqual(result.codingSequence, coding(10..<30))
        XCTAssertEqual(result.phaseOffset, 0)
        XCTAssertEqual(result.protein, "VGMNSR")
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.first)), [127, 130])
    }

    /// Reverse, GenBank. The 5'-most segment [200,229) is dropped because the record ends at 190, and
    /// the next segment has no phase, because a GenBank import sets it on the 5'-most segment only.
    /// p is 0 and r is 29.
    func testReverseGenBankFivePrimeSegmentDroppedAtRecordEnd() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "case2",
            intervals: [
                AnnotationInterval(start: 100, end: 115),
                AnnotationInterval(start: 200, end: 229, phase: 0)
            ],
            strand: .reverse
        )
        let bases = record(length: 190, [(start: 100, bases: plusStrand(ofCoding: 29..<44))])

        let result = try XCTUnwrap(
            TranslationEngine.translateCDS(annotation: annotation, sequenceProvider: clamping(bases))
        )

        XCTAssertEqual(result.codingSequence, coding(29..<44))
        XCTAssertEqual(result.phaseOffset, 0)
        XCTAssertEqual(result.protein, "SVR*R")
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.first)), [112, 115])
    }

    /// Reverse. The 5'-most segment [200,230) is clamped to [200,210) by the end of the record, so p is
    /// 0 and r is 20. The next segment [100,112) is whole.
    func testReverseFivePrimeSegmentClampedToItsFirstTenBases() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "case3",
            intervals: [
                AnnotationInterval(start: 100, end: 112),
                AnnotationInterval(start: 200, end: 230, phase: 0)
            ],
            strand: .reverse
        )
        let bases = record(
            length: 210,
            [
                (start: 100, bases: plusStrand(ofCoding: 30..<42)),
                (start: 200, bases: plusStrand(ofCoding: 20..<30))
            ]
        )

        let result = try XCTUnwrap(
            TranslationEngine.translateCDS(annotation: annotation, sequenceProvider: clamping(bases))
        )

        XCTAssertEqual(result.codingSequence, coding(20..<42))
        XCTAssertEqual(result.phaseOffset, 0)
        XCTAssertEqual(result.protein, "IPGSVR*")
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.first)), [227, 230])
    }

    /// Forward, [0,31), the record ends at 25. A 3' clip changes no phase and drops the partial codon.
    func testForwardClampedAtRecordEndDropsThePartialCodon() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "case4",
            intervals: [AnnotationInterval(start: 0, end: 31, phase: 0)],
            strand: .forward
        )
        let bases = record(length: 25, [(start: 0, bases: coding(0..<25))])

        let result = try XCTUnwrap(
            TranslationEngine.translateCDS(annotation: annotation, sequenceProvider: clamping(bases))
        )

        XCTAssertEqual(result.codingSequence, coding(0..<25))
        XCTAssertEqual(result.phaseOffset, 0)
        XCTAssertEqual(result.protein, "MAKRWHEF")
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.first)), [0, 3])
    }
}
