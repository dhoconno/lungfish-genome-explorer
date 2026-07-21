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
}
