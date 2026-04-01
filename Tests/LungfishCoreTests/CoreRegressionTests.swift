// CoreRegressionTests.swift - Regression tests for key LungfishCore types
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These tests lock in existing public API behavior so that refactoring
// does not silently change semantics. Each section corresponds to a
// source file in LungfishCore.

import XCTest
@testable import LungfishCore

// MARK: - CodonTable Tests

final class CodonTableRegressionTests: XCTestCase {

    // MARK: Standard Table Identity

    func testStandardTableProperties() {
        let table = CodonTable.standard
        XCTAssertEqual(table.id, 1)
        XCTAssertEqual(table.name, "Standard")
        XCTAssertEqual(table.shortName, "standard")
    }

    // MARK: Standard Codon Lookups

    func testStandardTranslationATG() {
        XCTAssertEqual(CodonTable.standard.translate("ATG"), "M")
    }

    func testStandardTranslationTTT() {
        XCTAssertEqual(CodonTable.standard.translate("TTT"), "F")
    }

    func testStandardTranslationTTA() {
        XCTAssertEqual(CodonTable.standard.translate("TTA"), "L")
    }

    func testStandardTranslationTGG() {
        XCTAssertEqual(CodonTable.standard.translate("TGG"), "W")
    }

    func testStandardTranslationAllAminoAcids() {
        // Spot-check one codon for each of the 20 standard amino acids + stop
        let expectations: [(String, Character)] = [
            ("GCT", "A"), ("TGT", "C"), ("GAT", "D"), ("GAA", "E"),
            ("TTT", "F"), ("GGT", "G"), ("CAT", "H"), ("ATT", "I"),
            ("AAA", "K"), ("TTA", "L"), ("ATG", "M"), ("AAT", "N"),
            ("CCT", "P"), ("CAA", "Q"), ("CGT", "R"), ("TCT", "S"),
            ("ACT", "T"), ("GTT", "V"), ("TGG", "W"), ("TAT", "Y"),
            ("TAA", "*"),
        ]
        for (codon, expected) in expectations {
            XCTAssertEqual(
                CodonTable.standard.translate(codon), expected,
                "Codon \(codon) should translate to \(expected)"
            )
        }
    }

    // MARK: Case Insensitivity and RNA Support

    func testTranslateLowercase() {
        XCTAssertEqual(CodonTable.standard.translate("atg"), "M")
    }

    func testTranslateMixedCase() {
        XCTAssertEqual(CodonTable.standard.translate("Atg"), "M")
    }

    func testTranslateRNACodon() {
        // U should be treated as T
        XCTAssertEqual(CodonTable.standard.translate("AUG"), "M")
    }

    func testTranslateRNAStopCodon() {
        XCTAssertEqual(CodonTable.standard.translate("UAA"), "*")
    }

    // MARK: Unknown Codons

    func testTranslateUnknownCodonReturnsX() {
        XCTAssertEqual(CodonTable.standard.translate("NNN"), "X")
    }

    func testTranslateEmptyStringReturnsX() {
        XCTAssertEqual(CodonTable.standard.translate(""), "X")
    }

    func testTranslateSingleBaseReturnsX() {
        XCTAssertEqual(CodonTable.standard.translate("A"), "X")
    }

    // MARK: Start Codons

    func testStandardStartCodonATG() {
        XCTAssertTrue(CodonTable.standard.isStartCodon("ATG"))
    }

    func testStandardStartCodonTTG() {
        XCTAssertTrue(CodonTable.standard.isStartCodon("TTG"))
    }

    func testStandardStartCodonCTG() {
        XCTAssertTrue(CodonTable.standard.isStartCodon("CTG"))
    }

    func testStandardNonStartCodon() {
        XCTAssertFalse(CodonTable.standard.isStartCodon("AAA"))
    }

    func testStartCodonCaseInsensitive() {
        XCTAssertTrue(CodonTable.standard.isStartCodon("atg"))
    }

    func testStartCodonRNAForm() {
        XCTAssertTrue(CodonTable.standard.isStartCodon("AUG"))
    }

    // MARK: Stop Codons

    func testStandardStopCodons() {
        XCTAssertTrue(CodonTable.standard.isStopCodon("TAA"))
        XCTAssertTrue(CodonTable.standard.isStopCodon("TAG"))
        XCTAssertTrue(CodonTable.standard.isStopCodon("TGA"))
    }

    func testStandardNonStopCodon() {
        XCTAssertFalse(CodonTable.standard.isStopCodon("ATG"))
    }

