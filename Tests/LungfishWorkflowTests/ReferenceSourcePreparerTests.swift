import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

final class ReferenceSourcePreparerTests: XCTestCase {
    func testGenBankPreparationCreatesQueryableRecordStoreForEveryRecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceSourcePreparerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("two-records.gb")
        try Self.twoRecordGenBank.write(to: sourceURL, atomically: true, encoding: .utf8)
        let working = root.appendingPathComponent("working", isDirectory: true)

        let prepared = try await ReferenceSourcePreparer().prepare(
            sourceURL: sourceURL,
            bundleName: "Two Records",
            tempDirectory: working
        )

        let recordStoreURL = try XCTUnwrap(prepared.recordStoreURL)
        XCTAssertEqual(recordStoreURL, working.appendingPathComponent("genbank_records.sqlite"))
        let database = try GenBankRecordDatabase(url: recordStoreURL)
        XCTAssertEqual(try database.recordCount(), 2)
        XCTAssertEqual(try database.records().map(\.sequenceName), ["RECORD1", "RECORD2"])
    }

    func testFASTAPreparationDoesNotCreateRecordStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceSourcePreparerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("reference.fa")
        try ">chr1\nACGT\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let prepared = try await ReferenceSourcePreparer().prepare(
            sourceURL: sourceURL,
            bundleName: "FASTA",
            tempDirectory: root.appendingPathComponent("working", isDirectory: true)
        )

        XCTAssertNil(prepared.recordStoreURL)
    }

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
        XCTAssertEqual(prepared.warnings[0].category, "genbank.feature.recovery")
        XCTAssertEqual(prepared.warnings[0].code, "invalid_feature_location")
        XCTAssertEqual(prepared.warnings[0].recordIdentifier, "PREPARE1")
        XCTAssertEqual(prepared.warnings[0].featureType, "CDS")
        XCTAssertNil(prepared.warnings[0].recordFieldKey)
        XCTAssertNotNil(prepared.warnings[0].lineNumber)
    }

    func testGenBankPreparationPreservesMalformedRecordFieldWarningDetails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceSourcePreparerWarningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("record-field.gb")
        try """
        LOCUS       RECOVER                  12 bp    DNA     linear   UNK 01-JAN-2024
        DEFINITION  Recovery fixture.
        ACCESSION   RECOVER
        DBLINK      INSDC: OMITTED
                   malformed continuation indentation
        FEATURES             Location/Qualifiers
             source          1..12
                             /organism="synthetic construct"
        ORIGIN
                1 atgcatgcatgc
        //
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let prepared = try await ReferenceSourcePreparer().prepare(
            sourceURL: sourceURL,
            bundleName: "Recovery",
            tempDirectory: root.appendingPathComponent("working", isDirectory: true)
        )

        let sequences = try await FASTAReader(url: prepared.fastaURL).readAll()
        XCTAssertEqual(sequences.map(\.name), ["RECOVER"])
        let warning = try XCTUnwrap(prepared.warnings.first)
        XCTAssertEqual(warning.category, "genbank.record-field.recovery")
        XCTAssertEqual(warning.code, "malformed_record_field")
        XCTAssertEqual(warning.recordIdentifier, "RECOVER")
        XCTAssertEqual(warning.recordFieldKey, "DBLINK")
        XCTAssertEqual(warning.lineNumber, 5)
        let store = try GenBankRecordDatabase(url: XCTUnwrap(prepared.recordStoreURL))
        XCTAssertNil(try store.records().first?.values["record.DBLINK"])
    }

    private static let twoRecordGenBank = """
    LOCUS       RECORD1                  4 bp    DNA     linear   UNK 01-JAN-2024
    DEFINITION  First record.
    ACCESSION   RECORD1
    VERSION     RECORD1.1
    FEATURES             Location/Qualifiers
         source          1..4
                         /organism="Test one"
    ORIGIN
            1 acgt
    //
    LOCUS       RECORD2                  4 bp    DNA     linear   UNK 01-JAN-2024
    DEFINITION  Second record.
    ACCESSION   RECORD2
    VERSION     RECORD2.1
    FEATURES             Location/Qualifiers
         source          1..4
                         /organism="Test two"
    ORIGIN
            1 tgca
    //
    """
}
