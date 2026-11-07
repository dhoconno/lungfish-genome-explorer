// FASTAReaderCompositionTests.swift - A peptide of nucleotide letters is read as protein (Phase 3.3 lane FASTAGC)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO

/// FASTA-PEPTIDE-NUCLEOTIDE-LETTERS and PROTEIN-ALPHABET-REJECTS-LETTERS (S3, BIO).
///
/// The reader typed a record protein only when it held one of E, F, I, L, P, Q or Z, so a short peptide whose every letter is
/// an IUPAC nucleotide code (`MKTAYGHSSRV`) was typed DNA and the FASTA list showed a GC percent for it. The reader now also
/// types a record protein when fewer than half of its letters are A, C, G, T, U or N. That types more records protein, and the
/// protein alphabet refused B, Z, J, U, O and lower-case x, so a record with one of them would have thrown where it opened.
final class FASTAReaderCompositionTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTAReaderComposition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    /// Writes the records to one FASTA file and reads it back through the reader the app opens a file with.
    private func read(_ records: [(name: String, bases: String)]) throws -> [LungfishCore.Sequence] {
        let text = records.map { ">\($0.name)\n\($0.bases)\n" }.joined()
        let url = tempDirectory.appendingPathComponent("records.fasta")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try FASTAReader(url: url).readAllSync()
    }

    // MARK: - FASTA-PEPTIDE-NUCLEOTIDE-LETTERS

    /// Three peptides that hold none of E, F, I, L, P, Q or Z and only IUPAC letters, with 27%, 36% and 18% of their letters
    /// in A, C, G, T, U or N. `MKTAYGHSSRV` is BIO's own example, which the list showed as a GC of 33.3%.
    func testPeptideOfNucleotideLettersIsReadAsProtein() throws {
        let peptides = ["MKTAYGHSSRV", "AGTHSRKDVMC", "NDGHKSRVWYM"]
        let sequences = try read(peptides.enumerated().map { (name: "peptide\($0.offset + 1)", bases: $0.element) })

        XCTAssertEqual(sequences.count, peptides.count)
        for (sequence, peptide) in zip(sequences, peptides) {
            XCTAssertEqual(sequence.alphabet, .protein, "\(peptide) is a peptide, so it is not typed DNA")
            XCTAssertEqual(sequence.asString(), peptide)
        }
    }

    /// The other side of the line. A DNA record heavy in N and in every other IUPAC code, the two 16S primers BIO named, a
    /// record of only N and an RNA record with U keep their nucleotide type.
    func testDnaAndRnaWithAmbiguityCodesStayNucleotide() throws {
        let sequences = try read([
            (name: "heavyInN", bases: "NNNNNNNNNNACGTRYSWKMBDHVNNNNNNNNNN"),
            (name: "onlyN", bases: "NNNNNNNNNN"),
            (name: "primer515F", bases: "GTGYCAGCMGCCGCGGTAA"),
            (name: "primer806R", bases: "GGACTACNVGGGTWTCTAAT"),
            (name: "rnaWithU", bases: "AUGGCUACGUUAGCNNRYAUGC")
        ])

        XCTAssertEqual(sequences.map(\.alphabet), [.dna, .dna, .dna, .dna, .rna])
        XCTAssertEqual(sequences[0].asString(), "NNNNNNNNNNACGTRYSWKMBDHVNNNNNNNNNN")
        XCTAssertEqual(sequences[4].asString(), "ATGGCTACGTTAGCNNRYATGC", "RNA is stored and emitted with T")
    }

    /// The line is fewer than half. Exactly half stays nucleotide, and a letter counts the same in either case.
    func testCompositionLineIsFewerThanHalfNucleotideLetters() throws {
        let records = [
            (name: "half", bases: "ACGTKMRY", expected: SequenceAlphabet.dna),
            (name: "fewerThanHalf", bases: "ACGKMRYS", expected: .protein),
            (name: "halfLowerCase", bases: "acgtkmry", expected: .dna),
            (name: "fewerThanHalfLowerCase", bases: "acgkmrys", expected: .protein),
            (name: "allN", bases: "NNNNNNNN", expected: .dna),
            (name: "letterOfProteinOnly", bases: "ACGTEACGT", expected: .protein)
        ]
        let sequences = try read(records.map { (name: $0.name, bases: $0.bases) })

        XCTAssertEqual(sequences.map(\.alphabet), records.map(\.expected))
    }

    /// A gap, a dot and a stop symbol are not letters, so they never count against a nucleotide record. An aligned nucleotide
    /// record keeps its nucleotide type, which a later fix of the reader refusing `-` in a nucleotide record needs. The
    /// function is called directly, since the reader still refuses a `-` in a nucleotide record (FASTA-NUCLEOTIDE-GAP-REJECTED).
    func testAlignedNucleotideRecordWithGapsStaysNucleotide() {
        XCTAssertEqual(FASTAReader.detectAlphabet(of: "AC--GT....AC**GT--------"), .dna)
        XCTAssertEqual(FASTAReader.detectAlphabet(of: "A--------------------T"), .dna)
        XCTAssertEqual(FASTAReader.detectAlphabet(of: "AC--GU....AC**GU--------"), .rna)
        XCTAssertEqual(FASTAReader.detectAlphabet(of: "MK--TAYGHSSRV...."), .protein)
        XCTAssertEqual(FASTAReader.detectAlphabet(of: "-----"), .dna, "no letters to count, so the old default holds")
        XCTAssertEqual(FASTAReader.detectAlphabet(of: ""), .dna)
    }

    // MARK: - PROTEIN-ALPHABET-REJECTS-LETTERS

    /// Selenocysteine (U) as UniProt writes it, one record with B (Asx) and Z (Glx), one with B and no letter that only protein
    /// uses (typed DNA before the composition rule, so it opened), and one with J, O and a lower-case x.
    func testSelenoproteinAndAmbiguousResidueRecordsOpenAsProtein() throws {
        let records = [
            (name: "selenoprotein", bases: "MKTAYIAKQRUISFVKSHFSRQ"),
            (name: "asxGlx", bases: "MKBTAYZGHSRVBZ"),
            (name: "asxOnly", bases: "GHSKRDVBMWY"),
            (name: "xleAndPyl", bases: "MKTAYJOGHSRVxMK")
        ]
        let sequences = try read(records)

        XCTAssertEqual(sequences.count, records.count, "one record with an uncommon residue letter must not stop the file")
        for (sequence, record) in zip(sequences, records) {
            XCTAssertEqual(sequence.alphabet, .protein, "\(record.name) is a protein record")
            XCTAssertEqual(sequence.asString(), record.bases)
        }
    }

    /// The protein alphabet takes every IUPAC protein letter in either case and the stop symbol, and still refuses a digit, a
    /// gap and a space, which no protein letter is.
    func testProteinAlphabetTakesEveryIupacProteinLetter() throws {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz*"
        let sequence = try LungfishCore.Sequence(name: "all", alphabet: .protein, bases: letters)
        XCTAssertEqual(sequence.asString(), letters)

        for refused in ["1", "-", " ", "."] {
            XCTAssertThrowsError(try LungfishCore.Sequence(name: "bad", alphabet: .protein, bases: "MK" + refused + "TA")) { error in
                guard case SequenceError.invalidCharacter(let character, let position) = error else {
                    return XCTFail("Expected an invalidCharacter error, got \(error)")
                }
                XCTAssertEqual(String(character), refused)
                XCTAssertEqual(position, 2)
            }
        }
    }
}