    func testStopCodonCaseInsensitive() {
        XCTAssertTrue(CodonTable.standard.isStopCodon("taa"))
    }

    // MARK: Alternative Genetic Codes

    func testVertebrateMitoTGAIsNotStop() {
        // In vertebrate mito, TGA = Trp (not stop)
        let table = CodonTable.vertebrateMitochondrial
        XCTAssertEqual(table.id, 2)
        XCTAssertFalse(table.isStopCodon("TGA"))
        XCTAssertEqual(table.translate("TGA"), "W")
    }

    func testVertebrateMitoAGAIsStop() {
        // In vertebrate mito, AGA = Stop (not Arg)
        XCTAssertTrue(CodonTable.vertebrateMitochondrial.isStopCodon("AGA"))
        XCTAssertTrue(CodonTable.vertebrateMitochondrial.isStopCodon("AGG"))
    }

    func testVertebrateMitoATAIsMet() {
        XCTAssertEqual(CodonTable.vertebrateMitochondrial.translate("ATA"), "M")
    }

    func testYeastMitoCTAIsThr() {
        // In yeast mito, CTA = Thr (not Leu)
        let table = CodonTable.yeastMitochondrial
        XCTAssertEqual(table.id, 3)
        XCTAssertEqual(table.translate("CTA"), "T")
        XCTAssertEqual(table.translate("CTC"), "T")
        XCTAssertEqual(table.translate("CTG"), "T")
        XCTAssertEqual(table.translate("CTT"), "T")
    }

    func testCiliateTAAIsNotStop() {
        // In ciliate code, TAA and TAG = Gln (not stop)
        let table = CodonTable.ciliate
        XCTAssertEqual(table.id, 6)
        XCTAssertFalse(table.isStopCodon("TAA"))
        XCTAssertFalse(table.isStopCodon("TAG"))
        XCTAssertEqual(table.translate("TAA"), "Q")
        XCTAssertEqual(table.translate("TAG"), "Q")
        // TGA is still stop in ciliate
        XCTAssertTrue(table.isStopCodon("TGA"))
    }

    func testInvertebrateMitoAGAIsSer() {
        let table = CodonTable.invertebrateMitochondrial
        XCTAssertEqual(table.id, 5)
        XCTAssertEqual(table.translate("AGA"), "S")
        XCTAssertEqual(table.translate("AGG"), "S")
    }

    func testMoldMitoTGAIsTrp() {
        let table = CodonTable.moldMitochondrial
        XCTAssertEqual(table.id, 4)
        XCTAssertEqual(table.translate("TGA"), "W")
    }

    func testBacterialTableSameTranslationsAsStandard() {
        let table = CodonTable.bacterial
        XCTAssertEqual(table.id, 11)
        // Same translations as standard
        XCTAssertEqual(table.translate("ATG"), "M")
        XCTAssertEqual(table.translate("TAA"), "*")
        // But different start codons: GTG and TTG are starts
        XCTAssertTrue(table.isStartCodon("GTG"))
        XCTAssertTrue(table.isStartCodon("TTG"))
    }

    // MARK: Table Lookup

    func testAllTablesCount() {
        XCTAssertEqual(CodonTable.allTables.count, 7)
    }

    func testTableByShortName() {
        let table = CodonTable.table(named: "standard")
        XCTAssertNotNil(table)
        XCTAssertEqual(table?.id, 1)
    }

    func testTableByFullName() {
        let table = CodonTable.table(named: "Standard")
        XCTAssertNotNil(table)
        XCTAssertEqual(table?.id, 1)
    }

    func testTableByID() {
        let table = CodonTable.table(id: 2)
        XCTAssertNotNil(table)
        XCTAssertEqual(table?.shortName, "vertebrate_mito")
    }

    func testTableByInvalidNameReturnsNil() {
        XCTAssertNil(CodonTable.table(named: "nonexistent"))
    }

    func testTableByInvalidIDReturnsNil() {
        XCTAssertNil(CodonTable.table(id: 999))
    }
}

// MARK: - TranslationResult Tests

final class TranslationResultRegressionTests: XCTestCase {

