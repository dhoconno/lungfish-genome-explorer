// TranslationEngineTests.swift - Tests for core translation engine
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

// MARK: - TranslationEngine Tests

final class TranslationEngineTests: XCTestCase {

    // MARK: - Basic Translation

    func testBasicTranslation() {
        let protein = TranslationEngine.translate("ATGGCAGCATAA")
        XCTAssertEqual(protein, "MAA*")
    }

    func testTranslationWithOffset1() {
        // Skip 1 base: A TGG CAG CAT AA -> TGG=W, CAG=Q, CAT=H
        let protein = TranslationEngine.translate("ATGGCAGCATAA", offset: 1)
        XCTAssertEqual(protein, "WQH")
    }

    func testTranslationWithOffset2() {
        // Skip 2 bases: AT GGC AGC ATA A -> GGC=G, AGC=S, ATA=I
        let protein = TranslationEngine.translate("ATGGCAGCATAA", offset: 2)
        XCTAssertEqual(protein, "GSI")
    }

    func testTrimToFirstStop() {
        let protein = TranslationEngine.translate("ATGGCATAAGCA", trimToFirstStop: true)
        XCTAssertEqual(protein, "MA")
    }

    func testHideStopCodons() {
        let protein = TranslationEngine.translate("ATGGCATAAGCA", showStopAsAsterisk: false)
        XCTAssertEqual(protein, "MAA")
    }

    func testPartialCodonIgnored() {
        // 7 bases = 2 codons + 1 leftover
        let protein = TranslationEngine.translate("ATGGCAN")
        XCTAssertEqual(protein, "MA")
    }

    func testUnknownCodonTranslatesAsX() {
        let protein = TranslationEngine.translate("ATGNNN")
        XCTAssertEqual(protein, "MX")
    }

    func testEmptySequence() {
        let protein = TranslationEngine.translate("")
        XCTAssertEqual(protein, "")
    }

    func testSequenceTooShort() {
        let protein = TranslationEngine.translate("AT")
        XCTAssertEqual(protein, "")
    }

    func testRNASequence() {
        let protein = TranslationEngine.translate("AUGGCAUAA")
        XCTAssertEqual(protein, "MA*")
    }

    func testCaseInsensitive() {
        let protein = TranslationEngine.translate("atggcataa")
        XCTAssertEqual(protein, "MA*")
    }

    // MARK: - Alternative Codon Tables

    func testVertebrateMitoTable() {
        let table = CodonTable.vertebrateMitochondrial
        // TGA = Trp (not stop), AGA = Stop (not Arg)
        let protein = TranslationEngine.translate("TGAAGA", table: table)
        XCTAssertEqual(protein, "W*")
    }

    func testYeastMitoTable() {
        let table = CodonTable.yeastMitochondrial
        // CTN = Thr (not Leu), TGA = Trp (not stop)
        let protein = TranslationEngine.translate("CTATGA", table: table)
        XCTAssertEqual(protein, "TW")
    }

    func testBacterialTable() {
        let table = CodonTable.bacterial
        // Same translations as standard, but different start codons
        let protein = TranslationEngine.translate("ATGGCA", table: table)
        XCTAssertEqual(protein, "MA")

        // GTG is a start codon in bacterial but translates as V
        XCTAssertTrue(table.isStartCodon("GTG"))
        XCTAssertEqual(table.translate("GTG"), "V")
    }

    func testCodonTableLookupByName() {
        XCTAssertNotNil(CodonTable.table(named: "standard"))
        XCTAssertNotNil(CodonTable.table(named: "vertebrate_mito"))
        XCTAssertNotNil(CodonTable.table(named: "bacterial"))
        XCTAssertNotNil(CodonTable.table(named: "yeast_mito"))
        XCTAssertNil(CodonTable.table(named: "nonexistent"))
    }

    func testCodonTableLookupById() {
        XCTAssertNotNil(CodonTable.table(id: 1))
        XCTAssertNotNil(CodonTable.table(id: 2))
        XCTAssertNotNil(CodonTable.table(id: 3))
        XCTAssertNotNil(CodonTable.table(id: 11))
        XCTAssertNil(CodonTable.table(id: 999))
    }

    func testCodonTableLookupByFullName() {
        XCTAssertNotNil(CodonTable.table(named: "Standard"))
        XCTAssertNotNil(CodonTable.table(named: "Vertebrate Mitochondrial"))
    }

