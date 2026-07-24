import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import SQLite3
@testable import LungfishWorkflow

final class MHCReferenceVisualizationArtifactBuilderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mhc-reference-visualization-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testBuildUsesPersistedRawSelectedEvidenceIdentityAndProducesCanonicalRecords() throws {
        let fixture = try makeReferenceBundle()
        let candidates = makeCandidateDocument(candidates: [
            makeCandidate(
                stableClusterID: "cluster-novel",
                classification: .novel,
                closestReferenceName: "Mafa-A1*018:01:01:01",
                selectedRawReferenceID: "UNCALLED_NOVEL_NEIGHBOR"
            ),
            makeCandidate(
                stableClusterID: "cluster-extension",
                classification: .extension,
                closestReferenceName: "Mafa-B*021:01:01",
                selectedRawReferenceID: "UNCALLED_EXTENSION_NEIGHBOR"
            ),
            makeCandidate(
                stableClusterID: "cluster-known-neighbor",
                classification: .novel,
                closestReferenceName: "Mafa-E*02:01:01",
                selectedRawReferenceID: "NHP00344"
            ),
        ])

        let output = try MHCReferenceVisualizationArtifactBuilder().build(.init(
            referenceBundleURL: fixture.bundleURL,
            exactKnownRawReferenceIDs: ["NHP00344"],
            candidates: candidates
        ))

        XCTAssertEqual(
            output.document.records.map(\.rawReferenceID),
            ["UNCALLED_EXTENSION_NEIGHBOR", "NHP00344", "UNCALLED_NOVEL_NEIGHBOR"]
        )
        XCTAssertEqual(Set(output.document.recordsByRawReferenceID.keys), [
            "NHP00344",
            "UNCALLED_NOVEL_NEIGHBOR",
            "UNCALLED_EXTENSION_NEIGHBOR",
        ])

        let exact = try XCTUnwrap(output.document.recordsByRawReferenceID["NHP00344"])
        XCTAssertEqual(exact.sourceOrdinal, 1)
        XCTAssertEqual(exact.alleleName, "Mafa-E*02:01:01")
        XCTAssertNotEqual(exact.rawReferenceID, exact.alleleName)
        XCTAssertEqual(exact.locus, "Mafa-E")
        XCTAssertEqual(exact.sequence, "ACGTACGT")
        XCTAssertEqual(exact.sequenceSHA256, sha256("ACGTACGT"))
        XCTAssertEqual(exact.recordFields["DEFINITION"], ["Mafa-E exact known reference"])
        XCTAssertEqual(exact.recordFields["DBLINK"], ["INSDC: FIRST", "INSDC: SECOND"])
        XCTAssertEqual(exact.annotatedTranslation, "TY")
        XCTAssertEqual(exact.features.map(\.type), ["CDS", "exon"])
        XCTAssertEqual(exact.features.map(\.sourceOrdinal), [0, 1])
        XCTAssertEqual(exact.features.map(\.interval), [0..<8, 0..<4])
        XCTAssertEqual(exact.features[0].strand, "+")
        XCTAssertEqual(exact.features[0].rawGenBankLocation, "1..8")
        XCTAssertEqual(exact.features[1].qualifiers["exon_number"], ["1"])
        XCTAssertNil(exact.features[0].qualifiers[GenBankReader.rawLocationQualifierKey])
        XCTAssertNil(exact.features[0].qualifiers["annotation_db_row_id"])
        XCTAssertEqual(exact.roles, [
            ONTMHCReferenceVisualizationRoleAssignment(
                role: .exactKnownCall,
                candidateStableClusterIDs: []
            ),
            ONTMHCReferenceVisualizationRoleAssignment(
                role: .closestNovelReference,
                candidateStableClusterIDs: ["cluster-known-neighbor"]
            ),
        ])
        let novel = try XCTUnwrap(
            output.document.recordsByRawReferenceID["UNCALLED_NOVEL_NEIGHBOR"]
        )
        XCTAssertEqual(novel.sourceOrdinal, 2)
        XCTAssertEqual(novel.alleleName, "Mafa-A1*018:01:01:01")
        XCTAssertNotEqual(novel.rawReferenceID, novel.alleleName)
        XCTAssertEqual(novel.sequence, "GGGGAAAA")
        XCTAssertEqual(novel.sequenceSHA256, sha256("GGGGAAAA"))
        XCTAssertEqual(novel.recordFields["DEFINITION"], ["Novel closest reference"])
        XCTAssertNil(novel.annotatedTranslation)
        XCTAssertEqual(novel.features.map(\.type), ["gene", "gene"])
        XCTAssertEqual(novel.features.map(\.sourceOrdinal), [0, 0])
        XCTAssertEqual(novel.features.map(\.interval), [1..<3, 5..<7])
        XCTAssertEqual(novel.features.map(\.strand), ["+", "+"])
        XCTAssertEqual(
            novel.features.map(\.rawGenBankLocation),
            ["join(2..3,6..7)", "join(2..3,6..7)"]
        )
        XCTAssertEqual(
            novel.features.map { $0.qualifiers["allele"] },
            [["Mafa-A1*018:01:01:01"], ["Mafa-A1*018:01:01:01"]]
        )
        XCTAssertEqual(
            novel.features.map { $0.qualifiers["gene"] },
            [["A1"], ["A1"]]
        )
        XCTAssertEqual(novel.roles, [
            ONTMHCReferenceVisualizationRoleAssignment(
                role: .closestNovelReference,
                candidateStableClusterIDs: ["cluster-novel"]
            ),
        ])

