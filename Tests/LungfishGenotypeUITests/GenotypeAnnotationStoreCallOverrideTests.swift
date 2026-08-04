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

    func testSavingAfterAnalysisRevisionReplacesStaleOverrideAgainstActiveBaseline() throws {
        let fixture = try makeStore(callOverrides: [
            staleOverride(
                originalCall: "revision-6-baseline",
                overrideCall: "revision-6-override"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let auditCountBefore = fixture.store.sidecar.auditLog.count

        let result = try fixture.store.mutateCallOverrides(
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
                    rationale: "Saved against revision 7"
                ),
            ],
            author: "Analyst",
            analysisIdentity: identity()
        )

        XCTAssertTrue(result.didChange)
        let replacement = try XCTUnwrap(
            fixture.store.sidecar.callOverrides.first
        )
        XCTAssertEqual(fixture.store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(replacement.originalCall, "M1A")
        XCTAssertEqual(replacement.overrideCall, "M2A")
        XCTAssertEqual(replacement.analysisIdentity, identity().sidecarIdentity)
        let audit = try XCTUnwrap(
            fixture.store.sidecar.auditLog.dropFirst(auditCountBefore).first
        )
        XCTAssertEqual(audit.before, "M1A")
        XCTAssertEqual(audit.after, "M2A")
    }

    func testRestoringAfterAnalysisRevisionRemovesStaleOverrideAndAuditsActiveBaseline() throws {
        let fixture = try makeStore(callOverrides: [
            staleOverride(
                originalCall: "revision-6-baseline",
                overrideCall: "revision-6-override"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let auditCountBefore = fixture.store.sidecar.auditLog.count

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
                    rationale: "Restore active pipeline call"
                ),
            ],
            author: "Analyst",
            analysisIdentity: identity()
        )

        XCTAssertTrue(result.didChange)
        XCTAssertTrue(fixture.store.sidecar.callOverrides.isEmpty)
        let audit = try XCTUnwrap(
            fixture.store.sidecar.auditLog.dropFirst(auditCountBefore).first
        )
        XCTAssertEqual(audit.action, "clearOverride")
        XCTAssertEqual(audit.before, "M1A")
        XCTAssertEqual(audit.after, "M1A")
        XCTAssertEqual(
            audit.callOverrideMutation?.analysisIdentity,
            identity().sidecarIdentity
        )
    }

    func testActiveIdentityFallsBackToLatestValidLegacyOverride() throws {
        let legacy = GenotypeAnnotationSidecar.CallOverride(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            originalCall: "M1A",
            overrideCall: "legacy-override",
            reasonTag: .analystJudgment,
            rationale: "Legacy record without identity",
            author: "Earlier Analyst",
            timestamp: "2026-08-03T00:20:00Z"
        )
        let malformedExact = GenotypeAnnotationSidecar.CallOverride(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            originalCall: "not-the-active-baseline",
            overrideCall: "malformed-exact",
            reasonTag: .analystJudgment,
            rationale: "Malformed record for active identity",
            author: "Earlier Analyst",
            timestamp: "not-a-timestamp",
            analysisIdentity: identity().sidecarIdentity,
            operationID: "malformed-active-operation"
        )
        let fixture = try makeStore(callOverrides: [
            legacy, malformedExact,
        ])
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let auditCountBefore = fixture.store.sidecar.auditLog.count

        _ = try fixture.store.mutateCallOverrides(
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
                    rationale: "Replace valid legacy authority"
                ),
            ],
            author: "Analyst",
            analysisIdentity: identity()
        )

        let audit = try XCTUnwrap(
            fixture.store.sidecar.auditLog.dropFirst(auditCountBefore).first
        )
        XCTAssertEqual(audit.before, "legacy-override")
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

    func testSecondTargetValidationFailurePublishesNeitherTarget() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let annotationBefore = try Data(contentsOf: fixture.annotationURL)
        let provenanceBefore = try Data(contentsOf: fixture.provenanceURL)
        let memoryBefore = fixture.store.sidecar
        let first = mutations()[0]

        XCTAssertThrowsError(try fixture.store.mutateCallOverrides(
            [first, first],
            author: "Analyst",
            analysisIdentity: identity()
        )) { error in
            XCTAssertEqual(
                error as? CallOverrideMutationError,
                .duplicateTarget(first.target)
            )
        }

        XCTAssertEqual(fixture.store.sidecar, memoryBefore)
        XCTAssertEqual(fixture.store.callOverrideMutationRevision, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.annotationURL), annotationBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.provenanceURL), provenanceBefore)
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

    func testIdentityLessClearWrapperRejectsIdentityBoundOverride() throws {
        let bound = GenotypeAnnotationSidecar.CallOverride(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            originalCall: "revision-6-baseline",
            overrideCall: "revision-6-override",
            reasonTag: .analystJudgment,
            rationale: "Belongs to a specific analysis",
            author: "Earlier Analyst",
            timestamp: "2026-08-03T01:00:00Z",
            analysisIdentity: .init(
                assayID: "MHC-exon2-miSeq",
                analysisRevisionID: "revision-6",
                definitionSetID: "definition-2"
            ),
            operationID: "revision-6-operation"
        )
        let fixture = try makeStore(callOverrides: [bound])
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let annotationBefore = try Data(contentsOf: fixture.annotationURL)
        let provenanceBefore = try Data(contentsOf: fixture.provenanceURL)

        XCTAssertThrowsError(try fixture.store.clearOverride(
            sample: bound.sample,
            locus: bound.locus,
            slot: bound.slot
        ))

        XCTAssertEqual(fixture.store.sidecar.callOverrides, [bound])
        XCTAssertEqual(try Data(contentsOf: fixture.annotationURL), annotationBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.provenanceURL), provenanceBefore)
        XCTAssertEqual(fixture.store.callOverrideMutationRevision, 0)
    }

    func testIdentityLessClearWrapperRejectsMixedLegacyAndIdentityBoundHistory()
        throws {
        let bound = GenotypeAnnotationSidecar.CallOverride(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            originalCall: "revision-6-baseline",
            overrideCall: "revision-6-override",
            reasonTag: .analystJudgment,
            rationale: "Identity-bound history",
            author: "Earlier Analyst",
            timestamp: "2026-08-03T01:00:00Z",
            analysisIdentity: .init(
                assayID: "MHC-exon2-miSeq",
                analysisRevisionID: "revision-6",
                definitionSetID: "definition-2"
            ),
            operationID: "revision-6-operation"
        )
        let legacy = GenotypeAnnotationSidecar.CallOverride(
            sample: bound.sample,
            locus: bound.locus,
            slot: bound.slot,
            originalCall: "legacy-baseline",
            overrideCall: "legacy-override",
            reasonTag: .misCall,
            rationale: "Later legacy history",
            author: "Legacy Analyst",
            timestamp: "2026-08-03T02:00:00Z"
        )
        let fixture = try makeStore(callOverrides: [bound, legacy])
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let annotationBefore = try Data(contentsOf: fixture.annotationURL)
        let provenanceBefore = try Data(contentsOf: fixture.provenanceURL)

        XCTAssertThrowsError(try fixture.store.clearOverride(
            sample: bound.sample,
            locus: bound.locus,
            slot: bound.slot
        ))

        XCTAssertEqual(fixture.store.sidecar.callOverrides, [bound, legacy])
        XCTAssertEqual(try Data(contentsOf: fixture.annotationURL), annotationBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.provenanceURL), provenanceBefore)
        XCTAssertEqual(fixture.store.callOverrideMutationRevision, 0)
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
        faultPoint: GenotypeAnnotationPublicationFaultPoint? = nil,
        callOverrides: [GenotypeAnnotationSidecar.CallOverride] = []
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
        if !callOverrides.isEmpty {
            var seeded = try GenotypeAnnotationSidecar.decode(
                Data(contentsOf: annotationURL)
            )
            seeded.callOverrides = callOverrides
            try seeded.encoded().write(to: annotationURL)
        }
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

    private func staleOverride(
        originalCall: String,
        overrideCall: String
    ) -> GenotypeAnnotationSidecar.CallOverride {
        .init(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            originalCall: originalCall,
            overrideCall: overrideCall,
            reasonTag: .analystJudgment,
            rationale: "Belonged to revision 6",
            author: "Earlier Analyst",
            timestamp: "2026-08-03T00:30:00Z",
            analysisIdentity: .init(
                assayID: "MHC-exon2-miSeq",
                analysisRevisionID: "revision-6",
                definitionSetID: "definition-2"
            ),
            operationID: "revision-6-operation"
        )
    }
}

private struct InjectedCallOverrideFailure: Error {}