    func testAllTablesCount() {
        XCTAssertEqual(CodonTable.allTables.count, 4)
    }

    // MARK: - Reverse Complement

    func testReverseComplement() {
        XCTAssertEqual(TranslationEngine.reverseComplement("ATCG"), "CGAT")
    }

    func testReverseComplementPreservesCase() {
        XCTAssertEqual(TranslationEngine.reverseComplement("AtCg"), "cGaT")
    }

    func testReverseComplementAmbiguity() {
        XCTAssertEqual(TranslationEngine.reverseComplement("RYSWKM"), "KMWSRY")
    }

    func testReverseComplementRNA() {
        // U -> A (complement of U is A in DNA context)
        XCTAssertEqual(TranslationEngine.reverseComplement("AUCG"), "CGAT")
    }

    func testReverseComplementEmpty() {
        XCTAssertEqual(TranslationEngine.reverseComplement(""), "")
    }

    func testReverseComplementIsInvolution() {
        let seq = "ATCGATCG"
        XCTAssertEqual(
            TranslationEngine.reverseComplement(TranslationEngine.reverseComplement(seq)),
            seq
        )
    }

    // MARK: - Six Reading Frames

    func testSixFrameTranslation() {
        // ATG GCA TAA = M A *
        // Reverse complement: TTA TGC CAT
        let sequence = "ATGGCATAA"
        let results = TranslationEngine.translateFrames(ReadingFrame.allCases, sequence: sequence)
        XCTAssertEqual(results.count, 6)

        // Check frame +1
        let plus1 = results.first { $0.0 == .plus1 }?.1
        XCTAssertEqual(plus1, "MA*")
    }

