import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class GenBankWriterTests: XCTestCase {
    func testFormatMatchesSingleRecordWrittenToDiskByteForByte() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("genbank-writer-\(UUID().uuidString).gb")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let record = GenBankRecord(
            sequence: try Sequence(name: "NHP00344", alphabet: .dna, bases: "ACGTACGT"),
            annotations: [
                SequenceAnnotation(
                    type: .cds,
                    name: "Mafa-E*02:01:01",
                    start: 1,
                    end: 7,
                    strand: .forward,
                    qualifiers: [
                        "allele": AnnotationQualifier("Mafa-E*02:01:01"),
                        "translation": AnnotationQualifier("TY"),
                    ]
                ),
            ],
            locus: LocusInfo(
                name: "NHP00344",
                length: 8,
                moleculeType: .dna,
                topology: .linear,
                division: "PRI",
                date: "20-JUL-2026"
            ),
            definition: "Mafa-E allele",
            accession: "NHP00344",
            version: "NHP00344.1"
        )
        let writer = GenBankWriter(url: outputURL)

        let formatted = writer.format(record)
        try writer.write([record])

        XCTAssertEqual(Data(formatted.utf8), try Data(contentsOf: outputURL))
    }

    func testFormatPreservesOrderedRecordLevelGenBankFields() throws {
        let record = GenBankRecord(
            sequence: try Sequence(name: "NHP00344", alphabet: .dna, bases: "ACGT"),
            annotations: [],
            locus: LocusInfo(
                name: "NHP00344",
                length: 4,
                moleculeType: .dna,
                topology: .linear
            ),
            definition: "Mafa-E allele",
            accession: "NHP00344",
            version: "NHP00344.1",
            recordFields: [
                GenBankRecordField(key: "DEFINITION", value: "Mafa-E allele", ordinal: 0),
                GenBankRecordField(key: "ACCESSION", value: "NHP00344", ordinal: 1),
                GenBankRecordField(key: "VERSION", value: "NHP00344.1", ordinal: 2),
                GenBankRecordField(key: "DBLINK", value: "BioProject: PRJ1", ordinal: 3),
                GenBankRecordField(key: "DBLINK", value: "BioSample: SAMN1", ordinal: 4),
                GenBankRecordField(key: "KEYWORDS", value: "MHC; class I.", ordinal: 5),
                GenBankRecordField(key: "SOURCE", value: "Macaca fascicularis", ordinal: 6),
                GenBankRecordField(key: "ORGANISM", value: "Macaca fascicularis", ordinal: 7),
                GenBankRecordField(key: "TAXONOMY", value: "Eukaryota; Metazoa.", ordinal: 8),
                GenBankRecordField(key: "REFERENCE", value: "1  (bases 1 to 4)", ordinal: 9),
                GenBankRecordField(key: "REFERENCE.1.AUTHORS", value: "Doe,J.", ordinal: 10),
                GenBankRecordField(key: "REFERENCE.1.TITLE", value: "Direct Submission", ordinal: 11),
                GenBankRecordField(key: "REFERENCE.1.JOURNAL", value: "Submitted (20-JUL-2026)", ordinal: 12),
                GenBankRecordField(key: "COMMENT", value: "Previous designations:: Mafa-E-old", ordinal: 13),
                // Parser-derived convenience fields remain available to callers but must not
                // duplicate the same content in canonical GenBank text.
                GenBankRecordField(key: "COMMENT.Previous designations", value: "Mafa-E-old", ordinal: 14),
            ]
        )

        let formatted = GenBankWriter(url: URL(fileURLWithPath: "/dev/null")).format(record)

        XCTAssertEqual(formatted, [
            "LOCUS       NHP00344                  4 bp    DNA  linear",
            "DEFINITION  Mafa-E allele",
            "ACCESSION   NHP00344",
            "VERSION     NHP00344.1",
            "DBLINK      BioProject: PRJ1",
            "DBLINK      BioSample: SAMN1",
            "KEYWORDS    MHC; class I.",
            "SOURCE      Macaca fascicularis",
            "  ORGANISM  Macaca fascicularis",
            "            Eukaryota; Metazoa.",
            "REFERENCE   1  (bases 1 to 4)",
            "  AUTHORS   Doe,J.",
            "  TITLE     Direct Submission",
            "  JOURNAL   Submitted (20-JUL-2026)",
            "COMMENT     Previous designations:: Mafa-E-old",
            "ORIGIN      ",
            "        1 acgt",
            "//",
            "",
        ].joined(separator: "\n"))
    }

    /// The reader's internal `_lf_` qualifiers never reach a written file (BIO ruling on lane 12.13, option A),
    /// and the reader sets them again from each feature line of that file.
    func testTheWriterOmitsInternalQualifiersAndTheReaderRestoresThem() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("genbank-writer-internal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("source.gb")
        let source = """
        LOCUS       segA                      40 bp    DNA     linear   SYN 01-JAN-2026
        DEFINITION  Synthetic record with a gene and a split reverse CDS.
        FEATURES             Location/Qualifiers
             gene            3..14
                             /gene="geneA"
             CDS             complement(join(16..21,25..36))
                             /gene="geneA"
                             /product="split protein"
        ORIGIN
                1 acgtacgtac ggttaaccgg ttaaccggtt acgtacgtac
        //

        """
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let read = try GenBankReader(url: sourceURL).readAllSync()
        XCTAssertEqual(read.first?.annotations.count, 2)
        XCTAssertEqual(
            read.first?.annotations.compactMap { $0.qualifier(GenBankReader.rawFeatureTypeQualifierKey) },
            ["gene", "CDS"],
            "The reader marks each feature it reads"
        )

        let writtenURL = folder.appendingPathComponent("written.gb")
        try GenBankWriter(url: writtenURL).write(read)
        let text = try String(contentsOf: writtenURL, encoding: .utf8)
        XCTAssertFalse(text.contains("/_lf_"), text)

        let featureLines = text.split(separator: "\n").map(String.init).filter { line in
            line.hasPrefix("     ") && !line.hasPrefix("      ")
        }
        let written = featureLines.map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        }
        XCTAssertEqual(written.count, 2, text)
        let reread = try XCTUnwrap(GenBankReader(url: writtenURL).readAllSync().first)
        XCTAssertEqual(reread.annotations.count, written.count)
        for (annotation, fields) in zip(reread.annotations, written) {
            XCTAssertEqual(annotation.qualifier(GenBankReader.rawFeatureTypeQualifierKey), fields.first)
            XCTAssertEqual(annotation.qualifier(GenBankReader.rawLocationQualifierKey), fields.last)
            XCTAssertEqual(annotation.qualifier("gene"), "geneA")
        }
    }
}