    func testTranslationResultConstruction() {
        let positions = [
            AminoAcidPosition(
                index: 0,
                aminoAcid: "M",
                codon: "ATG",
                genomicRanges: [GenomicRange(start: 100, end: 103)],
                isStart: true,
                isStop: false
            ),
            AminoAcidPosition(
                index: 1,
                aminoAcid: "*",
                codon: "TAA",
                genomicRanges: [GenomicRange(start: 103, end: 106)],
                isStart: false,
                isStop: true
            ),
        ]

        let result = TranslationResult(
            protein: "M*",
            codingSequence: "ATGTAA",
            aminoAcidPositions: positions,
            codonTable: .standard,
            phaseOffset: 0
        )

        XCTAssertEqual(result.protein, "M*")
        XCTAssertEqual(result.codingSequence, "ATGTAA")
        XCTAssertEqual(result.aminoAcidPositions.count, 2)
        XCTAssertEqual(result.phaseOffset, 0)
        XCTAssertEqual(result.codonTable.id, 1)
    }

    func testAminoAcidPositionProperties() {
        let position = AminoAcidPosition(
            index: 5,
            aminoAcid: "L",
            codon: "CTG",
            genomicRanges: [GenomicRange(start: 0, end: 3)],
            isStart: false,
            isStop: false
        )

        XCTAssertEqual(position.index, 5)
        XCTAssertEqual(position.aminoAcid, "L" as Character)
        XCTAssertEqual(position.codon, "CTG")
        XCTAssertFalse(position.isStart)
        XCTAssertFalse(position.isStop)
    }

    func testAminoAcidPositionSplitAcrossIntron() {
        // A codon can span an intron, producing two genomic ranges
        let position = AminoAcidPosition(
            index: 0,
            aminoAcid: "M",
            codon: "ATG",
            genomicRanges: [
                GenomicRange(start: 98, end: 100),
                GenomicRange(start: 500, end: 501),
            ],
            isStart: true,
            isStop: false
        )

        XCTAssertEqual(position.genomicRanges.count, 2)
        XCTAssertEqual(position.genomicRanges[0].length, 2)
        XCTAssertEqual(position.genomicRanges[1].length, 1)
    }

    func testGenomicRangeEquatable() {
        let a = GenomicRange(start: 10, end: 20)
        let b = GenomicRange(start: 10, end: 20)
        let c = GenomicRange(start: 10, end: 25)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testGenomicRangeLength() {
        let range = GenomicRange(start: 100, end: 200)
        XCTAssertEqual(range.length, 100)
    }

    func testGenomicRangeZeroLength() {
        let range = GenomicRange(start: 50, end: 50)
        XCTAssertEqual(range.length, 0)
    }
}

// MARK: - SequenceAlphabet Tests

final class SequenceAlphabetRegressionTests: XCTestCase {

    // MARK: Raw Values and Codable

    func testRawValues() {
        XCTAssertEqual(SequenceAlphabet.dna.rawValue, "dna")
        XCTAssertEqual(SequenceAlphabet.rna.rawValue, "rna")
        XCTAssertEqual(SequenceAlphabet.protein.rawValue, "protein")
    }

    func testCodableRoundTrip() throws {
        for alphabet in SequenceAlphabet.allCases {
            let data = try JSONEncoder().encode(alphabet)
            let decoded = try JSONDecoder().decode(SequenceAlphabet.self, from: data)
            XCTAssertEqual(decoded, alphabet)
        }
    }

    // MARK: Valid Characters

    func testDNAValidCharacters() {
        let valid = SequenceAlphabet.dna.validCharacters
        // Standard bases
        for c: Character in ["A", "T", "G", "C", "N"] {
            XCTAssertTrue(valid.contains(c), "DNA should contain \(c)")
        }
        // Lowercase
        for c: Character in ["a", "t", "g", "c", "n"] {
            XCTAssertTrue(valid.contains(c), "DNA should contain \(c)")
        }
        // IUPAC ambiguity codes
        for c: Character in ["R", "Y", "S", "W", "K", "M", "B", "D", "H", "V"] {
            XCTAssertTrue(valid.contains(c), "DNA should contain IUPAC code \(c)")
        }
        // U is NOT valid for DNA
        XCTAssertFalse(valid.contains("U"))
    }

    func testRNAValidCharacters() {
        let valid = SequenceAlphabet.rna.validCharacters
        for c: Character in ["A", "U", "G", "C", "N"] {
            XCTAssertTrue(valid.contains(c), "RNA should contain \(c)")
        }
        // T is NOT valid for RNA
        XCTAssertFalse(valid.contains("T"))
    }

    func testProteinValidCharacters() {
        let valid = SequenceAlphabet.protein.validCharacters
        // Standard amino acid one-letter codes
        for c: Character in ["A", "C", "D", "E", "F", "G", "H", "I", "K", "L",
                              "M", "N", "P", "Q", "R", "S", "T", "V", "W", "Y"] {
            XCTAssertTrue(valid.contains(c), "Protein should contain \(c)")
        }
        // Stop codon symbol and unknown
        XCTAssertTrue(valid.contains("*"))
        XCTAssertTrue(valid.contains("X"))
        // DNA-specific bases not in protein
        XCTAssertFalse(valid.contains("U"))
    }