    func testForwardFramesOnly() {
        let sequence = "ATGGCATAA"
        let results = TranslationEngine.translateFrames(ReadingFrame.forwardFrames, sequence: sequence)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { !$0.0.isReverse })
    }

    func testReverseFramesOnly() {
        let sequence = "ATGGCATAA"
        let results = TranslationEngine.translateFrames(ReadingFrame.reverseFrames, sequence: sequence)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.0.isReverse })
    }

    func testReverseFrame1Translation() {
        // Forward: TTATGCCAT
        // RC: ATGGCATAA -> ATG GCA TAA -> M A *
        let sequence = "TTATGCCAT"
        let results = TranslationEngine.translateFrames([.minus1], sequence: sequence)
        XCTAssertEqual(results.first?.1, "MA*")
    }

    // MARK: - CDS Translation (Single Exon)

    func testSingleExonCDS() {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "test_cds",
            intervals: [AnnotationInterval(start: 0, end: 9)],
            strand: .forward
        )

        let sequence = "ATGGCATAA"
        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { start, end in
                let s = sequence.index(sequence.startIndex, offsetBy: start)
                let e = sequence.index(sequence.startIndex, offsetBy: min(end, sequence.count))
                return String(sequence[s..<e])
            }
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.protein, "MA*")
        XCTAssertEqual(result?.codingSequence, "ATGGCATAA")
        XCTAssertEqual(result?.phaseOffset, 0)
        XCTAssertEqual(result?.aminoAcidPositions.count, 3)
    }

    func testSingleExonCDSCoordinateMapping() {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "test_cds",
            intervals: [AnnotationInterval(start: 100, end: 109)],
            strand: .forward
        )

        let sequence = "ATGGCATAA"
        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { _, _ in sequence }
        )

        XCTAssertNotNil(result)
        // First amino acid (M) at codons positions 100-103
        let firstAA = result!.aminoAcidPositions[0]
        XCTAssertEqual(firstAA.aminoAcid, "M")
        XCTAssertEqual(firstAA.codon, "ATG")
        XCTAssertTrue(firstAA.isStart)
        XCTAssertEqual(firstAA.genomicRanges.count, 1)
        XCTAssertEqual(firstAA.genomicRanges[0].start, 100)
        XCTAssertEqual(firstAA.genomicRanges[0].end, 103)

        // Stop codon
        let stopAA = result!.aminoAcidPositions[2]
        XCTAssertEqual(stopAA.aminoAcid, "*")
        XCTAssertTrue(stopAA.isStop)
    }

    // MARK: - CDS Translation (Multi-Exon)

    func testThreeExonCDS() {
        // Gene with 3 exons, introns removed
        // Exon 1: positions 0-5 = "ATGGCA" (6 bp)
        // Exon 2: positions 100-105 = "GCAGCA" (6 bp)
        // Exon 3: positions 200-205 = "GCATAA" (6 bp)
        // Concatenated: ATGGCAGCAGCAGCATAA = M A A A A *

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "multi_exon_cds",
            intervals: [
                AnnotationInterval(start: 0, end: 6),
                AnnotationInterval(start: 100, end: 106),
                AnnotationInterval(start: 200, end: 206)
            ],
            strand: .forward
        )

        let sequenceMap: [ClosedRange<Int>: String] = [
            0...5: "ATGGCA",
            100...105: "GCAGCA",
            200...205: "GCATAA"
        ]

        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { start, end in
                for (range, seq) in sequenceMap {
                    if range.lowerBound == start { return seq }
                }
                return nil
            }
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.protein, "MAAAA*")
        XCTAssertEqual(result?.codingSequence, "ATGGCAGCAGCAGCATAA")
        XCTAssertEqual(result?.aminoAcidPositions.count, 6)
    }

    func testIntronSpanningCodon() {
        // Exon 1: positions 0-4 = "ATGGC" (5 bp) — codon splits at boundary
        // Exon 2: positions 100-106 = "AGCATAA" (7 bp)
        // Concatenated: ATGGCAGCATAA = ATG GCA GCA TAA = M A A *
        // The second codon "GCA" spans: G from exon 1 (pos 3-4), CA from exon 2 (pos 100-101)

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "split_codon_cds",
            intervals: [
                AnnotationInterval(start: 0, end: 5),
                AnnotationInterval(start: 100, end: 107)
            ],
            strand: .forward
        )

        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { start, _ in
                if start == 0 { return "ATGGC" }
                if start == 100 { return "AGCATAA" }
                return nil
            }
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.protein, "MAA*")

        // Second amino acid's codon spans the intron
        // G at genomic pos 3, C at pos 4, A at pos 100
        let secondAA = result!.aminoAcidPositions[1]
        XCTAssertEqual(secondAA.aminoAcid, "A")
        XCTAssertEqual(secondAA.codon, "GCA")
        XCTAssertEqual(secondAA.genomicRanges.count, 2)
        // First part from exon 1 (positions 3,4)
        XCTAssertEqual(secondAA.genomicRanges[0].start, 3)
        XCTAssertEqual(secondAA.genomicRanges[0].end, 5)
        // Second part from exon 2 (position 100)
        XCTAssertEqual(secondAA.genomicRanges[1].start, 100)
        XCTAssertEqual(secondAA.genomicRanges[1].end, 101)
    }

    // MARK: - Phase Offset

    func testPhaseOffset0() {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "test",
            intervals: [AnnotationInterval(start: 0, end: 9, phase: 0)],
            strand: .forward
        )

        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { _, _ in "ATGGCATAA" }
        )

        XCTAssertEqual(result?.protein, "MA*")
        XCTAssertEqual(result?.phaseOffset, 0)
    }

    func testPhaseOffset1() {
        // Phase 1: skip 1 base before first codon
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "test",
            intervals: [AnnotationInterval(start: 0, end: 10, phase: 1)],
            strand: .forward
        )

        // N ATG GCA TAA -> skip N, translate ATG GCA TAA
        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { _, _ in "NATGGCATAA" }
        )

        XCTAssertEqual(result?.protein, "MA*")
        XCTAssertEqual(result?.phaseOffset, 1)
    }

    func testPhaseOffset2() {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "test",
            intervals: [AnnotationInterval(start: 0, end: 11, phase: 2)],
            strand: .forward
        )

        // NN ATG GCA TAA -> skip NN
        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { _, _ in "NNATGGCATAA" }
        )

        XCTAssertEqual(result?.protein, "MA*")
        XCTAssertEqual(result?.phaseOffset, 2)
    }

    // MARK: - Reverse Strand CDS

    func testReverseStrandSingleExon() {
        // Forward sequence at positions 0-8: "TTATGCCAT"
        // RC: "ATGGCATAA" -> ATG GCA TAA -> M A *
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "rev_cds",
            intervals: [AnnotationInterval(start: 0, end: 9)],
            strand: .reverse
        )

        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { _, _ in "TTATGCCAT" }
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.protein, "MA*")
    }

    func testReverseStrandMultiExon() {
        // Reverse strand: exons are read in reverse genomic order
        // Exon at 200-206: "TTATGC" -> RC contributes to start of protein
        // Exon at 0-6: "GCATAA" -> RC contributes to end of protein
        // Reading order (reverse strand): exon 200-206 first, then exon 0-6
        // Concatenated forward: "TTATGC" + "GCATAA" (but reversed for - strand)
        // Actually for reverse strand, we concatenate in descending start order:
        //   exon 200-206 ("TTATGC") then exon 0-6 ("GCATAA")
        //   concat = "TTATGCGCATAA"
        //   RC = "TTATGCGCATAA" -> that's the same... let me think more carefully

        // For reverse strand CDS:
        // Exon 1 (rightmost first): positions 200-206 = "GCATAA"
        // Exon 2 (leftmost second): positions 0-6 = "TTATGC"
        // Sorted descending by start: exon 200-206 first, then 0-6
        // Concatenated: "GCATAA" + "TTATGC" = "GCATAATTATGC"
        // RC of concatenated: "GCATAATTATGC" -> RC = "GCATAATTATGC" let me compute
        // G->C, C->G, A->T, T->A, A->T, A->T, T->A, T->A, A->T, T->A, G->C, C->G
        // reversed: C, G, A, T, A, A, T, T, A, T, G, C -> "CGATAAT TATGC"...

        // Let me use a simpler example.
        // Forward genomic: exon at 0-3 = "CAT", exon at 100-106 = "TTATGC"
        // For reverse strand, sorted descending: 100-106 then 0-3
        // concat = "TTATGC" + "CAT" = "TTATGCCAT"
        // RC = ATGGCATAA -> ATG GCA TAA -> M A *

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "rev_multi_exon",
            intervals: [
                AnnotationInterval(start: 0, end: 3),
                AnnotationInterval(start: 100, end: 106)
            ],
            strand: .reverse
        )

        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { start, _ in
                if start == 100 { return "TTATGC" }
                if start == 0 { return "CAT" }
                return nil
            }
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.protein, "MA*")
    }

    // MARK: - Edge Cases

    func testEmptyAnnotation() {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "empty",
            start: 0,
            end: 0
        )

        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { _, _ in "" }
        )

        XCTAssertNil(result)
    }

    func testSequenceProviderReturnsNil() {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "test",
            intervals: [AnnotationInterval(start: 0, end: 9)],
            strand: .forward
        )

        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { _, _ in nil }
        )

        XCTAssertNil(result)
    }

    func testAllStopCodons() {
        let protein = TranslationEngine.translate("TAATAGTGA")
        XCTAssertEqual(protein, "***")
    }

    func testAllAminoAcids() {
        // Verify all 20 standard amino acids can be produced
        let table = CodonTable.standard
        let aminoAcids = Set("ACDEFGHIKLMNPQRSTVWY".map { $0 })
        var produced = Set<Character>()

        for (_, aa) in [
            ("GCT", "A"), ("TGT", "C"), ("GAT", "D"), ("GAA", "E"),
            ("TTT", "F"), ("GGT", "G"), ("CAT", "H"), ("ATT", "I"),
            ("AAA", "K"), ("TTA", "L"), ("ATG", "M"), ("AAT", "N"),
            ("CCT", "P"), ("CAA", "Q"), ("CGT", "R"), ("TCT", "S"),
            ("ACT", "T"), ("GTT", "V"), ("TGG", "W"), ("TAT", "Y")
        ] as [(String, String)] {
            let result = table.translate(aa == "A" ? "GCT" :
                                        aa == "C" ? "TGT" :
                                        aa == "D" ? "GAT" :
                                        aa == "E" ? "GAA" :
                                        aa == "F" ? "TTT" :
                                        aa == "G" ? "GGT" :
                                        aa == "H" ? "CAT" :
                                        aa == "I" ? "ATT" :
                                        aa == "K" ? "AAA" :
                                        aa == "L" ? "TTA" :
                                        aa == "M" ? "ATG" :
                                        aa == "N" ? "AAT" :
                                        aa == "P" ? "CCT" :
                                        aa == "Q" ? "CAA" :
                                        aa == "R" ? "CGT" :
                                        aa == "S" ? "TCT" :
                                        aa == "T" ? "ACT" :
                                        aa == "V" ? "GTT" :
                                        aa == "W" ? "TGG" : "TAT")
            produced.insert(result)
        }

        XCTAssertEqual(produced, aminoAcids)
    }

    func testStartAndStopCodonFlags() {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "test",
            intervals: [AnnotationInterval(start: 0, end: 9)],
            strand: .forward
        )

        let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { _, _ in "ATGGCATAA" }
        )

        XCTAssertNotNil(result)
        let positions = result!.aminoAcidPositions

        // ATG is a start codon
        XCTAssertTrue(positions[0].isStart)
        XCTAssertFalse(positions[0].isStop)

        // GCA is neither
        XCTAssertFalse(positions[1].isStart)
        XCTAssertFalse(positions[1].isStop)

        // TAA is a stop codon
        XCTAssertFalse(positions[2].isStart)
        XCTAssertTrue(positions[2].isStop)
    }
}

