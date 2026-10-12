// TranslationFrameClampTests.swift - Reading frame of a CDS that the end of the record clips
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// Phase 2.8 lane B6, decision G1 and row 418 of the Phase 2.7 plan.
///
/// Each case reads its bases through the viewer's single-sequence provider. A request that runs past
/// the end of the record returns the bases that exist, and a request that starts at or after the end
/// returns nil. One coding sequence is cut several ways. Its protein is M A K R W H E F P D Q Y G S.
///
/// The frame offset is ((p - r) mod 3). Here p is the phase of the original 5'-most segment and r counts
/// the coding bases lost before the first base that was read. The first four tests are the four cases of
/// the bioinformatics inventory 1.5. Their expectations were pinned at the base commit and the fix flips
/// the three that lose the 5' end of a reverse-strand CDS. The forward case stays as it was.
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
        XCTAssertEqual(result.phaseOffset, 2)
        XCTAssertEqual(result.protein, "WHEFPD")
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.first)), [115, 118])
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
        XCTAssertEqual(result.phaseOffset, 1)
        XCTAssertEqual(result.protein, "QYGS")
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.first)), [111, 114])
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
        XCTAssertEqual(result.phaseOffset, 1)
        XCTAssertEqual(result.protein, "FPDQYGS")
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.first)), [206, 209])
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

    // MARK: - Around the four cases

    /// A clip of whole codons keeps the frame, and the codons still map to the bases that were read.
    func testReverseClipOfWholeCodonsKeepsTheFrameAndMapsTheCodons() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "whole-codons",
            intervals: [AnnotationInterval(start: 100, end: 130, phase: 0)],
            strand: .reverse
        )
        let bases = record(length: 121, [(start: 100, bases: plusStrand(ofCoding: 9..<30))])

        let result = try XCTUnwrap(
            TranslationEngine.translateCDS(annotation: annotation, sequenceProvider: clamping(bases))
        )

        XCTAssertEqual(result.phaseOffset, 0)
        XCTAssertEqual(result.protein, "RWHEFPD")
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.first)), [118, 121])
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.last)), [100, 103])
    }

    /// A phase other than 0 on the 5'-most segment carries through a dropped segment. Here codon_start is
    /// 2, so p is 1, and 29 coding bases are gone, so the frame starts at base ((1 - 29) mod 3) = 2.
    func testReverseGenBankPhaseOneCarriesThroughADroppedSegment() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "phase-one",
            intervals: [
                AnnotationInterval(start: 100, end: 115),
                AnnotationInterval(start: 200, end: 229, phase: 1)
            ],
            strand: .reverse
        )
        let bases = record(length: 190, [(start: 100, bases: plusStrand(ofCoding: 29..<44))])

        let result = try XCTUnwrap(
            TranslationEngine.translateCDS(annotation: annotation, sequenceProvider: clamping(bases))
        )

        XCTAssertEqual(result.phaseOffset, 2)
        XCTAssertEqual(result.protein, "STVA")
    }

    /// When every segment records a phase that agrees with the 5'-most one and the lengths, the rule gives the
    /// phase the first segment read records.
    func testReverseSegmentsThatRecordTheirOwnPhaseAgreeWithTheRule() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "gff3-phases",
            intervals: [
                AnnotationInterval(start: 100, end: 115, phase: 1),
                AnnotationInterval(start: 200, end: 229, phase: 0)
            ],
            strand: .reverse
        )
        let bases = record(length: 190, [(start: 100, bases: plusStrand(ofCoding: 29..<44))])

        let result = try XCTUnwrap(
            TranslationEngine.translateCDS(annotation: annotation, sequenceProvider: clamping(bases))
        )

        XCTAssertEqual(result.phaseOffset, 1)
        XCTAssertEqual(result.protein, "QYGS")
    }

    /// A writer that puts 0 in every CDS phase column records a phase on [100,115) that disagrees with p and the
    /// lengths, since 29 bases come before it. Only the phase of the 5'-most segment and the bases lost before
    /// the first base that was read set the frame, so these bases read in the same frame as in the GenBank case
    /// above, and the recorded 0 is not used (decision G1).
    func testARecordedPhaseThatDisagreesWithTheFivePrimeSegmentIsNotUsed() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "phase-zero-everywhere",
            intervals: [
                AnnotationInterval(start: 100, end: 115, phase: 0),
                AnnotationInterval(start: 200, end: 229, phase: 0)
            ],
            strand: .reverse
        )
        let bases = record(length: 190, [(start: 100, bases: plusStrand(ofCoding: 29..<44))])

        let result = try XCTUnwrap(
            TranslationEngine.translateCDS(annotation: annotation, sequenceProvider: clamping(bases))
        )

        XCTAssertEqual(result.phaseOffset, 1)
        XCTAssertEqual(result.protein, "QYGS")
    }

    // MARK: - Residue numbers

    private struct ResidueCase {
        let name: String
        let annotation: SequenceAnnotation
        let bases: String
        let codonsBeforeFirstRead: Int
    }

    /// The first whole codon that was read is residue (codonsBeforeFirstRead + 1) of the whole protein. So the
    /// protein that was read is the whole protein from that residue on, and no codon comes before it when nothing
    /// was lost.
    func testCodonsBeforeTheFirstReadNumberTheResiduesOfTheWholeProtein() throws {
        let whole = "MAKRWHEFPDQYGS"
        let cases = [
            ResidueCase(
                name: "one segment cut by 10 bases",
                annotation: SequenceAnnotation(
                    type: .cds, name: "r1", intervals: [AnnotationInterval(start: 100, end: 130, phase: 0)],
                    strand: .reverse
                ),
                bases: record(length: 120, [(start: 100, bases: plusStrand(ofCoding: 10..<30))]),
                codonsBeforeFirstRead: 4
            ),
            ResidueCase(
                name: "5'-most segment dropped",
                annotation: SequenceAnnotation(
                    type: .cds,
                    name: "r2",
                    intervals: [
                        AnnotationInterval(start: 100, end: 115),
                        AnnotationInterval(start: 200, end: 229, phase: 0)
                    ],
                    strand: .reverse
                ),
                bases: record(length: 190, [(start: 100, bases: plusStrand(ofCoding: 29..<44))]),
                codonsBeforeFirstRead: 10
            ),
            ResidueCase(
                name: "5'-most segment cut by 20 bases",
                annotation: SequenceAnnotation(
                    type: .cds,
                    name: "r3",
                    intervals: [
                        AnnotationInterval(start: 100, end: 112),
                        AnnotationInterval(start: 200, end: 230, phase: 0)
                    ],
                    strand: .reverse
                ),
                bases: record(
                    length: 210,
                    [
                        (start: 100, bases: plusStrand(ofCoding: 30..<42)),
                        (start: 200, bases: plusStrand(ofCoding: 20..<30))
                    ]
                ),
                codonsBeforeFirstRead: 7
            ),
            ResidueCase(
                name: "nothing lost",
                annotation: SequenceAnnotation(
                    type: .cds, name: "r4", intervals: [AnnotationInterval(start: 100, end: 144, phase: 0)],
                    strand: .reverse
                ),
                bases: record(length: 150, [(start: 100, bases: plusStrand(ofCoding: 0..<44))]),
                codonsBeforeFirstRead: 0
            )
        ]

        for residueCase in cases {
            let provider = clamping(residueCase.bases)
            let layout = try XCTUnwrap(
                TranslationEngine.codingLayout(
                    annotation: residueCase.annotation,
                    segmentProvider: { start, end in
                        provider(start, end).map { TranslationEngine.SegmentRead(start: start, sequence: $0) }
                    }
                ),
                residueCase.name
            )
            let result = try XCTUnwrap(
                TranslationEngine.translateCDS(annotation: residueCase.annotation, sequenceProvider: provider),
                residueCase.name
            )

            XCTAssertEqual(layout.codonsBeforeFirstRead, residueCase.codonsBeforeFirstRead, residueCase.name)
            XCTAssertTrue(
                whole.dropFirst(layout.codonsBeforeFirstRead).hasPrefix(result.protein),
                "\(residueCase.name) read \(result.protein) of \(whole)"
            )
        }
    }

    /// The count starts at the first whole codon of the full CDS, which a phase on the 5'-most segment moves. Here p
    /// is 1 and 29 bases are gone, so the frame starts at base 2 of the bases read. That is base 31 of the full CDS,
    /// and its first whole codon starts at base 1, so 10 whole codons come before the first one that was read.
    func testCodonsBeforeTheFirstReadCountFromTheFirstWholeCodonOfTheFullCDS() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "phase-one-residues",
            intervals: [
                AnnotationInterval(start: 100, end: 115),
                AnnotationInterval(start: 200, end: 229, phase: 1)
            ],
            strand: .reverse
        )
        let provider = clamping(record(length: 190, [(start: 100, bases: plusStrand(ofCoding: 29..<44))]))

        let layout = try XCTUnwrap(
            TranslationEngine.codingLayout(
                annotation: annotation,
                segmentProvider: { start, end in
                    provider(start, end).map { TranslationEngine.SegmentRead(start: start, sequence: $0) }
                }
            )
        )

        XCTAssertEqual(layout.phaseOffset, 2)
        XCTAssertEqual(layout.codonsBeforeFirstRead, 10)
    }

    // MARK: - A segment that fails

    /// One CDS of three segments on the given strand. In transcription order they hold coding bases
    /// 0..<18, 18..<30 and 30..<42. The middle segment sits at [200,212) on either strand.
    private func threeSegmentCDS(strand: Strand) -> (annotation: SequenceAnnotation, provider: (Int, Int) -> String?) {
        let forward = strand == .forward
        let segments: [(start: Int, end: Int, codingStart: Int)] = forward
            ? [(100, 118, 0), (200, 212, 18), (300, 312, 30)]
            : [(300, 318, 0), (200, 212, 18), (100, 112, 30)]
        let pieces = segments.map { segment -> (start: Int, bases: String) in
            let range = segment.codingStart..<(segment.codingStart + segment.end - segment.start)
            return (start: segment.start, bases: forward ? coding(range) : plusStrand(ofCoding: range))
        }
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "three-segments",
            intervals: segments
                .map { AnnotationInterval(start: $0.start, end: $0.end) }
                .sorted { $0.start < $1.start },
            strand: strand
        )
        return (annotation, clamping(record(length: 400, pieces)))
    }

    /// The fixture reads whole on both strands, which is what the two tests below start from.
    func testThreeSegmentFixtureTranslatesWhole() throws {
        for strand in [Strand.forward, Strand.reverse] {
            let cds = threeSegmentCDS(strand: strand)
            let result = try XCTUnwrap(
                TranslationEngine.translateCDS(annotation: cds.annotation, sequenceProvider: cds.provider),
                "\(strand) strand"
            )
            XCTAssertEqual(result.protein, "MAKRWHEFPDQYGS", "\(strand) strand")
            XCTAssertEqual(result.phaseOffset, 0, "\(strand) strand")
        }
    }

    /// A segment that fails between two that were read leaves a hole in the coding sequence. Joining
    /// across it gives a frameshifted protein, so the answer is no protein on either strand.
    func testAFailedInteriorSegmentGivesNoProtein() {
        for strand in [Strand.forward, Strand.reverse] {
            let cds = threeSegmentCDS(strand: strand)
            let result = TranslationEngine.translateCDS(
                annotation: cds.annotation,
                sequenceProvider: { start, end in start == 200 ? nil : cds.provider(start, end) }
            )
            XCTAssertNil(result, "\(strand) strand")
        }
    }

    /// A failure at the 3' end only shortens the coding sequence, so the segments before it translate.
    func testAFailedLastSegmentKeepsTheProteinOfTheSegmentsBeforeIt() throws {
        for strand in [Strand.forward, Strand.reverse] {
            let cds = threeSegmentCDS(strand: strand)
            let lastStart = strand == .forward ? 300 : 100
            let result = try XCTUnwrap(
                TranslationEngine.translateCDS(
                    annotation: cds.annotation,
                    sequenceProvider: { start, end in start == lastStart ? nil : cds.provider(start, end) }
                ),
                "\(strand) strand"
            )
            XCTAssertEqual(result.protein, "MAKRWHEFPD", "\(strand) strand")
        }
    }

    // MARK: - A provider that says where its bases start

    /// A window onto a plus-strand record that starts at `windowStart`, read the way the viewer's cached
    /// window is. It cuts a range at either end and reports where the bases it kept start.
    private func window(_ record: String, from windowStart: Int) -> (Int, Int) -> TranslationEngine.SegmentRead? {
        let bases = Array(record)
        return { start, end in
            let clampedStart = max(windowStart, start)
            let clampedEnd = min(windowStart + bases.count, end)
            guard clampedStart < clampedEnd else { return nil }
            return TranslationEngine.SegmentRead(
                start: clampedStart,
                sequence: String(bases[(clampedStart - windowStart)..<(clampedEnd - windowStart)])
            )
        }
    }

    /// Forward, [100,142). A window that starts at 110 cuts 10 bases from the 5' end of the CDS.
    func testAWindowThatCutsTheStartOfAForwardCDSMovesTheFrame() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "forward-window",
            intervals: [AnnotationInterval(start: 100, end: 142, phase: 0)],
            strand: .forward
        )
        let provider = window(coding(10..<42) + String(repeating: "N", count: 8), from: 110)

        let result = try XCTUnwrap(TranslationEngine.translateCDS(annotation: annotation, segmentProvider: provider))

        XCTAssertEqual(result.phaseOffset, 2)
        XCTAssertEqual(result.protein, "WHEFPDQYGS")
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.first)), [112, 115])
    }

    /// Reverse, [100,142). A window that starts at 110 cuts the low end, which is the 3' end of a reverse-strand
    /// CDS. The frame stays and the codons keep the coordinates they have without a window.
    func testAWindowThatCutsTheLowEndOfAReverseCDSKeepsTheFrame() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "reverse-window-low",
            intervals: [AnnotationInterval(start: 100, end: 142, phase: 0)],
            strand: .reverse
        )
        let provider = window(plusStrand(ofCoding: 0..<32) + String(repeating: "N", count: 8), from: 110)

        let result = try XCTUnwrap(TranslationEngine.translateCDS(annotation: annotation, segmentProvider: provider))

        XCTAssertEqual(result.phaseOffset, 0)
        XCTAssertEqual(result.protein, "MAKRWHEFPD")
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.first)), [139, 142])
    }

    /// Reverse, [100,142). A window that ends at 125 cuts 17 bases from the 5' end of the CDS.
    func testAWindowThatCutsTheHighEndOfAReverseCDSMovesTheFrame() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "reverse-window-high",
            intervals: [AnnotationInterval(start: 100, end: 142, phase: 0)],
            strand: .reverse
        )
        let provider = window(String(repeating: "N", count: 10) + plusStrand(ofCoding: 17..<42), from: 90)

        let result = try XCTUnwrap(TranslationEngine.translateCDS(annotation: annotation, segmentProvider: provider))

        XCTAssertEqual(result.phaseOffset, 1)
        XCTAssertEqual(result.protein, "EFPDQYGS")
        XCTAssertEqual(span(of: try XCTUnwrap(result.aminoAcidPositions.first)), [121, 124])
    }

    /// A segment that is short at its 3' end while another follows it leaves a gap in the coding sequence.
    func testAClipBetweenTwoSegmentsGivesNoProtein() {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "gap",
            intervals: [AnnotationInterval(start: 100, end: 118), AnnotationInterval(start: 200, end: 212)],
            strand: .forward
        )

        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            segmentProvider: { start, _ in
                start == 100
                    ? TranslationEngine.SegmentRead(start: 100, sequence: self.coding(0..<10))
                    : TranslationEngine.SegmentRead(start: 200, sequence: self.coding(18..<30))
            }
        )

        XCTAssertNil(result)
    }

    // MARK: - The extractor

    /// The extractor asks a provider that refuses a range past the end of the chromosome. It clamps the
    /// range with the chromosome length first, so the protein it attaches follows the same rule.
    func testExtractorProteinOfAReverseCDSThatRunsPastTheChromosomeEnd() throws {
        let bases = Array(record(length: 120, [(start: 100, bases: plusStrand(ofCoding: 10..<30))]))
        let strict: SequenceExtractor.SequenceProvider = { _, start, end in
            guard start >= 0, end <= bases.count, start < end else { return nil }
            return String(bases[start..<end])
        }
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "past-the-end",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 130, phase: 0)],
            strand: .reverse
        )

        let result = try SequenceExtractor.extract(
            request: ExtractionRequest.defaultAnnotationRequest(for: annotation),
            sequenceProvider: strict,
            chromosomeLength: 120
        )

        XCTAssertEqual(result.nucleotideSequence, coding(10..<30))
        XCTAssertEqual(result.proteinSequence, "WHEFPD")
    }
}