    // MARK: Complement Map

    func testDNAComplementMap() {
        let map = SequenceAlphabet.dna.complementMap
        XCTAssertNotNil(map)
        XCTAssertEqual(map?["A"], "T")
        XCTAssertEqual(map?["T"], "A")
        XCTAssertEqual(map?["G"], "C")
        XCTAssertEqual(map?["C"], "G")
        XCTAssertEqual(map?["N"], "N")
        // Lowercase
        XCTAssertEqual(map?["a"], "t")
        XCTAssertEqual(map?["t"], "a")
        // IUPAC codes
        XCTAssertEqual(map?["R"], "Y")
        XCTAssertEqual(map?["Y"], "R")
        XCTAssertEqual(map?["S"], "S")  // S complements to S
        XCTAssertEqual(map?["W"], "W")  // W complements to W
    }

    func testRNAComplementMap() {
        let map = SequenceAlphabet.rna.complementMap
        XCTAssertNotNil(map)
        XCTAssertEqual(map?["A"], "U")
        XCTAssertEqual(map?["U"], "A")
        XCTAssertEqual(map?["G"], "C")
        XCTAssertEqual(map?["C"], "G")
    }

    func testProteinComplementMapIsNil() {
        XCTAssertNil(SequenceAlphabet.protein.complementMap)
    }

    // MARK: Capabilities

    func testSupportsComplement() {
        XCTAssertTrue(SequenceAlphabet.dna.supportsComplement)
        XCTAssertTrue(SequenceAlphabet.rna.supportsComplement)
        XCTAssertFalse(SequenceAlphabet.protein.supportsComplement)
    }

    func testCanTranslate() {
        XCTAssertTrue(SequenceAlphabet.dna.canTranslate)
        XCTAssertTrue(SequenceAlphabet.rna.canTranslate)
        XCTAssertFalse(SequenceAlphabet.protein.canTranslate)
    }

    func testAllCasesCount() {
        XCTAssertEqual(SequenceAlphabet.allCases.count, 3)
    }
}

// MARK: - Strand Tests

final class StrandRegressionTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(Strand.forward.rawValue, "+")
        XCTAssertEqual(Strand.reverse.rawValue, "-")
        XCTAssertEqual(Strand.unknown.rawValue, ".")
    }

    func testOpposite() {
        XCTAssertEqual(Strand.forward.opposite, .reverse)
        XCTAssertEqual(Strand.reverse.opposite, .forward)
        XCTAssertEqual(Strand.unknown.opposite, .unknown)
    }

    func testCodableRoundTrip() throws {
        for strand in [Strand.forward, .reverse, .unknown] {
            let data = try JSONEncoder().encode(strand)
            let decoded = try JSONDecoder().decode(Strand.self, from: data)
            XCTAssertEqual(decoded, strand)
        }
    }
}

// MARK: - ReadingFrame Tests

final class ReadingFrameRegressionTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(ReadingFrame.plus1.rawValue, "+1")
        XCTAssertEqual(ReadingFrame.plus2.rawValue, "+2")
        XCTAssertEqual(ReadingFrame.plus3.rawValue, "+3")
        XCTAssertEqual(ReadingFrame.minus1.rawValue, "-1")
        XCTAssertEqual(ReadingFrame.minus2.rawValue, "-2")
        XCTAssertEqual(ReadingFrame.minus3.rawValue, "-3")
    }

    func testOffsets() {
        XCTAssertEqual(ReadingFrame.plus1.offset, 0)
        XCTAssertEqual(ReadingFrame.plus2.offset, 1)
        XCTAssertEqual(ReadingFrame.plus3.offset, 2)
        XCTAssertEqual(ReadingFrame.minus1.offset, 0)
        XCTAssertEqual(ReadingFrame.minus2.offset, 1)
        XCTAssertEqual(ReadingFrame.minus3.offset, 2)
    }

    func testIsReverse() {
        XCTAssertFalse(ReadingFrame.plus1.isReverse)
        XCTAssertFalse(ReadingFrame.plus2.isReverse)
        XCTAssertFalse(ReadingFrame.plus3.isReverse)
        XCTAssertTrue(ReadingFrame.minus1.isReverse)
        XCTAssertTrue(ReadingFrame.minus2.isReverse)
        XCTAssertTrue(ReadingFrame.minus3.isReverse)
    }

    func testForwardFrames() {
        XCTAssertEqual(ReadingFrame.forwardFrames, [.plus1, .plus2, .plus3])
    }

    func testReverseFrames() {
        XCTAssertEqual(ReadingFrame.reverseFrames, [.minus1, .minus2, .minus3])
    }

    func testAllCasesCount() {
        XCTAssertEqual(ReadingFrame.allCases.count, 6)
    }
}