// MARK: - AminoAcidColorScheme Tests

final class AminoAcidColorSchemeTests: XCTestCase {

    func testZappoSchemeReturnsValidColors() {
        let scheme = AminoAcidColorScheme.zappo
        let aminoAcids: [Character] = Array("ACDEFGHIKLMNPQRSTVWY*X")

        for aa in aminoAcids {
            let color = scheme.color(for: aa)
            XCTAssertTrue(color.red >= 0 && color.red <= 1, "Red out of range for \(aa)")
            XCTAssertTrue(color.green >= 0 && color.green <= 1, "Green out of range for \(aa)")
            XCTAssertTrue(color.blue >= 0 && color.blue <= 1, "Blue out of range for \(aa)")
        }
    }

    func testClustalSchemeReturnsValidColors() {
        let scheme = AminoAcidColorScheme.clustal
        for aa in Array("ACDEFGHIKLMNPQRSTVWY*") {
            let color = scheme.color(for: aa)
            XCTAssertTrue(color.red >= 0 && color.red <= 1)
            XCTAssertTrue(color.green >= 0 && color.green <= 1)
            XCTAssertTrue(color.blue >= 0 && color.blue <= 1)
        }
    }

    func testTaylorSchemeReturnsValidColors() {
        let scheme = AminoAcidColorScheme.taylor
        for aa in Array("ACDEFGHIKLMNPQRSTVWY*") {
            let color = scheme.color(for: aa)
            XCTAssertTrue(color.red >= 0 && color.red <= 1)
            XCTAssertTrue(color.green >= 0 && color.green <= 1)
            XCTAssertTrue(color.blue >= 0 && color.blue <= 1)
        }
    }

