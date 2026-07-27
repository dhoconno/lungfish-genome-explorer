import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class GenotypeReviewableRowCatalogPublisherTests: XCTestCase {
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
                $0 as? GenotypeReviewableRowCatalogPublisherError,
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
                $0 as? GenotypeReviewableRowCatalogPublisherError,
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
                $0 as? GenotypeReviewableRowCatalogPublisherError,
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

    private enum FixtureError: Error {
        case injected
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
