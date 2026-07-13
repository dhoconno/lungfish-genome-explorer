import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

final class ReferenceSourcePreparerTests: XCTestCase {
    func testGenBankPreparationKeepsSequenceAndReportsSkippedFeature() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceSourcePreparerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("reference.gb")
        try """
        LOCUS       PREPARE1                12 bp    DNA     linear   UNK 01-JAN-2024
        DEFINITION  Shared preparation fixture.
        ACCESSION   PREPARE1
        VERSION     PREPARE1.1
        FEATURES             Location/Qualifiers
             gene            1..6
                             /gene="valid_gene"
             CDS             bad..location
                             /product="invalid feature"
        ORIGIN
                1 atgcatgcatgc
        //
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let prepared = try await ReferenceSourcePreparer().prepare(
            sourceURL: sourceURL,
            bundleName: "Prepared Reference",
            tempDirectory: root.appendingPathComponent("working", isDirectory: true)
        )

        let sequences = try await FASTAReader(url: prepared.fastaURL).readAll()
        XCTAssertEqual(sequences.map { $0.asString() }, ["ATGCATGCATGC"])
        XCTAssertEqual(prepared.annotationInputs.count, 1)
        XCTAssertEqual(prepared.sequenceNames, ["PREPARE1"])
        XCTAssertEqual(prepared.warnings.count, 1)
        XCTAssertEqual(prepared.warnings[0].recordIdentifier, "PREPARE1")
        XCTAssertEqual(prepared.warnings[0].featureType, "CDS")
    }
}
