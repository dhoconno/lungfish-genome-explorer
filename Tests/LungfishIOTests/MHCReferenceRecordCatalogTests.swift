import Foundation
import SQLite3
import XCTest
@testable import LungfishIO

final class MHCReferenceRecordCatalogTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("mhc-reference-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    func testAnnotatedRecordStoreOverridesLengthFallbackForGenomicDNAAndCDNA() throws {
        let bundleURL = try makeBundle(
            fasta: """
            >NHP01222 Wrong-A*001:01, fallback description
            AAAAAAAAAAAA
            >NHP01638 Wrong-B*001:01, fallback description
            CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
            """,
            annotations: [
                .init(
                    sequenceID: "NHP01222",
                    sequenceLength: 12,
                    fields: [
                        "feature.allele": ["Mafa-A1*006:01:01:01"],
                        "feature.gene": ["A1"],
                        "feature.mol_type": ["genomic DNA"],
                    ]
                ),
                .init(
                    sequenceID: "NHP01638",
                    sequenceLength: 30,
                    fields: [
                        "feature.allele": ["Mafa-B*018:01:01:01"],
                        "feature.gene": ["B"],
                        "feature.mol_type": ["mRNA"],
                    ]
                ),
            ]
        )

        let catalog = try MHCReferenceRecordCatalog.load(from: bundleURL, cdnaThreshold: 20)

        XCTAssertEqual(
            catalog.records,
            [
                MHCReferenceRecord(
                    sequenceID: "NHP01222",
                    alleleName: "Mafa-A1*006:01:01:01",
                    locus: "Mafa-A1",
                    moleculeClass: .genomicDNA,
                    classEvidence: .annotatedMetadata,
                    sequenceLength: 12
                ),
                MHCReferenceRecord(
                    sequenceID: "NHP01638",
                    alleleName: "Mafa-B*018:01:01:01",
                    locus: "Mafa-B",
                    moleculeClass: .cDNA,
                    classEvidence: .annotatedMetadata,
                    sequenceLength: 30
                ),
            ]
        )
        XCTAssertEqual(catalog.record(sequenceID: "NHP01222"), catalog.records[0])
    }

    func testFASTAOnlyFallbackUsesDescriptionAndStrictLengthThreshold() throws {
        let bundleURL = try makeBundle(
            fasta: """
            >short Mafa-A1*006:01:02, A1 locus allele.
            AAAAAAAAAAA
            >boundary Mafa-B*018:01, B locus allele.
            CCCCCCCCCCCC
            """,
            annotations: nil
        )

        let first = try MHCReferenceRecordCatalog.load(from: bundleURL, cdnaThreshold: 12)
        let second = try MHCReferenceRecordCatalog.load(from: bundleURL, cdnaThreshold: 12)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.records.map(\.sequenceID), ["short", "boundary"])
        XCTAssertEqual(first.records[0].alleleName, "Mafa-A1*006:01:02")
        XCTAssertEqual(first.records[0].locus, "Mafa-A1")
        XCTAssertEqual(first.records[0].moleculeClass, .cDNA)
        XCTAssertEqual(first.records[0].classEvidence, .lengthThresholdFallback)
        XCTAssertEqual(first.records[0].sequenceLength, 11)
        XCTAssertEqual(first.records[1].moleculeClass, .genomicDNA)
        XCTAssertEqual(first.records[1].sequenceLength, 12)
    }

    func testMissingRecordFieldsFallBackIndependentlyToFASTAAndLength() throws {
        let bundleURL = try makeBundle(
            fasta: """
            >NHP10000 Mafa-I*001:02, I locus allele.
            AAAAAAAAAA
            """,
            annotations: [
                .init(
                    sequenceID: "NHP10000",
                    sequenceLength: 10,
                    fields: ["feature.gene": ["I"]]
                )
            ]
        )

        let record = try XCTUnwrap(
            MHCReferenceRecordCatalog.load(from: bundleURL, cdnaThreshold: 20)
                .record(sequenceID: "NHP10000")
        )

        XCTAssertEqual(record.alleleName, "Mafa-I*001:02")
        XCTAssertEqual(record.locus, "Mafa-I")
        XCTAssertEqual(record.moleculeClass, .cDNA)
        XCTAssertEqual(record.classEvidence, .lengthThresholdFallback)
    }

    func testConflictingAnnotatedMoleculeClassesThrowTypedActionableError() throws {
        let bundleURL = try makeBundle(
            fasta: """
            >NHP-conflict Mafa-A1*001:01, A1 locus allele.
            AAAAAAAAAA
            """,
            annotations: [
                .init(
                    sequenceID: "NHP-conflict",
                    sequenceLength: 10,
                    fields: [
                        "feature.allele": ["Mafa-A1*001:01"],
                        "feature.gene": ["A1"],
                        "feature.mol_type": ["genomic DNA", "mRNA"],
                    ]
                )
            ]
        )

        XCTAssertThrowsError(try MHCReferenceRecordCatalog.load(from: bundleURL)) { error in
            guard case let MHCReferenceRecordCatalogError.conflictingMoleculeClasses(sequenceID, values) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(sequenceID, "NHP-conflict")
            XCTAssertEqual(values, ["genomic DNA", "mRNA"])
            XCTAssertTrue(error.localizedDescription.contains("NHP-conflict"))
        }
    }

    func testNoResolvableAlleleOrLocusThrowsTypedActionableError() throws {
        let bundleURL = try makeBundle(
            fasta: """
            >NHP-unnamed sequence without allele metadata
            AAAAAAAAAA
            """,
            annotations: [
                .init(
                    sequenceID: "NHP-unnamed",
                    sequenceLength: 10,
                    fields: ["feature.mol_type": ["genomic DNA"]]
                )
            ]
        )

        XCTAssertThrowsError(try MHCReferenceRecordCatalog.load(from: bundleURL)) { error in
            guard case let MHCReferenceRecordCatalogError.unresolvedAlleleOrLocus(sequenceID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(sequenceID, "NHP-unnamed")
            XCTAssertTrue(error.localizedDescription.contains("NHP-unnamed"))
        }
    }

    func testRecordStoreIsOpenedReadOnlyAndDoesNotCreateSQLiteSidecars() throws {
        let bundleURL = try makeBundle(
            fasta: """
            >read-only Mafa-A4*001:01, A4 locus allele.
            AAAAAAAAAA
            """,
            annotations: [
                .init(
                    sequenceID: "read-only",
                    sequenceLength: 10,
                    fields: [
                        "feature.allele": ["Mafa-A4*001:01"],
                        "feature.gene": ["A4"],
                        "feature.mol_type": ["mRNA"],
                    ]
                )
            ]
        )
        let databaseURL = bundleURL.appendingPathComponent("metadata/records.sqlite")
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: databaseURL.path)

        let catalog = try MHCReferenceRecordCatalog.load(from: bundleURL)

        XCTAssertEqual(catalog.records.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        XCTAssertEqual(attributesBefore[.size] as? NSNumber, attributesAfter[.size] as? NSNumber)
    }

    func testRejectsReferencePayloadSymlinkThatEscapesBundle() throws {
        let bundleURL = try makeBundle(
            fasta: """
            >inside Mafa-A1*001:01, A1 locus allele.
            AAAAAAAAAA
            """,
            annotations: nil
        )
        let outsideFASTA = workspace.appendingPathComponent("outside.fa")
        try Data(">outside Mafa-B*001:01\nAAAAAAAAAA\n".utf8).write(to: outsideFASTA)
        let fastaURL = bundleURL.appendingPathComponent("genome/reference.fa")
        try FileManager.default.removeItem(at: fastaURL)
        try FileManager.default.createSymbolicLink(at: fastaURL, withDestinationURL: outsideFASTA)

        XCTAssertThrowsError(try MHCReferenceRecordCatalog.load(from: bundleURL)) { error in
            guard case let MHCReferenceRecordCatalogError.unsafeBundlePath(field, path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(field, "genome.path")
            XCTAssertEqual(path, "genome/reference.fa")
        }
    }

    private struct AnnotationFixture {
        let sequenceID: String
        let sequenceLength: Int
        let fields: [String: [String]]
    }

    private func makeBundle(fasta: String, annotations: [AnnotationFixture]?) throws -> URL {
        let bundleURL = workspace.appendingPathComponent("fixture-\(UUID().uuidString).lungfishref", isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try Data((fasta + "\n").utf8).write(to: genomeDirectory.appendingPathComponent("reference.fa"))

        var manifest: [String: Any] = [
            "genome": ["path": "genome/reference.fa"],
        ]

        if let annotations {
            let metadataDirectory = bundleURL.appendingPathComponent("metadata", isDirectory: true)
            try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
            let databaseURL = metadataDirectory.appendingPathComponent("records.sqlite")
            try writeRecordStore(at: databaseURL, records: annotations)
            manifest["record_store"] = ["database_path": "metadata/records.sqlite"]
        }

        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"))
        return bundleURL
    }

    private func writeRecordStore(at url: URL, records: [AnnotationFixture]) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "MHCReferenceRecordCatalogTests", code: 1)
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            CREATE TABLE records (
                id INTEGER PRIMARY KEY,
                sequence_name TEXT NOT NULL UNIQUE,
                sequence_length INTEGER NOT NULL,
                source_ordinal INTEGER NOT NULL
            );
            CREATE TABLE field_values (
                record_id INTEGER NOT NULL,
                field_key TEXT NOT NULL,
                value_ordinal INTEGER NOT NULL,
                value TEXT NOT NULL,
                PRIMARY KEY (record_id, field_key, value_ordinal)
            );
            """,
            in: database
        )

        for (recordOffset, record) in records.enumerated() {
            let recordID = recordOffset + 1
            try execute(
                "INSERT INTO records VALUES (\(recordID), \(quoted(record.sequenceID)), \(record.sequenceLength), \(recordOffset));",
                in: database
            )
            for fieldKey in record.fields.keys.sorted() {
                for (valueOrdinal, value) in (record.fields[fieldKey] ?? []).enumerated() {
                    try execute(
                        "INSERT INTO field_values VALUES (\(recordID), \(quoted(fieldKey)), \(valueOrdinal), \(quoted(value)));",
                        in: database
                    )
                }
            }
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(domain: "MHCReferenceRecordCatalogTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
