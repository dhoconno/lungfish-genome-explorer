import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeAnnotationStoreCallOverrideTests: XCTestCase {
    func testTwoSlotBatchPublishesOnceWithExactAuditsAndReplayProvenance() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let auditCountBefore = fixture.store.sidecar.auditLog.count

        let result = try fixture.store.mutateCallOverrides(
            mutations(),
            author: "Analyst",
            analysisIdentity: identity()
        )

        let h1 = GenotypeEffectiveHaplotypeKey(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1
        )
        let h2 = GenotypeEffectiveHaplotypeKey(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h2
        )
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.changedKeys, [h1, h2])
        XCTAssertEqual(fixture.store.callOverrideMutationRevision, 1)
        XCTAssertEqual(fixture.store.sidecar.callOverrides.count, 2)
        let audits = Array(
            fixture.store.sidecar.auditLog.dropFirst(auditCountBefore)
        )
        XCTAssertEqual(audits.count, 2)
        XCTAssertEqual(Set(audits.map(\.timestamp)).count, 1)
        XCTAssertEqual(
            Set(audits.compactMap {
                $0.callOverrideMutation?.operationID
            }).count,
            1
        )
        XCTAssertEqual(audits.map(\.slot), [.h1, .h2])
        XCTAssertEqual(audits.map(\.before), ["M1A", "M1B"])
        XCTAssertEqual(audits.map(\.after), ["M2A", "M2B"])
        XCTAssertEqual(
            fixture.store.sidecar.callOverrides.map(\.analysisIdentity),
            [identity().sidecarIdentity, identity().sidecarIdentity]
        )

        let durable = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: fixture.annotationURL)
        )
        XCTAssertEqual(durable, fixture.store.sidecar)
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: fixture.provenanceURL)
        )
        XCTAssertEqual(envelope.steps.count, 1)
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertGreaterThanOrEqual(envelope.wallTimeSeconds ?? -1, 0)
        XCTAssertNotNil(envelope.runtimeIdentity)
        XCTAssertEqual(
            envelope.durableReplayArgv,
            [
                "lungfish-cli",
                "genotype",
                "replay-call-overrides",
                "--provenance", fixture.provenanceURL.path,
                "--bundle", fixture.bundleURL.path,
            ]
        )
        XCTAssertEqual(
            envelope.options.explicit["sample"],
            .string("Animal-1")
        )
        XCTAssertEqual(
            envelope.options.explicit["resolvedAuthor"],
            .string("Analyst")
        )
        XCTAssertEqual(
            envelope.options.explicit["analysisIdentity"],
            .dictionary([
                "assayID": .string("MHC-exon2-miSeq"),
                "analysisRevisionID": .string("revision-7"),
                "definitionSetID": .string("definition-2"),
            ])
        )
        XCTAssertNotNil(
            envelope.options.explicit["replayPayloadBase64"]?.stringValue
        )
        XCTAssertNotNil(
            envelope.options.explicit["replayPayloadSHA256"]?.stringValue
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["changedTargetCount"],
            .integer(2)
        )
        XCTAssertEqual(envelope.files.filter { $0.role == .input }.count, 2)
        XCTAssertTrue(envelope.files.allSatisfy {
            $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertEqual(envelope.outputs, [envelope.output].compactMap { $0 })
        XCTAssertEqual(envelope.output?.path, fixture.annotationURL.path)
    }

    func testNoOpRestorePublishesNothing() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let annotationBefore = try Data(contentsOf: fixture.annotationURL)
        let provenanceBefore = try Data(contentsOf: fixture.provenanceURL)
        let memoryBefore = fixture.store.sidecar

        let result = try fixture.store.mutateCallOverrides(
            [
                .init(
                    target: .init(
                        sample: "Animal-1",
                        locus: "MHC-A",
                        slot: .h1
                    ),
                    baseline: "M1A",
                    after: "M1A",
                    reason: .analystJudgment,
                    rationale: "Restore pipeline call"
                ),
            ],
            author: "Analyst",
            analysisIdentity: identity()
        )

        XCTAssertFalse(result.didChange)
        XCTAssertTrue(result.changedKeys.isEmpty)
        XCTAssertEqual(fixture.store.sidecar, memoryBefore)
        XCTAssertEqual(fixture.store.callOverrideMutationRevision, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.annotationURL), annotationBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.provenanceURL), provenanceBefore)
    }

    func testStaleRevisionLeavesMemoryAndDurableBytesUnchanged() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let staleMemory = fixture.store.sidecar
        let fresh = try GenotypeAnnotationStore(
            bundleURL: fixture.bundleURL,
            author: "Other Analyst",
            seedBuiltInSmartCohorts: false
        )
        try fresh.setSampleStatus(.reviewed, sample: "Animal-2")
        let annotationBefore = try Data(contentsOf: fixture.annotationURL)
        let provenanceBefore = try Data(contentsOf: fixture.provenanceURL)

        XCTAssertThrowsError(try fixture.store.mutateCallOverrides(
            mutations(),
            author: "Analyst",
            analysisIdentity: identity()
        ))

        XCTAssertEqual(fixture.store.sidecar, staleMemory)
        XCTAssertEqual(fixture.store.callOverrideMutationRevision, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.annotationURL), annotationBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.provenanceURL), provenanceBefore)
    }

    func testPublicationFaultsPublishBothSlotsOrNeither() throws {
        for faultPoint in [
            GenotypeAnnotationPublicationFaultPoint.beforeProvenancePublication,
            .commitDirectorySync,
        ] {
            let fixture = try makeStore(faultPoint: faultPoint)
            defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
            let annotationBefore = try Data(contentsOf: fixture.annotationURL)
            let provenanceBefore = try Data(contentsOf: fixture.provenanceURL)
            let memoryBefore = fixture.store.sidecar

            XCTAssertThrowsError(try fixture.store.mutateCallOverrides(
                mutations(),
                author: "Analyst",
                analysisIdentity: identity()
            ))

            XCTAssertEqual(fixture.store.sidecar, memoryBefore)
            XCTAssertEqual(fixture.store.callOverrideMutationRevision, 0)
            XCTAssertEqual(try Data(contentsOf: fixture.annotationURL), annotationBefore)
            XCTAssertEqual(try Data(contentsOf: fixture.provenanceURL), provenanceBefore)
        }
    }

    func testCompatibilityWrappersUseAtomicBatchPath() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }

        try fixture.store.applyOverride(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            originalCall: "M1A",
            overrideCall: "M2A",
            reasonTag: .misCall,
            rationale: "Legacy caller"
        )
        XCTAssertEqual(fixture.store.callOverrideMutationRevision, 1)
        XCTAssertEqual(fixture.store.sidecar.callOverrides.count, 1)

        try fixture.store.clearOverride(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1
        )
        XCTAssertEqual(fixture.store.callOverrideMutationRevision, 2)
        XCTAssertTrue(fixture.store.sidecar.callOverrides.isEmpty)
        XCTAssertEqual(
            fixture.store.sidecar.auditLog.suffix(2).map(\.action),
            ["override", "clearOverride"]
        )
    }

    func testOpeningLegacySchemaDoesNotRewriteOrPromoteDurableBytes() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        var legacy = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-08-03T00:00:00Z"
        )
        legacy.schemaVersion = 3
        let legacyData = try legacy.encoded()
        let annotationURL = bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try legacyData.write(to: annotationURL)

        let store = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "Analyst",
            seedBuiltInSmartCohorts: false
        )

        XCTAssertEqual(store.sidecar.schemaVersion, 3)
        XCTAssertEqual(try Data(contentsOf: annotationURL), legacyData)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ProvenanceRecorder.fileSidecarURL(
                for: annotationURL
            ).path
        ))
    }

    private struct Fixture {
        let bundleURL: URL
        let annotationURL: URL
        let provenanceURL: URL
        let store: GenotypeAnnotationStore
    }

    private func makeStore(
        faultPoint: GenotypeAnnotationPublicationFaultPoint? = nil
    ) throws -> Fixture {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try Data(#"{"analysis":"revision-7"}"#.utf8).write(
            to: bundleURL.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        _ = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "seed"
        )
        let annotationURL = bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(
            for: annotationURL
        )
        let store = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "Analyst",
            seedBuiltInSmartCohorts: false,
            publicationFaultInjector: { point in
                point == faultPoint ? InjectedCallOverrideFailure() : nil
            }
        )
        return Fixture(
            bundleURL: bundleURL,
            annotationURL: annotationURL,
            provenanceURL: provenanceURL,
            store: store
        )
    }

    private func mutations() -> [CallOverrideMutation] {
        [
            .init(
                target: .init(
                    sample: "Animal-1",
                    locus: "MHC-A",
                    slot: .h1
                ),
                baseline: "M1A",
                after: "M2A",
                reason: .misCall,
                rationale: "Confirmed by reads"
            ),
            .init(
                target: .init(
                    sample: "Animal-1",
                    locus: "MHC-A",
                    slot: .h2
                ),
                baseline: "M1B",
                after: "M2B",
                reason: .dropoutSuspected,
                rationale: "Recovered second haplotype"
            ),
        ]
    }

    private func identity() -> GenotypeEffectiveHaplotypeIdentity {
        .init(
            assayID: "MHC-exon2-miSeq",
            analysisRevisionID: "revision-7",
            definitionSetID: "definition-2"
        )
    }
}

private struct InjectedCallOverrideFailure: Error {}