        let extensionRecord = try XCTUnwrap(
            output.document.recordsByRawReferenceID["UNCALLED_EXTENSION_NEIGHBOR"]
        )
        XCTAssertEqual(extensionRecord.sourceOrdinal, 0)
        XCTAssertEqual(extensionRecord.alleleName, "Mafa-B*021:01:01")
        XCTAssertNotEqual(extensionRecord.rawReferenceID, extensionRecord.alleleName)
        XCTAssertEqual(extensionRecord.sequence, "TTTTCCCC")
        XCTAssertEqual(extensionRecord.sequenceSHA256, sha256("TTTTCCCC"))
        XCTAssertEqual(
            extensionRecord.recordFields["DEFINITION"],
            ["Extension closest reference"]
        )
        XCTAssertEqual(extensionRecord.annotatedTranslation, "KF")
        XCTAssertEqual(extensionRecord.features.map(\.type), ["CDS"])
        XCTAssertEqual(extensionRecord.features.map(\.sourceOrdinal), [0])
        XCTAssertEqual(extensionRecord.features.map(\.interval), [0..<8])
        XCTAssertEqual(extensionRecord.features.map(\.strand), ["-"])
        XCTAssertEqual(
            extensionRecord.features.map(\.rawGenBankLocation),
            ["complement(1..8)"]
        )
        XCTAssertEqual(extensionRecord.roles, [
            ONTMHCReferenceVisualizationRoleAssignment(
                role: .closestExtensionReference,
                candidateStableClusterIDs: ["cluster-extension"]
            ),
        ])

