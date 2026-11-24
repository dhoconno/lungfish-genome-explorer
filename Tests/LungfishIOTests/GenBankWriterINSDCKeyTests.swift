// GenBankWriterINSDCKeyTests.swift - GenBankWriter prints the INSDC key of an annotation's type
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Row KL-177 GENBANK-KEY-CASE (S2). A feature that GenBankReader did not read, such as one from a GFF3 file, a BED
// file or a captured selection, printed the type's raw value in lower case (`cds`, `mrna`). INSDC spells the keys
// `CDS`, `mRNA`, `tRNA`, `rRNA` and `ncRNA`, and the key must read back as the type.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class GenBankWriterINSDCKeyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("genbank-insdc-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A GFF3 mRNA with its CDS, exported to GenBank, prints `mRNA` and `CDS`.
    func testAGFF3CDSAndMRNAExportAsCDSAndMRNA() async throws {
        let gff3 = folder.appendingPathComponent("genes.gff3")
        let text = "##gff-version 3\n"
            + "chr1\tsrc\tmRNA\t1\t90\t.\t+\t.\tID=m1;Name=m1\n"
            + "chr1\tsrc\tCDS\t10\t80\t.\t+\t0\tID=c1;Parent=m1\n"
        try text.write(to: gff3, atomically: true, encoding: .utf8)
        let annotations = try await GFF3Reader().readAsAnnotations(from: gff3)
        XCTAssertEqual(annotations.map(\.type).sorted { $0.rawValue < $1.rawValue }, [.cds, .mRNA])
        XCTAssertEqual(try exportedKeys(annotations).sorted(), ["CDS", "mRNA"])
    }

    /// The types that INSDC names print INSDC's spelling.
    func testEachTypeThatINSDCNamesPrintsINSDCsSpelling() {
        let expected: [(AnnotationType, String)] = [
            (.cds, "CDS"), (.mRNA, "mRNA"), (.gene, "gene"), (.exon, "exon"), (.intron, "intron"),
            (.rRNA, "rRNA"), (.tRNA, "tRNA"), (.ncRNA, "ncRNA"), (.misc_feature, "misc_feature"),
            (.utr5, "5'UTR"), (.utr3, "3'UTR"), (.repeatRegion, "repeat_region"), (.stem_loop, "stem_loop"),
            (.mobileElement, "mobile_element"), (.mat_peptide, "mat_peptide"), (.sig_peptide, "sig_peptide"),
            (.transit_peptide, "transit_peptide"), (.misc_binding, "misc_binding"),
            (.protein_bind, "protein_bind"), (.regulatory, "regulatory"), (.variation, "variation"),
            (.gap, "gap"), (.source, "source"), (.primer, "primer_bind"),
            // INSDC names no key ORF or SNP, so those two print their raw value (backlog GENBANK-NON-INSDC-KEYS).
            (.orf, "ORF"), (.snp, "SNP"), (.polyASignal, "polyA_signal"),
        ]
        for (type, key) in expected {
            XCTAssertEqual(GenBankWriter.featureKey(of: Self.annotation(of: type)), key, "\(type)")
        }
    }

    /// Every key reads back as its type, which is the inverse of `GenBankReader.mapFeatureType`. A type whose key is
    /// longer than the 15 characters of the key column is left out, since the column cuts it.
    func testEveryKeyReadsBackAsItsType() {
        let tooLongForTheKeyColumn: Set<AnnotationType> = [.restrictionSite, .contaminantMatch]
        for type in AnnotationType.allCases where !tooLongForTheKeyColumn.contains(type) {
            let key = GenBankWriter.featureKey(of: Self.annotation(of: type))
            XCTAssertEqual(GenBankReader.mapFeatureType(key), type, "\(type) printed as \(key)")
        }
    }

    // MARK: - Helpers

    private static func annotation(of type: AnnotationType) -> SequenceAnnotation {
        SequenceAnnotation(type: type, name: "a1", chromosome: "chr1", start: 0, end: 10, strand: .forward)
    }

    /// The keys of the feature lines GenBankWriter prints for `annotations`, in file order.
    private func exportedKeys(_ annotations: [SequenceAnnotation]) throws -> [String] {
        let record = GenBankRecord(
            sequence: try Sequence(name: "chr1", alphabet: .dna, bases: String(repeating: "A", count: 100)),
            annotations: annotations,
            locus: LocusInfo(name: "chr1", length: 100, moleculeType: .dna, topology: .linear)
        )
        let url = folder.appendingPathComponent("out.gb")
        try GenBankWriter(url: url).write([record])
        let text = try String(contentsOf: url, encoding: .utf8)
        // A feature line has five spaces and then its key. Qualifier and sequence lines have more spaces.
        return text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("     ") && !$0.hasPrefix("      ") }
            .map { String($0.dropFirst(5).prefix(15)).trimmingCharacters(in: .whitespaces) }
    }
}