// MARK: - LungfishError Tests

/// Concrete error type for testing the LungfishError protocol.
private enum TestLungfishError: LungfishError {
    case sampleError
    case errorWithSuggestion

    var userTitle: String {
        switch self {
        case .sampleError: return "Sample Error"
        case .errorWithSuggestion: return "Error With Suggestion"
        }
    }

    var userMessage: String {
        switch self {
        case .sampleError: return "Something went wrong."
        case .errorWithSuggestion: return "A recoverable problem occurred."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .sampleError: return nil
        case .errorWithSuggestion: return "Try restarting the app."
        }
    }
}

final class LungfishErrorRegressionTests: XCTestCase {

    func testErrorDescriptionMapsToUserTitle() {
        let error: any LungfishError = TestLungfishError.sampleError
        XCTAssertEqual(error.errorDescription, "Sample Error")
    }

    func testFailureReasonMapsToUserMessage() {
        let error: any LungfishError = TestLungfishError.sampleError
        XCTAssertEqual(error.failureReason, "Something went wrong.")
    }

    func testLocalizedDescriptionUsesErrorDescription() {
        let error: Error = TestLungfishError.sampleError
        XCTAssertEqual(error.localizedDescription, "Sample Error")
    }

    func testFormattedDescriptionWithoutSuggestion() {
        let error = TestLungfishError.sampleError
        let formatted = error.formattedDescription
        XCTAssertEqual(formatted, "Error: Sample Error\nSomething went wrong.")
    }

    func testFormattedDescriptionWithSuggestion() {
        let error = TestLungfishError.errorWithSuggestion
        let formatted = error.formattedDescription
        XCTAssertEqual(
            formatted,
            "Error: Error With Suggestion\nA recoverable problem occurred.\nSuggestion: Try restarting the app."
        )
    }

    func testRecoverySuggestionNilByDefault() {
        let error = TestLungfishError.sampleError
        XCTAssertNil(error.recoverySuggestion)
    }
}

// MARK: - GenomicDocument Tests

final class GenomicDocumentRegressionTests: XCTestCase {

    @MainActor
    func testEmptyDocumentCreation() {
        let doc = GenomicDocument(name: "Test")
        XCTAssertEqual(doc.name, "Test")
        XCTAssertEqual(doc.documentCategory, .generic)
        XCTAssertNil(doc.filePath)
        XCTAssertEqual(doc.sequenceCount, 0)
        XCTAssertEqual(doc.totalLength, 0)
        XCTAssertEqual(doc.annotationCount, 0)
        XCTAssertFalse(doc.isModified)
    }

    @MainActor
    func testDocumentCreationWithCategory() {
        let doc = GenomicDocument(name: "Ref", documentCategory: .reference)
        XCTAssertEqual(doc.documentCategory, .reference)
    }

    @MainActor
    func testDocumentCreationWithFilePath() {
        let url = URL(fileURLWithPath: "/tmp/test.fasta")
        let doc = GenomicDocument(name: "Test", filePath: url)
        XCTAssertEqual(doc.filePath, url)
    }

    @MainActor
    func testAddSequenceSetsModified() throws {
        let doc = GenomicDocument(name: "Test")
        let seq = try Sequence(name: "chr1", alphabet: .dna, bases: "ATCG")
        doc.addSequence(seq)

        XCTAssertTrue(doc.isModified)
        XCTAssertEqual(doc.sequenceCount, 1)
        XCTAssertEqual(doc.totalLength, 4)
    }

    @MainActor
    func testAddAndRetrieveSequenceByID() throws {
        let doc = GenomicDocument(name: "Test")
        let seq = try Sequence(name: "chr1", alphabet: .dna, bases: "ATCG")
        doc.addSequence(seq)

        let found = doc.sequence(byID: seq.id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "chr1")
    }

