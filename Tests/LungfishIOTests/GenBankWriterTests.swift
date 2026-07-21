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
}
