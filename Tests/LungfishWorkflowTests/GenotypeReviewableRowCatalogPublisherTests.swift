import Foundation
import SQLite3
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class GenotypeReviewableRowCatalogPublisherTests: XCTestCase {
    func testMiSeqReferenceAuthorityDescriptorsCoverManifestAndRecordStoreMutation() throws {
        let fixture = try AnnotatedReferenceFixture()
        defer { fixture.remove() }

        let first = try ONTBarcodeDemuxGenotypingPipeline.reviewableReferenceAuthority(
            referenceFASTAURL: fixture.fastaURL,
            sourceReferenceBundleURL: fixture.bundleURL
        )
        XCTAssertEqual(first.records.first?.displayNameForTesting, "Mafa-A1*001:01")
        XCTAssertEqual(
            Set(first.descriptors.map(\.path)),
            Set([
                fixture.fastaURL.path,
                fixture.manifestURL.path,
                fixture.databaseURL.path,
            ])
        )
        XCTAssertTrue(first.descriptors.allSatisfy {
            $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        let firstDatabaseHash = first.descriptors.first {
            $0.path == fixture.databaseURL.path
        }?.checksumSHA256

        try fixture.updateAllele(to: "Mafa-A1*002:01")
        let second = try ONTBarcodeDemuxGenotypingPipeline.reviewableReferenceAuthority(
            referenceFASTAURL: fixture.fastaURL,
            sourceReferenceBundleURL: fixture.bundleURL
        )

        XCTAssertEqual(second.records.first?.displayNameForTesting, "Mafa-A1*002:01")
        XCTAssertNotEqual(
            second.descriptors.first { $0.path == fixture.databaseURL.path }?
                .checksumSHA256,
            firstDatabaseHash
        )
    }

    func testPublishesAbsentAndSupportedReferenceRowsForExactRoster() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inputs = fixture.inputs(
            references: [
                makeReference("ref-a", "Mafa-A1*001:01", "MHC-A"),
                makeReference("ref-b", "Mafa-B*002:01", "MHC-B"),
            ],
            calls: [
                makeCall("MHC-A", "Mafa-A1*001:01", [("S1", 7)]),
            ]
        )

        let publication = try fixture.publisher.publish(
            inputs,
            to: fixture.outputDirectory
        )

        XCTAssertEqual(publication.document.samples, ["S1", "S2"])
        XCTAssertEqual(publication.document.rows.map(\.displayName), [
            "Mafa-A1*001:01",
            "Mafa-B*002:01",
        ])
        XCTAssertEqual(publication.document.rows[0].supportBySample, ["S1": 7, "S2": 0])
        XCTAssertEqual(publication.document.rows[1].supportBySample, ["S1": 0, "S2": 0])
        XCTAssertEqual(publication.artifact.path, "artifacts/projections/genotype-reviewable-rows.json")
        XCTAssertEqual(publication.artifact.sha256, try ProvenanceFileHasher.sha256(of: publication.outputURL))
        XCTAssertEqual(
            publication.artifact.sizeBytes,
            Int64(try ProvenanceFileHasher.fileSize(of: publication.outputURL))
        )
    }

    func testResolvesRawReferenceSequenceIDsToAuthoritativeDisplayRows() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let publication = try fixture.publisher.publish(
            fixture.inputs(
                references: [
                    makeReference("raw-reference-17", "Mafa-A1*001:01", "MHC-A"),
                ],
                calls: [
                    makeCall("MHC-A", "raw-reference-17", [("S2", 6)]),
                ]
            ),
            to: fixture.outputDirectory
        )

        XCTAssertEqual(publication.document.rows.count, 1)
        XCTAssertEqual(publication.document.rows[0].displayName, "Mafa-A1*001:01")
        XCTAssertEqual(publication.document.rows[0].supportBySample, ["S1": 0, "S2": 6])
    }

    func testPublishesProvisionalExon2AndFullLengthCandidateWithStableIDs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inputs = fixture.inputs(
            references: [makeReference("ref-a", "Mafa-A1*001:01", "MHC-A")],
            candidates: [
                .init(
                    kind: .provisionalExon2,
                    stableID: "sha256:exon2",
                    displayName: "Mafa-A1_02_nov_1",
                    locus: "MHC-A",
                    supportBySample: ["S1": 4]
                ),
                .init(
                    kind: .candidate,
                    stableID: "cluster-0001",
                    displayName: "Mafa-B*002:01_3nt_nov",
                    locus: "MHC-B",
                    supportBySample: ["S2": 9]
                ),
            ]
        )

        let publication = try fixture.publisher.publish(inputs, to: fixture.outputDirectory)
        let candidates = publication.document.rows.filter { $0.kind != .reference }

        XCTAssertEqual(candidates.map(\.kind), [.provisionalExon2, .candidate])
        XCTAssertEqual(candidates.map(\.stableID), ["sha256:exon2", "cluster-0001"])
        XCTAssertEqual(candidates[0].supportBySample, ["S1": 4, "S2": 0])
        XCTAssertEqual(candidates[1].supportBySample, ["S1": 0, "S2": 9])
    }

    func testRejectsRosterMismatchDuplicateCandidatesAndUnknownCalls() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.publisher.publish(
            fixture.inputs(
                calls: [makeCall("MHC-A", "Mafa-A1*001:01", [("outside", 1)])]
            ),
            to: fixture.outputDirectory
        )) {
            XCTAssertEqual(
                ($0 as? GenotypeReviewableRowCatalogPublicationFailure)?
                    .underlyingError as? GenotypeReviewableRowCatalogPublisherError,
                .sampleOutsideRoster("outside")
            )
        }

        let duplicate = GenotypeReviewableRowCandidate(
            kind: .candidate,
            stableID: "stable-1",
            displayName: "Mafa-A1*001:01_1nt_nov",
            locus: "MHC-A",
            supportBySample: ["S1": 1]
        )
        XCTAssertThrowsError(try fixture.publisher.publish(
            fixture.inputs(candidates: [duplicate, duplicate]),
            to: fixture.outputDirectory
        )) {
            XCTAssertEqual(
                ($0 as? GenotypeReviewableRowCatalogPublicationFailure)?
                    .underlyingError as? GenotypeReviewableRowCatalogPublisherError,
                .duplicateCandidateStableID("stable-1")
            )
        }

        XCTAssertThrowsError(try fixture.publisher.publish(
            fixture.inputs(
                references: [],
                calls: [makeCall("MHC-A", "not-authoritative", [("S1", 1)])]
            ),
            to: fixture.outputDirectory
        )) {
            XCTAssertEqual(
                ($0 as? GenotypeReviewableRowCatalogPublicationFailure)?
                    .underlyingError as? GenotypeReviewableRowCatalogPublisherError,
                .callWithoutAuthoritativeRow(locus: "MHC-A", genotype: "not-authoritative")
            )
        }
    }

    func testDistinctStableCandidatesMayShareAProvisionalDisplayName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let publication = try fixture.publisher.publish(
            fixture.inputs(candidates: [
                .init(
                    kind: .candidate,
                    stableID: "stable-1",
                    displayName: "Mafa-A1*001:01_1nt_nov",
                    locus: "MHC-A",
                    supportBySample: ["S1": 2]
                ),
                .init(
                    kind: .candidate,
                    stableID: "stable-2",
                    displayName: "Mafa-A1*001:01_1nt_nov",
                    locus: "MHC-A",
                    supportBySample: ["S2": 3]
                ),
            ]),
            to: fixture.outputDirectory
        )

        let candidates = publication.document.rows.filter { $0.kind == .candidate }
        XCTAssertEqual(
            candidates.compactMap(\.stableID).sorted(),
            ["stable-1", "stable-2"]
        )
    }

    func testPublicationRollbackPreservesExistingCatalogAndRemovesStaging() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outputURL = fixture.outputDirectory
            .appendingPathComponent("artifacts/projections/genotype-reviewable-rows.json")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("existing".utf8).write(to: outputURL)
        let publisher = GenotypeReviewableRowCatalogPublisher(
            dateProvider: { fixture.startedAt },
            publicationObserver: { phase in
                if phase == .staged { throw FixtureError.injected }
            }
        )

        XCTAssertThrowsError(
            try publisher.publish(fixture.inputs(), to: fixture.outputDirectory)
        )
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("existing".utf8))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: outputURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.contains(".staging-") }
        )
    }

    func testPostPublicationFailureRestoresExistingCatalogAndCarriesFailedProvenance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outputURL = fixture.outputDirectory
            .appendingPathComponent("artifacts/projections/genotype-reviewable-rows.json")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("existing-authoritative-catalog".utf8)
        try original.write(to: outputURL)
        let publisher = GenotypeReviewableRowCatalogPublisher(
            dateProvider: { fixture.startedAt },
            publicationObserver: { phase in
                if phase == .published { throw FixtureError.injected }
            }
        )

        XCTAssertThrowsError(
            try publisher.publish(fixture.inputs(), to: fixture.outputDirectory)
        ) { error in
            let failure = error as? GenotypeReviewableRowCatalogPublicationFailure
            XCTAssertEqual(failure?.provenance.exitStatus, 1)
            XCTAssertEqual(failure?.provenance.steps.last?.exitStatus, 1)
            XCTAssertTrue(failure?.provenance.stderr?.contains("injected") == true)
            XCTAssertEqual(
                failure?.provenance.steps.last?.outputs.first?.path,
                outputURL.path
            )
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), original)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: outputURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).contains {
                $0.lastPathComponent.contains(".staging-")
                    || $0.lastPathComponent.contains(".rollback-")
            }
        )
    }

    func testFinalHashFailureRestoresExistingCatalog() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outputURL = fixture.outputDirectory
            .appendingPathComponent("artifacts/projections/genotype-reviewable-rows.json")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("existing-before-hash-fault".utf8)
        try original.write(to: outputURL)
        let publisher = GenotypeReviewableRowCatalogPublisher(
            dateProvider: { fixture.startedAt },
            finalArtifactDescriptorProvider: { _ in
                throw FixtureError.injected
            }
        )

        XCTAssertThrowsError(
            try publisher.publish(fixture.inputs(), to: fixture.outputDirectory)
        ) { error in
            let failure = error as? GenotypeReviewableRowCatalogPublicationFailure
            XCTAssertEqual(failure?.provenance.exitStatus, 1)
            XCTAssertTrue(failure?.provenance.stderr?.contains("injected") == true)
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), original)
    }

    func testSuccessfulReplacementPublishesOnlyTheNewCompleteCatalog() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.publisher.publish(
            fixture.inputs(
                calls: [makeCall("MHC-A", "Mafa-A1*001:01", [("S1", 2)])]
            ),
            to: fixture.outputDirectory
        )

        let replacement = try fixture.publisher.publish(
            fixture.inputs(
                calls: [makeCall("MHC-A", "Mafa-A1*001:01", [("S2", 9)])]
            ),
            to: fixture.outputDirectory
        )
        let decoded = try JSONDecoder().decode(
            GenotypeReviewableRowCatalog.self,
            from: Data(contentsOf: replacement.outputURL)
        ).validated()

        XCTAssertEqual(decoded.rows[0].supportBySample, ["S1": 0, "S2": 9])
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: replacement.outputURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.contains(".staging-") }
        )
    }

    func testPublicationCarriesCompleteCanonicalProvenance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let publication = try fixture.publisher.publish(
            fixture.inputs(),
            to: fixture.outputDirectory
        )
        let provenance = publication.provenance

        XCTAssertEqual(provenance.toolName, "lungfish genotype reviewable row catalog publisher")
        XCTAssertEqual(provenance.toolVersion, "test-version")
        XCTAssertEqual(provenance.workflowName, "test genotype workflow")
        XCTAssertEqual(provenance.workflowVersion, "2")
        XCTAssertEqual(provenance.argv, fixture.argv)
        XCTAssertEqual(provenance.durableReplayArgv, fixture.argv)
        XCTAssertFalse(provenance.reproducibleCommand.isEmpty)
        XCTAssertEqual(provenance.options.explicit["workflowMode"], .string("genotype-only"))
        XCTAssertEqual(provenance.options.resolvedDefaults["supportMetric"], .string("passed-unique-reads"))
        XCTAssertEqual(provenance.runtimeIdentity, fixture.runtime)
        XCTAssertEqual(provenance.files, fixture.inputDescriptors + [provenance.outputs[0]])
        XCTAssertEqual(provenance.output, provenance.outputs[0])
        XCTAssertEqual(provenance.outputs[0].path, publication.outputURL.path)
        XCTAssertEqual(provenance.outputs[0].checksumSHA256, publication.artifact.sha256)
        XCTAssertEqual(provenance.outputs[0].fileSize, UInt64(publication.artifact.sizeBytes))
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertEqual(provenance.wallTimeSeconds, 2)
        XCTAssertNil(provenance.stderr)
        XCTAssertEqual(provenance.steps.count, 1)
        XCTAssertEqual(provenance.steps[0].inputs, fixture.inputDescriptors)
        XCTAssertEqual(provenance.steps[0].outputs, provenance.outputs)
        XCTAssertEqual(provenance.steps[0].exitStatus, 0)
    }

    private enum FixtureError: Error, LocalizedError {
        case injected

        var errorDescription: String? { "injected review catalog failure" }
    }

    private struct Fixture {
        let root: URL
        let outputDirectory: URL
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let argv = ["lungfish-internal", "publish-genotype-reviewable-rows", "--input", "calls.json"]
        let runtime = ProvenanceRuntimeIdentity(
            appVersion: "test-version",
            executablePath: "/test/lungfish",
            processIdentifier: 42,
            operatingSystemVersion: "testOS",
            architecture: "arm64",
            user: "tester",
            condaEnvironment: "test-env",
            condaPrefix: "/test/conda"
        )
        let inputDescriptors: [ProvenanceFileDescriptor]

        var publisher: GenotypeReviewableRowCatalogPublisher {
            let dates = LockedDateSequence([
                startedAt,
                startedAt.addingTimeInterval(2),
            ])
            return GenotypeReviewableRowCatalogPublisher(
                dateProvider: { dates.next() }
            )
        }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("review-catalog-\(UUID().uuidString)", isDirectory: true)
            outputDirectory = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            inputDescriptors = [
                ProvenanceFileDescriptor(
                    path: root.appendingPathComponent("reference.json").path,
                    checksumSHA256: String(repeating: "a", count: 64),
                    fileSize: 10,
                    format: .json,
                    role: .reference
                ),
                ProvenanceFileDescriptor(
                    path: root.appendingPathComponent("roster.json").path,
                    checksumSHA256: String(repeating: "b", count: 64),
                    fileSize: 11,
                    format: .json,
                    role: .input
                ),
                ProvenanceFileDescriptor(
                    path: root.appendingPathComponent("calls.json").path,
                    checksumSHA256: String(repeating: "c", count: 64),
                    fileSize: 12,
                    format: .json,
                    role: .input
                ),
            ]
        }

        func inputs(
            references: [MHCReferenceRecord]? = nil,
            calls: [ONTGenotypeSharedCall] = [],
            candidates: [GenotypeReviewableRowCandidate] = []
        ) -> GenotypeReviewableRowCatalogInputs {
            GenotypeReviewableRowCatalogInputs(
                referenceRecords: references ?? [
                    makeReference("ref-a", "Mafa-A1*001:01", "MHC-A"),
                ],
                authoritativeSamples: ["S1", "S2"],
                calls: calls,
                candidates: candidates,
                inputDescriptors: inputDescriptors,
                workflowName: "test genotype workflow",
                workflowVersion: "2",
                toolVersion: "test-version",
                argv: argv,
                userVisibleOptions: ["workflowMode": .string("genotype-only")],
                resolvedDefaults: ["supportMetric": .string("passed-unique-reads")],
                runtimeIdentity: runtime
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class LockedDateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]
    private var index = 0

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let date = dates[min(index, dates.count - 1)]
        index += 1
        return date
    }
}