    @MainActor
    func testRetrieveSequenceByName() throws {
        let doc = GenomicDocument(name: "Test")
        let seq = try Sequence(name: "chr1", alphabet: .dna, bases: "ATCG")
        doc.addSequence(seq)

        let found = doc.sequence(byName: "chr1")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, seq.id)
    }

    @MainActor
    func testRetrieveNonexistentSequenceReturnsNil() {
        let doc = GenomicDocument(name: "Test")
        XCTAssertNil(doc.sequence(byID: UUID()))
        XCTAssertNil(doc.sequence(byName: "nonexistent"))
    }

    @MainActor
    func testRemoveSequence() throws {
        let doc = GenomicDocument(name: "Test")
        let seq = try Sequence(name: "chr1", alphabet: .dna, bases: "ATCG")
        doc.addSequence(seq)
        doc.removeSequence(id: seq.id)

        XCTAssertEqual(doc.sequenceCount, 0)
        XCTAssertNil(doc.sequence(byID: seq.id))
    }

    @MainActor
    func testAddAnnotation() throws {
        let doc = GenomicDocument(name: "Test")
        let seq = try Sequence(name: "chr1", alphabet: .dna, bases: "ATCGATCGATCG")
        doc.addSequence(seq)

        let annotation = SequenceAnnotation(
            type: .gene, name: "geneA", start: 0, end: 6, strand: .forward
        )
        doc.addAnnotation(annotation, to: seq.id)

        XCTAssertEqual(doc.annotationCount, 1)
        let annotations = doc.annotations(for: seq.id)
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations.first?.name, "geneA")
    }

    @MainActor
    func testAnnotationsOverlappingRange() throws {
        let doc = GenomicDocument(name: "Test")
        let seq = try Sequence(name: "chr1", alphabet: .dna, bases: "ATCGATCGATCG")
        doc.addSequence(seq)

        let a1 = SequenceAnnotation(type: .gene, name: "a1", start: 0, end: 4)
        let a2 = SequenceAnnotation(type: .gene, name: "a2", start: 6, end: 10)
        doc.addAnnotation(a1, to: seq.id)
        doc.addAnnotation(a2, to: seq.id)

        // Query range 2..8 should overlap both
        let overlapping = doc.annotations(for: seq.id, overlapping: 2, end: 8)
        XCTAssertEqual(overlapping.count, 2)

        // Query range 5..6 should overlap neither (a1 ends at 4, a2 starts at 6)
        let none = doc.annotations(for: seq.id, overlapping: 4, end: 6)
        XCTAssertEqual(none.count, 0)
    }

    @MainActor
    func testAnnotationsByType() throws {
        let doc = GenomicDocument(name: "Test")
        let seq = try Sequence(name: "chr1", alphabet: .dna, bases: "ATCGATCGATCG")
        doc.addSequence(seq)

        let gene = SequenceAnnotation(type: .gene, name: "geneA", start: 0, end: 6)
        let cds = SequenceAnnotation(type: .cds, name: "cdsA", start: 0, end: 6)
        doc.addAnnotation(gene, to: seq.id)
        doc.addAnnotation(cds, to: seq.id)

        let genes = doc.annotations(for: seq.id, ofType: .gene)
        XCTAssertEqual(genes.count, 1)
        XCTAssertEqual(genes.first?.name, "geneA")
    }

    @MainActor
    func testRemoveAnnotation() throws {
        let doc = GenomicDocument(name: "Test")
        let seq = try Sequence(name: "chr1", alphabet: .dna, bases: "ATCG")
        doc.addSequence(seq)

        let annotation = SequenceAnnotation(type: .gene, name: "geneA", start: 0, end: 4)
        doc.addAnnotation(annotation, to: seq.id)
        doc.removeAnnotation(id: annotation.id, from: seq.id)

        XCTAssertEqual(doc.annotationCount, 0)
    }

    @MainActor
    func testAnnotationsForNonexistentSequenceReturnsEmpty() {
        let doc = GenomicDocument(name: "Test")
        XCTAssertTrue(doc.annotations(for: UUID()).isEmpty)
    }
}

// MARK: - DocumentCategory Tests

final class DocumentCategoryRegressionTests: XCTestCase {

    func testAllCases() {
        let cases: [DocumentCategory] = [
            .generic, .reference, .reads, .assembly,
            .alignment, .annotations, .primers, .variants,
        ]
        for category in cases {
            // Verify raw value round-trip
            XCTAssertEqual(DocumentCategory(rawValue: category.rawValue), category)
        }
    }

    func testCodableRoundTrip() throws {
        let category = DocumentCategory.reference
        let data = try JSONEncoder().encode(category)
        let decoded = try JSONDecoder().decode(DocumentCategory.self, from: data)
        XCTAssertEqual(decoded, .reference)
    }
}

// MARK: - DocumentMetadata Tests

