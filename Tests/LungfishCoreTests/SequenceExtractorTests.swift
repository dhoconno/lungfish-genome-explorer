// SequenceExtractorTests.swift - Tests for sequence extraction logic
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SequenceExtractorTests: XCTestCase {

    // A simple sequence provider that returns a substring of a known genome.
    // Genome: 200 bases of repeating "ACGT"
    let genome = String(repeating: "ACGT", count: 50) // 200 bp
    let chromLength = 200

    func makeProvider() -> SequenceExtractor.SequenceProvider {
        let g = genome
        return { _, start, end in
            guard start >= 0, end <= g.count, start < end else { return nil }
            let startIdx = g.index(g.startIndex, offsetBy: start)
            let endIdx = g.index(g.startIndex, offsetBy: end)
            return String(g[startIdx..<endIdx])
        }
    }

    // MARK: - Region Extraction

    func testExtractSimpleRegion() throws {
        let request = ExtractionRequest(
            source: .region(chromosome: "chr1", start: 10, end: 20)
        )

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        XCTAssertEqual(result.nucleotideSequence.count, 10)
        XCTAssertEqual(result.effectiveStart, 10)
        XCTAssertEqual(result.effectiveEnd, 20)
        XCTAssertEqual(result.chromosome, "chr1")
        XCTAssertFalse(result.isReverseComplement)
        XCTAssertNil(result.proteinSequence)
    }

    func testExtractRegionWithFlanking() throws {
        let request = ExtractionRequest(
            source: .region(chromosome: "chr1", start: 20, end: 30),
            flank5Prime: 5,
            flank3Prime: 10
        )

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        // 10bp region + 5bp 5' + 10bp 3' = 25bp
        XCTAssertEqual(result.nucleotideSequence.count, 25)
        XCTAssertEqual(result.effectiveStart, 15)
        XCTAssertEqual(result.effectiveEnd, 40)
    }

    func testFlankingClampedToChromosomeBounds() throws {
        let request = ExtractionRequest(
            source: .region(chromosome: "chr1", start: 2, end: 10),
            flank5Prime: 100,
            flank3Prime: 500
        )

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        // 5' clamped to 0, 3' clamped to 200
        XCTAssertEqual(result.effectiveStart, 0)
        XCTAssertEqual(result.effectiveEnd, chromLength)
        XCTAssertEqual(result.nucleotideSequence.count, chromLength)
    }

    func testExtractRegionReverseComplement() throws {
        let request = ExtractionRequest(
            source: .region(chromosome: "chr1", start: 0, end: 4),
            reverseComplement: true
        )

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        // genome starts with "ACGT", RC of "ACGT" is "ACGT"
        XCTAssertEqual(result.nucleotideSequence, "ACGT")
        XCTAssertTrue(result.isReverseComplement)
    }

    func testExtractRegionRCDifferentSequence() throws {
        // Use a custom provider with asymmetric sequence
        let customProvider: SequenceExtractor.SequenceProvider = { _, start, end in
            let seq = "AAACCCTTTGGG"
            guard start >= 0, end <= seq.count else { return nil }
            let s = seq.index(seq.startIndex, offsetBy: start)
            let e = seq.index(seq.startIndex, offsetBy: end)
            return String(seq[s..<e])
        }

        let request = ExtractionRequest(
            source: .region(chromosome: "chr1", start: 0, end: 6),
            reverseComplement: true
        )

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: customProvider,
            chromosomeLength: 12
        )

        // "AAACCC" -> RC -> "GGGTTT"
        XCTAssertEqual(result.nucleotideSequence, "GGGTTT")
    }

    func testEmptyRegionThrows() {
        let request = ExtractionRequest(
            source: .region(chromosome: "chr1", start: 10, end: 10)
        )

        XCTAssertThrowsError(try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )) { error in
            XCTAssertTrue(error is ExtractionError)
        }
    }

    // MARK: - Contiguous Annotation Extraction

    func testExtractContiguousAnnotation() throws {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "TestGene",
            chromosome: "chr1",
            start: 10,
            end: 30,
            strand: .forward
        )

        let request = ExtractionRequest(source: .annotation(annotation))

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        XCTAssertEqual(result.nucleotideSequence.count, 20)
        XCTAssertEqual(result.effectiveStart, 10)
        XCTAssertEqual(result.effectiveEnd, 30)
        XCTAssertEqual(result.sourceName, "TestGene")
        XCTAssertNil(result.proteinSequence)
    }

    func testExtractAnnotationWithFlanking() throws {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "TestGene",
            chromosome: "chr1",
            start: 20,
            end: 40,
            strand: .forward
        )

        let request = ExtractionRequest(
            source: .annotation(annotation),
            flank5Prime: 10,
            flank3Prime: 5
        )

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        // 20bp annotation + 10bp 5' + 5bp 3' = 35bp
        XCTAssertEqual(result.nucleotideSequence.count, 35)
        XCTAssertEqual(result.effectiveStart, 10)
        XCTAssertEqual(result.effectiveEnd, 45)
    }

    // MARK: - Discontiguous Annotation Extraction

    func testExtractDiscontiguousAnnotationFullRegion() throws {
        // Two exons: 10-20 and 30-40
        let annotation = SequenceAnnotation(
            type: .mRNA,
            name: "TestmRNA",
            chromosome: "chr1",
            intervals: [
                AnnotationInterval(start: 10, end: 20),
                AnnotationInterval(start: 30, end: 40)
            ],
            strand: .forward
        )

        // Without concatenation: fetch full bounding region 10-40
        let request = ExtractionRequest(
            source: .annotation(annotation),
            concatenateExons: false
        )

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        // Full bounding region: 30bp (10 to 40)
        XCTAssertEqual(result.nucleotideSequence.count, 30)
        XCTAssertEqual(result.effectiveStart, 10)
        XCTAssertEqual(result.effectiveEnd, 40)
    }

    func testExtractDiscontiguousConcatenated() throws {
        // Two exons: 10-20 and 30-40
        let annotation = SequenceAnnotation(
            type: .mRNA,
            name: "TestmRNA",
            chromosome: "chr1",
            intervals: [
                AnnotationInterval(start: 10, end: 20),
                AnnotationInterval(start: 30, end: 40)
            ],
            strand: .forward
        )

        let request = ExtractionRequest(
            source: .annotation(annotation),
            concatenateExons: true
        )

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        // Concatenated exons: 10bp + 10bp = 20bp (intron removed)
        XCTAssertEqual(result.nucleotideSequence.count, 20)
    }

    func testExtractDiscontiguousConcatenatedWithFlanking() throws {
        let annotation = SequenceAnnotation(
            type: .mRNA,
            name: "TestmRNA",
            chromosome: "chr1",
            intervals: [
                AnnotationInterval(start: 20, end: 30),
                AnnotationInterval(start: 40, end: 50)
            ],
            strand: .forward
        )

        let request = ExtractionRequest(
            source: .annotation(annotation),
            flank5Prime: 5,
            flank3Prime: 5,
            concatenateExons: true
        )

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        // 5bp flank + 10bp exon + 10bp exon + 5bp flank = 30bp
        XCTAssertEqual(result.nucleotideSequence.count, 30)
        XCTAssertEqual(result.effectiveStart, 15)
        XCTAssertEqual(result.effectiveEnd, 55)
    }

    // MARK: - CDS Translation

    func testExtractCDSWithTranslation() throws {
        // Create a CDS with ATG...TAA (simple ORF)
        // ATG GCA GCA TAA = M A A * (12 bp)
        let cdsSequence = "ATGGCAGCATAA"
        let provider: SequenceExtractor.SequenceProvider = { _, start, end in
            guard start >= 0, end <= cdsSequence.count else { return nil }
            let s = cdsSequence.index(cdsSequence.startIndex, offsetBy: start)
            let e = cdsSequence.index(cdsSequence.startIndex, offsetBy: end)
            return String(cdsSequence[s..<e])
        }

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "TestCDS",
            chromosome: "chr1",
            start: 0,
            end: 12,
            strand: .forward
        )

        let request = ExtractionRequest(source: .annotation(annotation))

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: provider,
            chromosomeLength: 12
        )

        XCTAssertEqual(result.nucleotideSequence, "ATGGCAGCATAA")
        XCTAssertNotNil(result.proteinSequence)
        XCTAssertEqual(result.proteinSequence, "MAA*")
    }

    func testNonCDSHasNoTranslation() throws {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "TestGene",
            chromosome: "chr1",
            start: 0,
            end: 20,
            strand: .forward
        )

        let request = ExtractionRequest(source: .annotation(annotation))

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        XCTAssertNil(result.proteinSequence)
    }

    // MARK: - FASTA Formatting

    func testFormatFASTA() throws {
        let result = ExtractionResult(
            fastaHeader: "TestGene [chr1:10-30] [gene] [strand: +] [20 bp]",
            nucleotideSequence: "ACGTACGTACGTACGTACGT",
            proteinSequence: nil,
            sourceName: "TestGene",
            chromosome: "chr1",
            effectiveStart: 10,
            effectiveEnd: 30,
            isReverseComplement: false
        )

        let fasta = SequenceExtractor.formatFASTA(result)

        XCTAssertTrue(fasta.hasPrefix(">TestGene"))
        XCTAssertTrue(fasta.contains("[chr1:10-30]"))
        // Sequence should be on second line
        let lines = fasta.split(separator: "\n")
        XCTAssertEqual(lines.count, 2) // header + sequence (short enough for one line)
    }

    func testFormatFASTAWrapsLongSequence() throws {
        let longSeq = String(repeating: "A", count: 150)
        let result = ExtractionResult(
            fastaHeader: "test",
            nucleotideSequence: longSeq,
            proteinSequence: nil,
            sourceName: "test",
            chromosome: "chr1",
            effectiveStart: 0,
            effectiveEnd: 150,
            isReverseComplement: false
        )

        let fasta = SequenceExtractor.formatFASTA(result, lineWidth: 70)
        let lines = fasta.split(separator: "\n")

        XCTAssertEqual(lines.count, 4) // header + 70 + 70 + 10
        XCTAssertEqual(lines[1].count, 70)
        XCTAssertEqual(lines[2].count, 70)
        XCTAssertEqual(lines[3].count, 10)
    }

    func testFormatProteinFASTA() throws {
        let result = ExtractionResult(
            fastaHeader: "TestCDS [chr1:0-12] [CDS] [12 bp]",
            nucleotideSequence: "ATGGCAGCATAA",
            proteinSequence: "MAA*",
            sourceName: "TestCDS",
            chromosome: "chr1",
            effectiveStart: 0,
            effectiveEnd: 12,
            isReverseComplement: false
        )

        let proteinFASTA = SequenceExtractor.formatProteinFASTA(result)
        XCTAssertNotNil(proteinFASTA)
        XCTAssertTrue(proteinFASTA!.contains("[protein]"))
        XCTAssertTrue(proteinFASTA!.contains("MAA*"))
    }

    func testFormatProteinFASTAReturnsNilForNonCDS() throws {
        let result = ExtractionResult(
            fastaHeader: "test",
            nucleotideSequence: "ACGT",
            proteinSequence: nil,
            sourceName: "test",
            chromosome: "chr1",
            effectiveStart: 0,
            effectiveEnd: 4,
            isReverseComplement: false
        )

        XCTAssertNil(SequenceExtractor.formatProteinFASTA(result))
    }

    // MARK: - Header Formatting

    func testHeaderIncludesAnnotationMetadata() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "XP_001114420.3",
            chromosome: "NC_041760.1",
            start: 100,
            end: 200,
            strand: .reverse
        )

        let request = ExtractionRequest(
            source: .annotation(annotation),
            reverseComplement: true
        )

        let provider: SequenceExtractor.SequenceProvider = { _, _, _ in
            String(repeating: "A", count: 100)
        }

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: provider,
            chromosomeLength: 1000
        )

        XCTAssertTrue(result.fastaHeader.contains("XP_001114420.3"))
        XCTAssertTrue(result.fastaHeader.contains("[NC_041760.1:100-200]"))
        XCTAssertTrue(result.fastaHeader.contains("[CDS]"))
        XCTAssertTrue(result.fastaHeader.contains("[strand: -]"))
        XCTAssertTrue(result.fastaHeader.contains("[reverse complement]"))
        XCTAssertTrue(result.fastaHeader.contains("[100 bp]"))
    }

    func testHeaderIncludesConcatenatedLabel() throws {
        let annotation = SequenceAnnotation(
            type: .mRNA,
            name: "TestmRNA",
            chromosome: "chr1",
            intervals: [
                AnnotationInterval(start: 10, end: 20),
                AnnotationInterval(start: 30, end: 40)
            ],
            strand: .forward
        )

        let request = ExtractionRequest(
            source: .annotation(annotation),
            concatenateExons: true
        )

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        XCTAssertTrue(result.fastaHeader.contains("[exons concatenated]"))
    }

    // MARK: - Edge Cases

    func testNegativeFlankingClampedToZero() throws {
        // ExtractionRequest constructor clamps negative to 0
        let request = ExtractionRequest(
            source: .region(chromosome: "chr1", start: 10, end: 20),
            flank5Prime: -10,
            flank3Prime: -5
        )

        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: makeProvider(),
            chromosomeLength: chromLength
        )

        // No flanking applied
        XCTAssertEqual(result.effectiveStart, 10)
        XCTAssertEqual(result.effectiveEnd, 20)
    }

    func testSequenceProviderReturnsNilThrows() {
        let nilProvider: SequenceExtractor.SequenceProvider = { _, _, _ in nil }

        let request = ExtractionRequest(
            source: .region(chromosome: "chr1", start: 0, end: 10)
        )

        XCTAssertThrowsError(try SequenceExtractor.extract(
            request: request,
            sequenceProvider: nilProvider,
            chromosomeLength: 100
        )) { error in
            XCTAssertTrue(error is ExtractionError)
        }
    }

    // MARK: - SCI-06: Strand- and splice-aware annotation extraction

    /// Single-exon minus-strand CDS: extraction with reverseComplement=true must
    /// return the reverse complement of the plus-strand span, and translating it
    /// must equal the CDS's own `proteinSequence` (previously the two disagreed:
    /// the nucleotide sequence was the plus-strand span, but the protein was
    /// already strand-correct from `translateCDS`).
    func testMinusStrandSingleExonCDSReverseComplementMatchesTranslation() throws {
        // Plus-strand genomic bases at [0,12): "TTATTTGCCAT"... use a clean 12bp ORF.
        // Forward genomic: "ATGGCATAACC" is irrelevant; construct so that RC gives an ORF.
        // Forward (plus strand) bases at [0,9): "TTATGCCAT"
        // RC: "ATGGCATAA" -> ATG GCA TAA -> M A *
        let forwardGenome = "TTATGCCAT"
        let provider: SequenceExtractor.SequenceProvider = { _, start, end in
            guard start >= 0, end <= forwardGenome.count else { return nil }
            let s = forwardGenome.index(forwardGenome.startIndex, offsetBy: start)
            let e = forwardGenome.index(forwardGenome.startIndex, offsetBy: end)
            return String(forwardGenome[s..<e])
        }

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "minus_cds",
            chromosome: "chr1",
            start: 0,
            end: 9,
            strand: .reverse
        )

        let request = ExtractionRequest(source: .annotation(annotation), reverseComplement: true)
        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: provider,
            chromosomeLength: 9
        )

        XCTAssertEqual(result.nucleotideSequence, "ATGGCATAA", "Should be the reverse complement of the plus-strand span")
        XCTAssertEqual(result.proteinSequence, "MA*")
        XCTAssertTrue(result.fastaHeader.contains("[feature orientation]"))
    }

    /// Two-exon minus-strand CDS: copied-as-FASTA output (RC on, exons
    /// concatenated) must equal the reverse complement of the joined exons in
    /// transcription order, and must equal the annotation's own translation.
    func testMinusStrandMultiExonCDSMatchesReverseComplementOfJoinedExons() throws {
        // Exon A (genomic [0,6)): "TTATGC" ; Exon B (genomic [100,103)): "CAT"
        // Ascending genomic (stored) order: [Exon A, Exon B]
        // Concatenated ascending: "TTATGC" + "CAT" = "TTATGCCAT"
        // RC of that whole string: "ATGGCATAA" -> ATG GCA TAA -> M A *
        let provider: SequenceExtractor.SequenceProvider = { _, start, _ in
            if start == 0 { return "TTATGC" }
            if start == 100 { return "CAT" }
            return nil
        }

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "minus_multi_cds",
            chromosome: "chr1",
            intervals: [
                AnnotationInterval(start: 0, end: 6),
                AnnotationInterval(start: 100, end: 103)
            ],
            strand: .reverse
        )

        let request = ExtractionRequest(
            source: .annotation(annotation),
            reverseComplement: true,
            concatenateExons: true
        )
        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: provider,
            chromosomeLength: 103
        )

        XCTAssertEqual(result.nucleotideSequence, "ATGGCATAA")
        XCTAssertEqual(result.proteinSequence, "MA*", "Nucleotide and protein must agree")
    }

    /// flank5=3 on a minus-strand feature must add bases from the genomic-higher
    /// coordinate side (`end..end+3`), and after reverse complementing they land
    /// at the 5' end of the output (SCI-06 acceptance test from the audit).
    func testMinusStrandFlank5AddsFromGenomicHighSide() throws {
        // Genomic layout: feature at [10,20). Downstream (3' on genomic axis,
        // 5' in feature orientation) flank at [20,23) = "TTT".
        // Feature span [10,20) plus-strand = 10 bases of "A".
        // RC(feature span) = 10 T's. RC(downstream flank "TTT") = "AAA", which
        // must appear at the 5' (leading) end of the RC'd output.
        // Extraction fetches the whole flanked genomic span in one call for a
        // contiguous (single-interval) annotation. Genome: [0,10) padding,
        // [10,20) = 10 A's (the feature), [20,23) = "TTT" (the flank).
        let genome = String(repeating: "N", count: 10) + String(repeating: "A", count: 10) + "TTT"
        let provider: SequenceExtractor.SequenceProvider = { _, start, end in
            guard start >= 0, end <= genome.count else { return nil }
            let s = genome.index(genome.startIndex, offsetBy: start)
            let e = genome.index(genome.startIndex, offsetBy: end)
            return String(genome[s..<e])
        }

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "minus_gene",
            chromosome: "chr1",
            start: 10,
            end: 20,
            strand: .reverse
        )

        let request = ExtractionRequest(
            source: .annotation(annotation),
            flank5Prime: 3,
            reverseComplement: true
        )
        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: provider,
            chromosomeLength: 30
        )

        // Effective genomic range extended on the high-coordinate (3') side by
        // the feature's 5' flank: [10, 23).
        XCTAssertEqual(result.effectiveStart, 10)
        XCTAssertEqual(result.effectiveEnd, 23)
        // RC("TTT") = "AAA" leads, then RC(10 A's) = 10 T's.
        XCTAssertEqual(result.nucleotideSequence, "AAA" + String(repeating: "T", count: 10))
    }

    /// Plus-strand equivalent of the flank test: flank5 must add bases from the
    /// genomic-lower coordinate side, unaffected by this change.
    func testPlusStrandFlank5AddsFromGenomicLowSide() throws {
        // Genome: [0,7) padding, [7,10) = "TTT" (the flank), [10,20) = 10 A's
        // (the feature). Extraction fetches the merged span [7,20) in one call.
        let genome = String(repeating: "N", count: 7) + "TTT" + String(repeating: "A", count: 10)
        let provider: SequenceExtractor.SequenceProvider = { _, start, end in
            guard start >= 0, end <= genome.count else { return nil }
            let s = genome.index(genome.startIndex, offsetBy: start)
            let e = genome.index(genome.startIndex, offsetBy: end)
            return String(genome[s..<e])
        }

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "plus_gene",
            chromosome: "chr1",
            start: 10,
            end: 20,
            strand: .forward
        )

        let request = ExtractionRequest(
            source: .annotation(annotation),
            flank5Prime: 3
        )
        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: provider,
            chromosomeLength: 30
        )

        XCTAssertEqual(result.effectiveStart, 7)
        XCTAssertEqual(result.effectiveEnd, 20)
        XCTAssertEqual(result.nucleotideSequence, "TTT" + String(repeating: "A", count: 10))
    }

    // MARK: - SCI-15: origin-spanning extraction preserves join order

    /// Concatenated extraction of an origin-spanning circular feature must
    /// use the annotation's own segment order, not a re-sort by ascending
    /// genomic start, matching `TranslationEngine.translateCDS`'s behavior
    /// for the identical fixture.
    func testExtractAnnotationOriginSpanningPreservesJoinOrder() throws {
        // Segment A: genomic [15,20) = "ATGGC". Segment B: genomic [0,5) = "ATAAT".
        // Stored in join order [A, B] (not ascending), as a circular
        // `join(16..20,1..5)` GenBank location would parse.
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "wrapCDS",
            chromosome: "chr1",
            intervals: [
                AnnotationInterval(start: 15, end: 20),
                AnnotationInterval(start: 0, end: 5)
            ],
            strand: .forward
        )
        XCTAssertTrue(annotation.isOriginSpanning)

        let sequence = "ATAATCCCCCCCCCCATGGC"
        let provider: SequenceExtractor.SequenceProvider = { _, start, end in
            guard start >= 0, end <= sequence.count else { return nil }
            let s = sequence.index(sequence.startIndex, offsetBy: start)
            let e = sequence.index(sequence.startIndex, offsetBy: end)
            return String(sequence[s..<e])
        }

        let request = ExtractionRequest(source: .annotation(annotation), concatenateExons: true)
        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: provider,
            chromosomeLength: sequence.count
        )

        XCTAssertEqual(result.nucleotideSequence, "ATGGC" + "ATAAT", "Join order (A then B), not genomic-ascending (B then A)")
    }
}
