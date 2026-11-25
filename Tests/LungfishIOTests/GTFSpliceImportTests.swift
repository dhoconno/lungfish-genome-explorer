// GTFSpliceImportTests.swift - A GTF transcript imports with its exons as blocks and its CDS in one row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// BIO-GTF-SPLICE-17. A GTF line has no ID or Parent, so import gave a transcript row no blocks and left each CDS line
// as one exon's segment. "Concatenate exons" returned the unspliced span (210 bp where the transcript is 120 bp) and
// Copy translation a fragment (16 amino acids of 29). A GTF line carries `transcript_id`, which joins the exons and
// CDS lines of a transcript to its row. The GFF3 twin joins them through ID and Parent and is the control.

import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishIO

final class GTFSpliceImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "gtf-splice")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The coding sequence

    /// Twenty-nine codons, 87 bases, that translate to MWANLVTPKYLMRSPRAGARKMYGYFPHR.
    private static let codons29 = "ATG TGG GCT AAT CTG GTT ACT CCT AAA TAT CTT ATG CGT TCT CCT CGT GCT GGT GCT CGT AAA ATG TAT GGT TAT TTT CCT CAT CGT"
        .split(separator: " ").joined()
    private static let protein29 = "MWANLVTPKYLMRSPRAGARKMYGYFPHR"
    /// The same CDS with three more codons, 96 bases, MWANLVTPKYLMRSPRAGARKMYGYFPHRGSD.
    private static let codons32 = codons29 + "GGTTCTGAT"
    private static let protein32 = protein29 + "GSD"

    private static func reverseComplement(_ sequence: String) -> String {
        let pairs: [Character: Character] = ["A": "T", "T": "A", "C": "G", "G": "C"]
        return String(sequence.reversed().map { pairs[$0] ?? $0 })
    }

    private static func piece(_ sequence: String, _ range: Range<Int>) -> String {
        String(Array(sequence)[range])
    }

    // MARK: - Plus strand: 300 bp, transcript 51-260, exons 51-110 and 201-260, CDS 61-110 and 201-237

    private static let plusExon1 = "CTTAGGCTTA" + piece(codons29, 0..<50)
    private static let plusExon2 = piece(codons29, 50..<87) + "TAA" + "GGATCCGGATCCGGATCCGG"
    private static let plusGenome = String(repeating: "ACGTTGCAAG", count: 5)
        + plusExon1
        + "GT" + String(repeating: "CA", count: 43) + "AG"
        + plusExon2
        + String(repeating: "TTGACCAG", count: 5)

    private static func gtfLine(
        _ type: String, _ start: Int, _ end: Int, strand: String, phase: String = ".", transcript: String?
    ) -> String {
        var attributes = "gene_id \"G1\"; "
        if let transcript { attributes += "transcript_id \"\(transcript)\"; " }
        attributes += "gene_name \"GENE1\";"
        return "chr1\ttest\t\(type)\t\(start)\t\(end)\t.\t\(strand)\t\(phase)\t\(attributes)"
    }

    private static let plusGTF = [
        gtfLine("gene", 51, 260, strand: "+", transcript: nil),
        gtfLine("transcript", 51, 260, strand: "+", transcript: "T1"),
        gtfLine("exon", 51, 110, strand: "+", transcript: "T1"),
        gtfLine("CDS", 61, 110, strand: "+", phase: "0", transcript: "T1"),
        gtfLine("start_codon", 61, 63, strand: "+", phase: "0", transcript: "T1"),
        gtfLine("exon", 201, 260, strand: "+", transcript: "T1"),
        gtfLine("CDS", 201, 237, strand: "+", phase: "1", transcript: "T1"),
        gtfLine("stop_codon", 238, 240, strand: "+", phase: "0", transcript: "T1"),
    ]

    /// The control: the same transcript as GFF3, with the stop codon inside the CDS.
    private static let plusGFF3 = [
        "chr1\ttest\tgene\t51\t260\t.\t+\t.\tID=gene-G1;Name=GENE1",
        "chr1\ttest\tmRNA\t51\t260\t.\t+\t.\tID=rna-T1;Parent=gene-G1;Name=T1;gene=GENE1",
        "chr1\ttest\texon\t51\t110\t.\t+\t.\tID=exon-T1-1;Parent=rna-T1;gene=GENE1",
        "chr1\ttest\texon\t201\t260\t.\t+\t.\tID=exon-T1-2;Parent=rna-T1;gene=GENE1",
        "chr1\ttest\tCDS\t61\t110\t.\t+\t0\tID=cds-T1;Parent=rna-T1;gene=GENE1",
        "chr1\ttest\tCDS\t201\t240\t.\t+\t1\tID=cds-T1;Parent=rna-T1;gene=GENE1",
    ]

    // MARK: - Minus strand: 300 bp, transcript 41-260, exons 201-260, 121-160 and 41-90, CDS over all three

    private static let minusUTR5 = "CTTAGGCTTA"
    private static let minusUTR3 = String(String(repeating: "GATTACA", count: 6).prefix(41))
    /// The transcript as it reads 5' to 3': the 5' UTR, the 96 coding bases, the stop codon and the 3' UTR.
    private static let minusTranscript = minusUTR5 + codons32 + "TAA" + minusUTR3

    /// Each piece of the transcript is written reverse-complemented where the minus strand puts it.
    private static let minusGenome = String(repeating: "ACGTTGCAAG", count: 4)                // 1-40
        + reverseComplement(minusUTR3)                                                       // 41-81
        + reverseComplement("TAA")                                                           // 82-84
        + reverseComplement(piece(codons32, 90..<96))                                        // 85-90
        + String(repeating: "CT", count: 15)                                                 // 91-120
        + reverseComplement(piece(codons32, 50..<90))                                        // 121-160
        + String(repeating: "TC", count: 20)                                                 // 161-200
        + reverseComplement(piece(codons32, 0..<50))                                         // 201-250
        + reverseComplement(minusUTR5)                                                       // 251-260
        + String(repeating: "TTGACCAG", count: 5)                                            // 261-300

    /// Listed 5' to 3' of the transcript, as Ensembl writes a minus-strand transcript. CDS phases: 0, then 1 (50
    /// bases before it), then 0 (90 bases before it).
    private static let minusGTF = [
        gtfLine("gene", 41, 260, strand: "-", transcript: nil),
        gtfLine("transcript", 41, 260, strand: "-", transcript: "T2"),
        gtfLine("exon", 201, 260, strand: "-", transcript: "T2"),
        gtfLine("CDS", 201, 250, strand: "-", phase: "0", transcript: "T2"),
        gtfLine("exon", 121, 160, strand: "-", transcript: "T2"),
        gtfLine("CDS", 121, 160, strand: "-", phase: "1", transcript: "T2"),
        gtfLine("exon", 41, 90, strand: "-", transcript: "T2"),
        gtfLine("CDS", 85, 90, strand: "-", phase: "0", transcript: "T2"),
        gtfLine("stop_codon", 82, 84, strand: "-", phase: "0", transcript: "T2"),
    ]

    // MARK: - Helpers

    private func importRows(_ lines: [String], file: String) async throws -> [AnnotationDatabaseRecord] {
        let sourceURL = root.appendingPathComponent(file)
        try (lines.joined(separator: "\n") + "\n").write(to: sourceURL, atomically: true, encoding: .utf8)
        let databaseURL = root.appendingPathComponent("\(file).db")
        _ = try await AnnotationDatabase.createFromGFF3(gffURL: sourceURL, outputURL: databaseURL)
        return try AnnotationDatabase(url: databaseURL).queryByRegion(
            chromosome: "chr1", start: 0, end: 300, limit: 1000)
    }

    /// What Extract Sequence and Copy translation give for a row: the app's default request on the row's annotation.
    private func extract(_ row: AnnotationDatabaseRecord, genome: String) throws -> LungfishCore.ExtractionResult {
        let bases = Array(genome)
        return try SequenceExtractor.extract(
            request: ExtractionRequest.defaultAnnotationRequest(for: row.toAnnotation()),
            sequenceProvider: { _, start, end in
                guard start >= 0, start < end, end <= bases.count else { return nil }
                return String(bases[start..<end])
            },
            chromosomeLength: bases.count
        )
    }

    // MARK: - Tests

    /// The plus-strand GTF of BIO-GTF-SPLICE-17 item 6. The transcript row holds its two exons as blocks and extracts
    /// 120 bp, exon 1 then exon 2. The CDS is one row of two blocks and translates whole. H17 gives no blocks, 210 bp
    /// and 16 amino acids.
    func testAPlusStrandGTFTranscriptIsSplicedAndItsCDSTranslatesWhole() async throws {
        XCTAssertEqual(Self.plusGenome.count, 300, "the fixture is the 300 bp chromosome of the ruling")
        let rows = try await importRows(Self.plusGTF, file: "plus.gtf")

        let transcript = try XCTUnwrap(rows.first { $0.type == "transcript" })
        XCTAssertEqual(transcript.blockCount, 2)
        XCTAssertEqual(transcript.blockSizes, "60,60")
        XCTAssertEqual(transcript.blockStarts, "0,150")
        let spliced = try extract(transcript, genome: Self.plusGenome)
        XCTAssertEqual(spliced.nucleotideSequence.count, 120, "the spliced transcript, not the 210 bp span")
        XCTAssertEqual(spliced.nucleotideSequence, Self.plusExon1 + Self.plusExon2, "exon 1 then exon 2")

        let cdsRows = rows.filter { $0.type == "CDS" }
        XCTAssertEqual(cdsRows.count, 1, "the two CDS lines of one transcript are one CDS row")
        let cds = try XCTUnwrap(cdsRows.first)
        XCTAssertEqual(cds.blockCount, 2)
        XCTAssertEqual(cds.blockSizes, "50,37")
        XCTAssertEqual(cds.blockStarts, "0,140")
        XCTAssertEqual(try extract(cds, genome: Self.plusGenome).proteinSequence, Self.protein29)

        XCTAssertEqual(rows.count, 7, "gene, transcript, two exons, one CDS, start and stop codon")
    }

    /// BIO-GTF-SPLICE-17 item 8: a minus-strand transcript of three exons, with its CDS over all three. The blocks
    /// are in genomic order, the extraction reads the transcript 5' to 3', and the protein starts from the phase of the
    /// 5'-most CDS line (the one at the highest coordinates).
    func testAMinusStrandGTFTranscriptWithACDSOverThreeExonsIsSplicedAndTranslatesWhole() async throws {
        XCTAssertEqual(Self.minusGenome.count, 300)
        let rows = try await importRows(Self.minusGTF, file: "minus.gtf")

        let transcript = try XCTUnwrap(rows.first { $0.type == "transcript" })
        XCTAssertEqual(transcript.blockCount, 3)
        XCTAssertEqual(transcript.blockSizes, "50,40,60")
        XCTAssertEqual(transcript.blockStarts, "0,80,160")
        let spliced = try extract(transcript, genome: Self.minusGenome)
        XCTAssertEqual(spliced.nucleotideSequence.count, 150)
        XCTAssertEqual(spliced.nucleotideSequence, Self.minusTranscript, "the transcript 5' to 3'")

        let cdsRows = rows.filter { $0.type == "CDS" }
        XCTAssertEqual(cdsRows.count, 1, "the three CDS lines of one transcript are one CDS row")
        let cds = try XCTUnwrap(cdsRows.first)
        XCTAssertEqual(cds.blockCount, 3)
        XCTAssertEqual(cds.blockSizes, "6,40,50")
        XCTAssertEqual(cds.blockStarts, "0,36,116")
        XCTAssertEqual(try extract(cds, genome: Self.minusGenome).proteinSequence, Self.protein32)
    }

    /// The GFF3 twin joins its exons and CDS through ID and Parent and was right at H17. It stays right.
    func testTheGFF3TwinIsSplicedAndItsCDSTranslatesWhole() async throws {
        let rows = try await importRows(Self.plusGFF3, file: "plus.gff3")

        let mRNA = try XCTUnwrap(rows.first { $0.type == "mRNA" })
        XCTAssertEqual(mRNA.blockCount, 2)
        XCTAssertEqual(mRNA.blockSizes, "60,60")
        XCTAssertEqual(mRNA.blockStarts, "0,150")
        XCTAssertEqual(try extract(mRNA, genome: Self.plusGenome).nucleotideSequence, Self.plusExon1 + Self.plusExon2)

        let cds = try XCTUnwrap(rows.first { $0.type == "CDS" })
        XCTAssertEqual(cds.blockCount, 2)
        XCTAssertEqual(cds.blockSizes, "50,40")
        XCTAssertEqual(try extract(cds, genome: Self.plusGenome).proteinSequence, Self.protein29 + "*")
    }
}