final class DocumentMetadataRegressionTests: XCTestCase {

    func testDefaultInitialization() {
        let metadata = DocumentMetadata()
        XCTAssertNil(metadata.organism)
        XCTAssertNil(metadata.taxonomyID)
        XCTAssertNil(metadata.assemblyName)
        XCTAssertNil(metadata.accession)
        XCTAssertNil(metadata.source)
        XCTAssertEqual(metadata.custom, [:])
    }

    func testFullInitialization() {
        let metadata = DocumentMetadata(
            organism: "Homo sapiens",
            taxonomyID: 9606,
            assemblyName: "GRCh38",
            accession: "GCF_000001405.40",
            source: "NCBI",
            custom: ["key": "value"]
        )

        XCTAssertEqual(metadata.organism, "Homo sapiens")
        XCTAssertEqual(metadata.taxonomyID, 9606)
        XCTAssertEqual(metadata.assemblyName, "GRCh38")
        XCTAssertEqual(metadata.accession, "GCF_000001405.40")
        XCTAssertEqual(metadata.source, "NCBI")
        XCTAssertEqual(metadata.custom["key"], "value")
    }

    func testCodableRoundTrip() throws {
        let original = DocumentMetadata(
            organism: "SARS-CoV-2",
            taxonomyID: 2697049,
            assemblyName: "ASM985889v3",
            source: "NCBI"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DocumentMetadata.self, from: data)

        XCTAssertEqual(decoded.organism, "SARS-CoV-2")
        XCTAssertEqual(decoded.taxonomyID, 2697049)
        XCTAssertEqual(decoded.assemblyName, "ASM985889v3")
        XCTAssertEqual(decoded.source, "NCBI")
    }
}

// MARK: - TempFileManager Tests

final class TempFileManagerRegressionTests: XCTestCase {

    func testCreateTempDirectory() async throws {
        let manager = TempFileManager.shared

        let tempDir = try await manager.createTempDirectory(prefix: "lungfish-test-")

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
        XCTAssertTrue(tempDir.lastPathComponent.hasPrefix("lungfish-test-"))

        // Cleanup
        await manager.cleanupTempDirectory(tempDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testCleanupSessionFiles() async throws {
        let manager = TempFileManager.shared

        let dir1 = try await manager.createTempDirectory(prefix: "lungfish-test-")
        let dir2 = try await manager.createTempDirectory(prefix: "lungfish-test-")

        // Write a small file into one directory to verify size tracking
        let testFile = dir1.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir2.path))

        let bytesReclaimed = await manager.cleanupSessionFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir2.path))
        XCTAssertGreaterThan(bytesReclaimed, 0)
    }

    func testSetMaxAge() async {
        let manager = TempFileManager.shared
        await manager.setMaxAge(hours: 48)
        // 48 hours = 172800 seconds
        let age = await manager.maxTempFileAge
        XCTAssertEqual(age, 172_800)

        // Reset to default
        await manager.setMaxAge(hours: 24)
    }

    func testRegisterAndUnregister() async throws {
        let manager = TempFileManager.shared

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        await manager.registerSessionTempDirectory(tempDir)
        await manager.unregisterSessionTempDirectory(tempDir)

        // After unregistering, cleanupSessionFiles should NOT remove it
        // (it was unregistered before cleanup)
        _ = await manager.cleanupSessionFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))

        // Manual cleanup
        try FileManager.default.removeItem(at: tempDir)
    }
}

// MARK: - Version Tests

final class VersionRegressionTests: XCTestCase {

    func testVersionCreation() {
        let diff = SequenceDiff.empty
        let version = Version(
            content: "ATCG",
            diff: diff,
            parentHash: nil,
            message: "Initial commit",
            author: "tester"
        )

        XCTAssertNotNil(version.id)
        XCTAssertNotNil(version.contentHash)
        XCTAssertNil(version.parentHash)
        XCTAssertEqual(version.message, "Initial commit")
        XCTAssertEqual(version.author, "tester")
        XCTAssertEqual(version.diff, .empty)
        XCTAssertTrue(version.metadata.isEmpty)
    }

    func testVersionContentHash() {
        let v1 = Version(content: "ATCG", diff: .empty, parentHash: nil)
        let v2 = Version(content: "ATCG", diff: .empty, parentHash: nil)
        let v3 = Version(content: "GCTA", diff: .empty, parentHash: nil)

        // Same content should produce same hash
        XCTAssertEqual(v1.contentHash, v2.contentHash)
        // Different content should produce different hash
        XCTAssertNotEqual(v1.contentHash, v3.contentHash)
    }