private func makeReference(
    _ sequenceID: String,
    _ alleleName: String,
    _ locus: String
) -> MHCReferenceRecord {
    MHCReferenceRecord(
        sequenceID: sequenceID,
        alleleName: alleleName,
        locus: locus,
        moleculeClass: .genomicDNA,
        classEvidence: .annotatedMetadata,
        sequenceLength: 100
    )
}

private func makeCall(
    _ locus: String,
    _ genotype: String,
    _ support: [(String, Int)]
) -> ONTGenotypeSharedCall {
    ONTGenotypeSharedCall(
        locus: locus,
        genotype: genotype,
        sampleSupport: support.map {
            ONTGenotypeSampleSupport(
                sample: $0.0,
                passedAlignments: $0.1,
                passedUniqueReads: $0.1
            )
        }
    )
}

private struct AnnotatedReferenceFixture {
    let root: URL
    let bundleURL: URL
    let fastaURL: URL
    let manifestURL: URL
    let databaseURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-reference-\(UUID().uuidString)", isDirectory: true)
        bundleURL = root.appendingPathComponent("reference.lungfishref", isDirectory: true)
        fastaURL = bundleURL.appendingPathComponent("genome/reference.fa")
        manifestURL = bundleURL.appendingPathComponent("manifest.json")
        databaseURL = bundleURL.appendingPathComponent("metadata/records.sqlite")
        try FileManager.default.createDirectory(
            at: fastaURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(">raw-a\nACGT\n".utf8).write(to: fastaURL)
        let manifest: [String: Any] = [
            "genome": ["path": "genome/reference.fa"],
            "record_store": ["database_path": "metadata/records.sqlite"],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL)
        try Self.createDatabase(at: databaseURL, allele: "Mafa-A1*001:01")
    }

    func updateAllele(to allele: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw FixtureDatabaseError.open
        }
        defer { sqlite3_close(database) }
        let escaped = allele.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(
            database,
            "UPDATE field_values SET value = '\(escaped)' WHERE field_key = 'feature.allele';",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw FixtureDatabaseError.update
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func createDatabase(at url: URL, allele: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK,
              let database else {
            throw FixtureDatabaseError.open
        }
        defer { sqlite3_close(database) }
        let escaped = allele.replacingOccurrences(of: "'", with: "''")
        let sql = """
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
        INSERT INTO records VALUES (1, 'raw-a', 4, 0);
        INSERT INTO field_values VALUES (1, 'feature.allele', 0, '\(escaped)');
        INSERT INTO field_values VALUES (1, 'feature.gene', 0, 'A1');
        INSERT INTO field_values VALUES (1, 'feature.mol_type', 0, 'genomic DNA');
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureDatabaseError.create
        }
    }

    private enum FixtureDatabaseError: Error {
        case open
        case create
        case update
    }
}

private extension MHCReferenceRecord {
    var displayNameForTesting: String { alleleName }
}