    func testHydrophobicitySchemeReturnsValidColors() {
        let scheme = AminoAcidColorScheme.hydrophobicity
        for aa in Array("ACDEFGHIKLMNPQRSTVWY*") {
            let color = scheme.color(for: aa)
            XCTAssertTrue(color.red >= 0 && color.red <= 1)
            XCTAssertTrue(color.green >= 0 && color.green <= 1)
            XCTAssertTrue(color.blue >= 0 && color.blue <= 1)
        }
    }

    func testZappoGroupColors() {
        let scheme = AminoAcidColorScheme.zappo

        // Aliphatic amino acids should all get the same color
        let iColor = scheme.color(for: "I")
        let lColor = scheme.color(for: "L")
        XCTAssertEqual(iColor.red, lColor.red, accuracy: 0.01)
        XCTAssertEqual(iColor.green, lColor.green, accuracy: 0.01)
        XCTAssertEqual(iColor.blue, lColor.blue, accuracy: 0.01)

        // Positive (K, R, H) should be different from aliphatic
        let kColor = scheme.color(for: "K")
        XCTAssertNotEqual(iColor.red, kColor.red, accuracy: 0.1)
    }

    func testAllSchemesIterable() {
        XCTAssertEqual(AminoAcidColorScheme.allCases.count, 4)
    }

    func testDisplayNames() {
        XCTAssertEqual(AminoAcidColorScheme.zappo.displayName, "Zappo")
        XCTAssertEqual(AminoAcidColorScheme.clustal.displayName, "ClustalX")
        XCTAssertEqual(AminoAcidColorScheme.taylor.displayName, "Taylor")
        XCTAssertEqual(AminoAcidColorScheme.hydrophobicity.displayName, "Hydrophobicity")
    }
}

// MARK: - GenomicRange Tests

final class GenomicRangeTests: XCTestCase {

    func testLength() {
        let range = GenomicRange(start: 100, end: 200)
        XCTAssertEqual(range.length, 100)
    }

    func testEquality() {
        let a = GenomicRange(start: 10, end: 20)
        let b = GenomicRange(start: 10, end: 20)
        let c = GenomicRange(start: 10, end: 30)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