    func testComputeHashDeterministic() {
        let hash1 = Version.computeHash("ATCGATCG")
        let hash2 = Version.computeHash("ATCGATCG")
        XCTAssertEqual(hash1, hash2)
        // SHA-256 produces a 64-character hex string
        XCTAssertEqual(hash1.count, 64)
    }

    func testComputeHashHexFormat() {
        let hash = Version.computeHash("test")
        // Should only contain hex characters
        let validChars = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(
            hash.unicodeScalars.allSatisfy { validChars.contains($0) },
            "Hash should contain only lowercase hex characters"
        )
    }

    func testShortHash() {
        let version = Version(content: "ATCG", diff: .empty, parentHash: nil)
        let shortHash = version.shortHash
        XCTAssertEqual(shortHash.count, 8)
        XCTAssertEqual(shortHash, String(version.contentHash.prefix(8)))
    }

    func testVersionComparable() {
        let v1 = Version(content: "ATCG", diff: .empty, parentHash: nil, message: "first")
        // Small delay to ensure different timestamps
        Thread.sleep(forTimeInterval: 0.01)
        let v2 = Version(content: "GCTA", diff: .empty, parentHash: v1.contentHash, message: "second")

        XCTAssertTrue(v1 < v2, "Earlier version should be less than later version")
    }

    func testVersionEquality() {
        // Equality is based on contentHash, not id
        let v1 = Version(content: "ATCG", diff: .empty, parentHash: nil)
        let v2 = Version(content: "ATCG", diff: .empty, parentHash: nil)
        let v3 = Version(content: "GCTA", diff: .empty, parentHash: nil)

        XCTAssertEqual(v1, v2, "Versions with same content hash should be equal")
        XCTAssertNotEqual(v1, v3, "Versions with different content should not be equal")
    }

    func testVersionHashable() {
        let v1 = Version(content: "ATCG", diff: .empty, parentHash: nil)
        let v2 = Version(content: "ATCG", diff: .empty, parentHash: nil)

        var set = Set<Version>()
        set.insert(v1)
        set.insert(v2)
        // Same content hash means they should collapse to 1 entry
        XCTAssertEqual(set.count, 1)
    }

    func testVersionSummary() {
        let version = Version(
            content: "ATCG",
            diff: .empty,
            parentHash: nil,
            message: "Initial commit"
        )
        let summary = version.summary
        XCTAssertTrue(summary.hasPrefix(version.shortHash))
        XCTAssertTrue(summary.contains("Initial commit"))
    }

    func testVersionSummaryTruncation() {
        let longMessage = String(repeating: "A", count: 60)
        let version = Version(
            content: "ATCG",
            diff: .empty,
            parentHash: nil,
            message: longMessage
        )
        let summary = version.summary
        // Message should be truncated to 50 chars + "..."
        XCTAssertTrue(summary.contains("..."))
        XCTAssertTrue(summary.count < version.shortHash.count + 1 + 60)
    }

    func testVersionSummaryNoMessage() {
        let version = Version(content: "ATCG", diff: .empty, parentHash: nil)
        XCTAssertTrue(version.summary.contains("No message"))
    }

    func testVersionWithParentHash() {
        let parent = Version(content: "ATCG", diff: .empty, parentHash: nil)
        let child = Version(
            content: "ATCGG",
            diff: .empty,
            parentHash: parent.contentHash
        )

        XCTAssertEqual(child.parentHash, parent.contentHash)
    }

    func testVersionCodable() throws {
        let original = Version(
            content: "ATCG",
            diff: .empty,
            parentHash: nil,
            message: "Test",
            author: "tester",
            metadata: ["key": "value"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Version.self, from: data)

        XCTAssertEqual(decoded.contentHash, original.contentHash)
        XCTAssertEqual(decoded.message, "Test")
        XCTAssertEqual(decoded.author, "tester")
        XCTAssertEqual(decoded.metadata["key"], "value")
        XCTAssertNil(decoded.parentHash)
    }

    func testVersionSummaryStruct() {
        let version = Version(
            content: "ATCG",
            diff: .empty,
            parentHash: nil,
            message: "Test message",
            author: "tester"
        )

        let summary = VersionSummary(from: version)
        XCTAssertEqual(summary.id, version.id)
        XCTAssertEqual(summary.shortHash, version.shortHash)
        XCTAssertEqual(summary.message, "Test message")
        XCTAssertEqual(summary.author, "tester")
        XCTAssertEqual(summary.timestamp, version.timestamp)
    }
}