        let expectedGenBankByRawReferenceID = [
            "UNCALLED_EXTENSION_NEIGHBOR": [
                "LOCUS       UNCALLED_EXTENSI          8 bp    DNA  linear",
                "DEFINITION  Extension closest reference",
                "ACCESSION   UNCALLED_EXTENSION_NEIGHBOR",
                "VERSION     UNCALLED_EXTENSION_NEIGHBOR.1",
                "DBLINK      INSDC: FIRST",
                "DBLINK      INSDC: SECOND",
                "KEYWORDS    MHC; class I.",
                "SOURCE      Macaca fascicularis",
                "  ORGANISM  Macaca fascicularis",
                "            Eukaryota; Metazoa.",
                "REFERENCE   1  (bases 1 to 8)",
                "  AUTHORS   Doe,J.",
                "  TITLE     Direct Submission",
                "  JOURNAL   Submitted (20-JUL-2026)",
                "COMMENT     Previous designations:: legacy-name",
                "FEATURES             Location/Qualifiers",
                "     cds             complement(1..8)",
                "                     /allele=\"Mafa-B*021:01:01\"",
                "                     /translation=\"KF\"",
                "ORIGIN      ",
                "        1 ttttcccc",
                "//",
            ].joined(separator: "\n") + "\n",
            "NHP00344": [
                "LOCUS       NHP00344\(String(repeating: " ", count: 18))8 bp    DNA  linear",
                "DEFINITION  Mafa-E exact known reference",
                "ACCESSION   NHP00344",
                "VERSION     NHP00344.1",
                "DBLINK      INSDC: FIRST",
                "DBLINK      INSDC: SECOND",
                "KEYWORDS    MHC; class I.",
                "SOURCE      Macaca fascicularis",
                "  ORGANISM  Macaca fascicularis",
                "            Eukaryota; Metazoa.",
                "REFERENCE   1  (bases 1 to 8)",
                "  AUTHORS   Doe,J.",
                "  TITLE     Direct Submission",
                "  JOURNAL   Submitted (20-JUL-2026)",
                "COMMENT     Previous designations:: legacy-name",
                "FEATURES             Location/Qualifiers",
                "     cds             1..8",
                "                     /allele=\"Mafa-E*02:01:01\"",
                "                     /translation=\"TY\"",
                "     exon            1..4",
                "                     /allele=\"Mafa-E*02:01:01\"",
                "                     /exon_number=\"1\"",
                "ORIGIN      ",
                "        1 acgtacgt",
                "//",
            ].joined(separator: "\n") + "\n",
            "UNCALLED_NOVEL_NEIGHBOR": [
                "LOCUS       UNCALLED_NOVEL_N          8 bp    DNA  linear",
                "DEFINITION  Novel closest reference",
                "ACCESSION   UNCALLED_NOVEL_NEIGHBOR",
                "VERSION     UNCALLED_NOVEL_NEIGHBOR.1",
                "DBLINK      INSDC: FIRST",
                "DBLINK      INSDC: SECOND",
                "KEYWORDS    MHC; class I.",
                "SOURCE      Macaca fascicularis",
                "  ORGANISM  Macaca fascicularis",
                "            Eukaryota; Metazoa.",
                "REFERENCE   1  (bases 1 to 8)",
                "  AUTHORS   Doe,J.",
                "  TITLE     Direct Submission",
                "  JOURNAL   Submitted (20-JUL-2026)",
                "COMMENT     Previous designations:: legacy-name",
                "FEATURES             Location/Qualifiers",
                "     gene            join(2..3,6..7)",
                "                     /allele=\"Mafa-A1*018:01:01:01\"",
                "                     /gene=\"A1\"",
                "ORIGIN      ",
                "        1 ggggaaaa",
                "//",
            ].joined(separator: "\n") + "\n",
        ]
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: output.document.records.map {
                ($0.rawReferenceID, $0.genBankText)
            }),
            expectedGenBankByRawReferenceID
        )

        for record in output.document.records {
            XCTAssertTrue(record.genBankText.hasPrefix("LOCUS       "))
            XCTAssertTrue(record.genBankText.hasSuffix("//\n"))
            XCTAssertEqual(
                record.fastaText,
                ">\(record.rawReferenceID) \(record.alleleName)\n\(record.sequence)\n"
            )
        }
        XCTAssertEqual(
            Data(output.genBankText.utf8),
            output.document.records.reduce(into: Data()) {
                $0.append(Data($1.genBankText.utf8))
            }
        )
        XCTAssertEqual(
            Data(output.fastaText.utf8),
            output.document.records.reduce(into: Data()) {
                $0.append(Data($1.fastaText.utf8))
            }
        )
    }

    func testBuildFailsBeforeOutputWhenRequestedRawIdentityIsMissing() throws {
        let fixture = try makeReferenceBundle()

        XCTAssertThrowsError(
            try MHCReferenceVisualizationArtifactBuilder().build(.init(
                referenceBundleURL: fixture.bundleURL,
                exactKnownRawReferenceIDs: ["MISSING_RAW_REFERENCE"],
                candidates: nil
            ))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("MISSING_RAW_REFERENCE"))
        }
    }

    func testBuildFailsWhenRecordFieldValueIsUnexpectedlyNull() throws {
        let fixture = try makeReferenceBundle()
        let databaseURL = fixture.bundleURL
            .appendingPathComponent("metadata/genbank_records.sqlite")
        try replaceRecordFieldsTableAllowingNullValue(at: databaseURL)

        XCTAssertThrowsError(
            try MHCReferenceVisualizationArtifactBuilder().build(.init(
                referenceBundleURL: fixture.bundleURL,
                exactKnownRawReferenceIDs: ["NHP00344"],
                candidates: nil
            ))
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("Unexpected NULL field_values.value")
            )
        }
    }

    func testBuildKeepsSequenceOnlyRecordWithoutSynthesizingFeatures() throws {
        let fixture = try makeReferenceBundle()
        let manifestURL = fixture.bundleURL.appendingPathComponent(BundleManifest.filename)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        manifest["annotations"] = []
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)

        let output = try MHCReferenceVisualizationArtifactBuilder().build(.init(
            referenceBundleURL: fixture.bundleURL,
            exactKnownRawReferenceIDs: ["NHP00344"],
            candidates: nil
        ))

        let record = try XCTUnwrap(output.document.records.first)
        XCTAssertEqual(record.rawReferenceID, "NHP00344")
        XCTAssertEqual(record.sequence, "ACGTACGT")
        XCTAssertTrue(record.features.isEmpty)
        XCTAssertNil(record.annotatedTranslation)
        XCTAssertFalse(record.genBankText.contains("FEATURES"))
    }

    private func makeReferenceBundle() throws -> (bundleURL: URL, records: [GenBankRecord]) {
        let bundleURL = root.appendingPathComponent("complete.lungfishref", isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let annotationDirectory = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        let metadataDirectory = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)

        let records = try [
            makeGenBankRecord(
                rawID: "UNCALLED_EXTENSION_NEIGHBOR",
                alleleName: "Mafa-B*021:01:01",
                gene: "B",
                sequence: "TTTTCCCC",
                definition: "Extension closest reference"
            ),
            makeGenBankRecord(
                rawID: "NHP00344",
                alleleName: "Mafa-E*02:01:01",
                gene: "E",
                sequence: "ACGTACGT",
                definition: "Mafa-E exact known reference"
            ),
            makeGenBankRecord(
                rawID: "UNCALLED_NOVEL_NEIGHBOR",
                alleleName: "Mafa-A1*018:01:01:01",
                gene: "A1",
                sequence: "GGGGAAAA",
                definition: "Novel closest reference"
            ),
        ]

        let fastaURL = genomeDirectory.appendingPathComponent("reference.fa")
        var fastaText = ""
        var chromosomes: [ChromosomeInfo] = []
        var indexLines: [String] = []
        for (ordinal, record) in records.enumerated() {
            let allele = try XCTUnwrap(record.annotations.first?.qualifier("allele"))
            let header = ">\(record.locus.name) \(allele)\n"
            let sequence = record.sequence.asString()
            let offset = fastaText.utf8.count + header.utf8.count
            fastaText += header + sequence + "\n"
            chromosomes.append(ChromosomeInfo(
                name: record.locus.name,
                length: Int64(sequence.count),
                offset: Int64(offset),
                lineBases: sequence.count,
                lineWidth: sequence.count + 1,
                fastaDescription: allele
            ))
            indexLines.append(
                "\(record.locus.name)\t\(sequence.count)\t\(offset)\t\(sequence.count)\t\(sequence.count + 1)"
            )
            XCTAssertEqual(ordinal, chromosomes.count - 1)
        }
        try fastaText.write(to: fastaURL, atomically: true, encoding: .utf8)
        try (indexLines.joined(separator: "\n") + "\n").write(
            to: genomeDirectory.appendingPathComponent("reference.fa.fai"),
            atomically: true,
            encoding: .utf8
        )

        let recordStoreURL = metadataDirectory.appendingPathComponent("genbank_records.sqlite")
        let store = try GenBankRecordDatabase.create(records: records, at: recordStoreURL)
        let bedURL = annotationDirectory.appendingPathComponent("features.bed")
        let exactRawLocationKey = GenBankReader.rawLocationQualifierKey
        let bed = """
        UNCALLED_EXTENSION_NEIGHBOR\t0\t8\tMafa-B*021:01:01\t0\t-\t0\t8\t0,0,0\t1\t8,\t0,\tCDS\tallele=Mafa-B*021:01:01;translation=KF;\(exactRawLocationKey)=complement(1..8)
        NHP00344\t0\t8\tMafa-E*02:01:01\t0\t+\t0\t8\t0,0,0\t1\t8,\t0,\tCDS\tallele=Mafa-E*02:01:01;translation=TY;\(exactRawLocationKey)=1..8
        NHP00344\t0\t4\tMafa-E*02:01:01\t0\t+\t0\t4\t0,0,0\t1\t4,\t0,\texon\tallele=Mafa-E*02:01:01;exon_number=1;\(exactRawLocationKey)=1..4
        UNCALLED_NOVEL_NEIGHBOR\t1\t7\tMafa-A1*018:01:01:01\t0\t+\t1\t7\t0,0,0\t2\t2,2,\t0,4,\tgene\tallele=Mafa-A1*018:01:01:01;gene=A1;\(exactRawLocationKey)=join(2..3,6..7)
        """
        try bed.write(to: bedURL, atomically: true, encoding: .utf8)
        let annotationDatabaseURL = annotationDirectory.appendingPathComponent("features.sqlite")
        _ = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotationDatabaseURL)
        try Data().write(to: annotationDirectory.appendingPathComponent("features.bb"))

        let manifest = BundleManifest(
            name: "Complete MHC Reference",
            identifier: "org.lungfish.tests.mhc-reference-visualization",
            source: SourceInfo(organism: "Macaca fascicularis", assembly: "IPD-MHC"),
            genome: GenomeInfo(
                path: "genome/reference.fa",
                indexPath: "genome/reference.fa.fai",
                totalLength: Int64(records.reduce(0) { $0 + $1.sequence.length }),
                chromosomes: chromosomes
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "imported_annotations",
                    name: "Imported Annotations",
                    path: "annotations/features.bb",
                    databasePath: "annotations/features.sqlite",
                    featureCount: 4
                ),
            ],
            recordStore: ReferenceRecordStoreInfo(
                schemaVersion: GenBankRecordDatabase.schemaVersion,
                format: ReferenceRecordStoreInfo.supportedFormat,
                databasePath: "metadata/genbank_records.sqlite",
                recordCount: store.recordCount
            )
        )
        try manifest.save(to: bundleURL)
        return (bundleURL, records)
    }

    private func makeGenBankRecord(
        rawID: String,
        alleleName: String,
        gene: String,
        sequence: String,
        definition: String
    ) throws -> GenBankRecord {
        GenBankRecord(
            sequence: try Sequence(name: rawID, alphabet: .dna, bases: sequence),
            annotations: [
                SequenceAnnotation(
                    type: .source,
                    name: rawID,
                    start: 0,
                    end: sequence.count,
                    qualifiers: [
                        "allele": AnnotationQualifier(alleleName),
                        "gene": AnnotationQualifier(gene),
                        "mol_type": AnnotationQualifier("genomic DNA"),
                    ]
                ),
            ],
            locus: LocusInfo(name: rawID, length: sequence.count, moleculeType: .dna, topology: .linear),
            definition: definition,
            accession: rawID,
            version: "\(rawID).1",
            recordFields: [
                GenBankRecordField(key: "DEFINITION", value: definition, ordinal: 0),
                GenBankRecordField(key: "ACCESSION", value: rawID, ordinal: 1),
                GenBankRecordField(key: "VERSION", value: "\(rawID).1", ordinal: 2),
                GenBankRecordField(key: "DBLINK", value: "INSDC: FIRST", ordinal: 3),
                GenBankRecordField(key: "DBLINK", value: "INSDC: SECOND", ordinal: 4),
                GenBankRecordField(key: "KEYWORDS", value: "MHC; class I.", ordinal: 5),
                GenBankRecordField(key: "SOURCE", value: "Macaca fascicularis", ordinal: 6),
                GenBankRecordField(key: "ORGANISM", value: "Macaca fascicularis", ordinal: 7),
                GenBankRecordField(key: "TAXONOMY", value: "Eukaryota; Metazoa.", ordinal: 8),
                GenBankRecordField(key: "REFERENCE", value: "1  (bases 1 to 8)", ordinal: 9),
                GenBankRecordField(key: "REFERENCE.1.AUTHORS", value: "Doe,J.", ordinal: 10),
                GenBankRecordField(key: "REFERENCE.1.TITLE", value: "Direct Submission", ordinal: 11),
                GenBankRecordField(key: "REFERENCE.1.JOURNAL", value: "Submitted (20-JUL-2026)", ordinal: 12),
                GenBankRecordField(key: "COMMENT", value: "Previous designations:: legacy-name", ordinal: 13),
                GenBankRecordField(key: "COMMENT.Previous designations", value: "legacy-name", ordinal: 14),
            ]
        )
    }

    private func replaceRecordFieldsTableAllowingNullValue(at databaseURL: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        defer { sqlite3_close(connection) }

        let sql = """
        PRAGMA foreign_keys = OFF;
        BEGIN IMMEDIATE TRANSACTION;
        ALTER TABLE field_values RENAME TO field_values_original;
        CREATE TABLE field_values (
            record_id INTEGER,
            field_key TEXT,
            value_ordinal INTEGER,
            value TEXT,
            PRIMARY KEY (record_id, field_key, value_ordinal)
        );
        INSERT INTO field_values(record_id, field_key, value_ordinal, value)
            SELECT record_id, field_key, value_ordinal, value FROM field_values_original;
        DROP TABLE field_values_original;
        CREATE INDEX idx_field_values_key_value
            ON field_values(field_key, value COLLATE NOCASE);
        CREATE INDEX idx_field_values_record_key
            ON field_values(record_id, field_key);
        UPDATE field_values
            SET value = NULL
            WHERE field_key = 'record.DBLINK' AND value_ordinal = 0;
        COMMIT;
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) }
        sqlite3_free(errorMessage)
        XCTAssertEqual(result, SQLITE_OK, message ?? "SQLite mutation failed")
    }

    private func makeCandidateDocument(
        candidates: [ONTMHCCandidateRecord]
    ) -> ONTMHCCandidateAllelesDocument {
        ONTMHCCandidateAllelesDocument(
            schemaVersion: 1,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: [],
            sequenceFASTA: ONTMHCArtifactReference(path: "candidates.fa", sha256: "", sizeBytes: 0),
            candidates: candidates,
            observations: []
        )
    }

    private func makeCandidate(
        stableClusterID: String,
        classification: ONTMHCCandidateClassification,
        closestReferenceName: String,
        selectedRawReferenceID: String
    ) -> ONTMHCCandidateRecord {
        ONTMHCCandidateRecord(
            stableClusterID: stableClusterID,
            provisionalName: "\(closestReferenceName)_\(classification == .novel ? "nov" : "ext")",
            locus: String(closestReferenceName.split(separator: "*")[0]),
            classification: classification,
            supportClass: .singleton,
            closestReferenceName: closestReferenceName,
            closestReferenceClass: .genomicDNA,
            snpCount: 1,
            insertedBases: 0,
            deletedBases: 0,
            longGapBases: 0,
            comparableBases: 8,
            shorterCoverage: 1,
            identity: 0.99,
            mappingQuality: 60,
            alignmentScore: 8,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 10,
            supportingSampleIDs: ["sample-1"],
            fastaRecordID: stableClusterID,
            sequenceSHA256: String(repeating: "0", count: 64),
            selectedEvidence: ONTMHCEvidenceLocator(
                bamPath: "evidence.bam",
                queryName: stableClusterID,
                referenceName: selectedRawReferenceID,
                readGroupID: nil,
                referenceStart: 0,
                cigar: "8M"
            )
        )
    }

    private func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
