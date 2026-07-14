import XCTest
import SQLite3
@testable import LungfishIO
import LungfishCore

final class GenBankRecordDatabaseTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenBankRecordDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testCreateRoundTripsRecordFieldsAndAggregatedFeatureQualifiers() throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("records.sqlite")
        let records = try makeRecords()

        let result = try GenBankRecordDatabase.create(records: records, at: databaseURL)

        XCTAssertEqual(result.recordCount, 2)
        let database = try GenBankRecordDatabase(url: databaseURL)
        let rows = try database.records()
        XCTAssertEqual(rows.map(\.sequenceName), ["NHP00353", "NHP02052"])
        XCTAssertEqual(rows[0].values["feature.allele"], "Mafa-I*01:01:01; Mafa-I*01:01:02")
        XCTAssertEqual(rows[0].values["record.REFERENCE.1.PUBMED"], "10640754")
        XCTAssertEqual(rows[0].values["feature.db_xref"], "taxon:9541")
        XCTAssertEqual(rows[0].values["record.KEYWORDS"], "MHC; class I; macaque")

        let definitions = try database.fieldDefinitions()
        XCTAssertEqual(Array(definitions.prefix(6).map(\.displayTitle)), [
            "Allele", "Gene", "Definition", "Accession", "Organism", "Product"
        ])
        XCTAssertEqual(Array(definitions.dropFirst(6).prefix(2).map(\.key)), [
            "record.LOCUS.NAME", "record.LOCUS.LENGTH"
        ])
        XCTAssertEqual(definitions.first(where: { $0.key == "record.LOCUS.LENGTH" })?.valueType, "number")
        XCTAssertEqual(definitions.first(where: { $0.key == "feature.codon_start" })?.valueType, "number")
        XCTAssertEqual(definitions.first(where: { $0.key == "feature.allele" })?.sourceCategory, "feature")
    }

    func testOpeningDatabaseMissingRequiredTableIsRejected() throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("corrupt.sqlite")
        try executeSQLite(at: databaseURL, sql: """
            CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO metadata VALUES ('schema_version', '1');
            CREATE TABLE records (id INTEGER PRIMARY KEY, sequence_name TEXT NOT NULL UNIQUE, sequence_length INTEGER NOT NULL, source_ordinal INTEGER NOT NULL);
            """)

        XCTAssertThrowsError(try GenBankRecordDatabase(url: databaseURL)) { error in
            guard case GenBankRecordDatabase.Error.invalidSchema(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("field_definitions"))
        }
    }

    func testOpeningUnsupportedSchemaVersionIsRejected() throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("future.sqlite")
        try executeSQLite(at: databaseURL, sql: """
            CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO metadata VALUES ('schema_version', '999');
            CREATE TABLE records (id INTEGER PRIMARY KEY, sequence_name TEXT NOT NULL UNIQUE, sequence_length INTEGER NOT NULL, source_ordinal INTEGER NOT NULL);
            CREATE TABLE field_definitions (key TEXT PRIMARY KEY, display_title TEXT NOT NULL, value_type TEXT NOT NULL, source_category TEXT NOT NULL, preferred_order INTEGER NOT NULL);
            CREATE TABLE field_values (record_id INTEGER NOT NULL REFERENCES records(id) ON DELETE CASCADE, field_key TEXT NOT NULL REFERENCES field_definitions(key), value_ordinal INTEGER NOT NULL, value TEXT NOT NULL, PRIMARY KEY (record_id,field_key,value_ordinal));
            """)

        XCTAssertThrowsError(try GenBankRecordDatabase(url: databaseURL)) { error in
            guard case GenBankRecordDatabase.Error.unsupportedSchemaVersion(let found, let expected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(found, 999)
            XCTAssertEqual(expected, 1)
        }
    }

    private func makeRecords() throws -> [GenBankRecord] {
        let first = GenBankRecord(
            sequence: try Sequence(name: "NHP00353", alphabet: .dna, bases: "ATGCATGC"),
            annotations: [
                SequenceAnnotation(
                    type: .source,
                    name: "source",
                    start: 0,
                    end: 8,
                    qualifiers: [
                        "organism": AnnotationQualifier("Macaca fascicularis"),
                        "db_xref": AnnotationQualifier(["taxon:9541", "taxon:9541"])
                    ]
                ),
                SequenceAnnotation(
                    type: .gene,
                    name: "Mafa-I",
                    start: 0,
                    end: 8,
                    qualifiers: [
                        "gene": AnnotationQualifier("Mafa-I"),
                        "allele": AnnotationQualifier(["Mafa-I*01:01:01", "Mafa-I*01:01:01"])
                    ]
                ),
                SequenceAnnotation(
                    type: .cds,
                    name: "MHC class I antigen",
                    start: 0,
                    end: 6,
                    qualifiers: [
                        "allele": AnnotationQualifier(["Mafa-I*01:01:01", "Mafa-I*01:01:02"]),
                        "product": AnnotationQualifier("MHC class I antigen"),
                        "codon_start": AnnotationQualifier("1")
                    ]
                )
            ],
            locus: LocusInfo(name: "NHP00353", length: 8, moleculeType: .dna, topology: .linear, division: "PRI", date: "01-JAN-2024"),
            definition: "Mafa-I allele",
            accession: "NHP00353",
            version: "NHP00353.1",
            recordFields: [
                GenBankRecordField(key: "LOCUS.NAME", value: "NHP00353", ordinal: 0),
                GenBankRecordField(key: "LOCUS.LENGTH", value: "8", ordinal: 1),
                GenBankRecordField(key: "DEFINITION", value: "Mafa-I allele", ordinal: 2),
                GenBankRecordField(key: "ACCESSION", value: "NHP00353", ordinal: 3),
                GenBankRecordField(key: "ORGANISM", value: "Macaca fascicularis", ordinal: 4),
                GenBankRecordField(key: "REFERENCE.1.PUBMED", value: "10640754", ordinal: 5),
                GenBankRecordField(key: "KEYWORDS", value: "MHC", ordinal: 6),
                GenBankRecordField(key: "KEYWORDS", value: "MHC", ordinal: 7),
                GenBankRecordField(key: "KEYWORDS", value: "class I", ordinal: 8),
                GenBankRecordField(key: "KEYWORDS", value: "macaque", ordinal: 9)
            ]
        )
        let second = GenBankRecord(
            sequence: try Sequence(name: "NHP02052", alphabet: .dna, bases: "ATGC"),
            annotations: [
                SequenceAnnotation(type: .source, name: "source", start: 0, end: 4, qualifiers: ["db_xref": AnnotationQualifier("taxon:9541")]),
                SequenceAnnotation(type: .gene, name: "Mafa-B", start: 0, end: 4, qualifiers: ["gene": AnnotationQualifier("Mafa-B")])
            ],
            locus: LocusInfo(name: "NHP02052", length: 4, moleculeType: .dna, topology: .linear),
            recordFields: [
                GenBankRecordField(key: "LOCUS.NAME", value: "NHP02052", ordinal: 0),
                GenBankRecordField(key: "LOCUS.LENGTH", value: "4", ordinal: 1),
                GenBankRecordField(key: "DEFINITION", value: "Mafa-B allele", ordinal: 2),
                GenBankRecordField(key: "ACCESSION", value: "NHP02052", ordinal: 3),
                GenBankRecordField(key: "ORGANISM", value: "Macaca fascicularis", ordinal: 4),
                GenBankRecordField(key: "REFERENCE.1.PUBMED", value: "20000000", ordinal: 5)
            ]
        )
        return [first, second]
    }

    private func executeSQLite(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "SQLite", code: 1)
        }
        defer { sqlite3_close(database) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
