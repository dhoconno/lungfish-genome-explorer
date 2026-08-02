import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class FullLengthONTMHCEMBLWriterTests: XCTestCase {
    func testFormatsDeterministicSequenceRecordAndPreservesValidationWarning() throws {
        let record = GenBankRecord(
            sequence: try Sequence(
                name: "partial-1",
                description: "partial observation",
                alphabet: .dna,
                bases: "AACCGGTTNN"
            ),
            annotations: [
                SequenceAnnotation(
                    type: .source,
                    name: "partial observation",
                    start: 0,
                    end: 10,
                    strand: .forward,
                    qualifiers: [
                        "reference_readiness_status": .init(
                            "not-reference-ready-incomplete"
                        ),
                        "validation_scope": .init("partial-observation-only"),
                    ]
                ),
            ],
            locus: LocusInfo(
                name: "partial-1",
                length: 10,
                moleculeType: .dna,
                topology: .linear
            ),
            definition: "Mamu-DRB1*03:09:01:02_partial_2diff; diagnostic partial observation",
            accession: "partial-1",
            recordFields: [
                .init(
                    key: "COMMENT",
                    value: "This partial observation cannot be fully validated and is not reference-ready.",
                    ordinal: 0
                ),
            ]
        )

        let text = FullLengthONTMHCEMBLWriter().format(record)

        XCTAssertTrue(text.hasPrefix("ID   partial-1; SV 1; linear; genomic DNA; STD; UNC; 10 BP.\n"), text)
        XCTAssertTrue(text.contains("AC   partial-1;\n"), text)
        XCTAssertTrue(text.contains("DE   Mamu-DRB1*03:09:01:02_partial_2diff"), text)
        XCTAssertTrue(text.contains("CC   This partial observation cannot be fully validated"), text)
        XCTAssertTrue(text.contains("FT   source          1..10\n"), text)
        XCTAssertTrue(text.contains("FT                   /reference_readiness_status=\"not-reference-ready-incomplete\""), text)
        XCTAssertTrue(text.contains("SQ   Sequence 10 BP; 2 A; 2 C; 2 G; 2 T; 2 other;\n"), text)
        XCTAssertTrue(text.hasSuffix("//\n"), text)
    }
}
