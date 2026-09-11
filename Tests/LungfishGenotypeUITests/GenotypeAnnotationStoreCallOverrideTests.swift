import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeAnnotationStoreCallOverrideTests: XCTestCase {
    func testFormattingOnlyWorkbookSaveCanBeAcceptedWithoutInventingAnnotationChanges() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let service = try prepareEditableWorkbook(fixture)
        let original = fixture.store.sidecar
        let originalProvenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: fixture.provenanceURL))
        let workbook = fixture.bundleURL.appendingPathComponent("current.xlsx")
        try editWorkbook(workbook, code: "w['Edit Calls'].column_dimensions['B'].width=45")
        XCTAssertTrue(try GenotypeEditableWorkbookService.hasUnreviewedExternalEdits(in: fixture.bundleURL))
        let inspection = try service.inspect(bundleURL: fixture.bundleURL)
        XCTAssertTrue(inspection.changes.isEmpty)
        let retained = try fixture.store.applyEditableWorkbook(inspection, using: service, analysisIdentity: identity().sidecarIdentity, author: "Analyst")
        XCTAssertEqual(fixture.store.sidecar, original)
        XCTAssertEqual(fixture.store.callOverrideMutationRevision, 0)
        XCTAssertEqual(fixture.store.matrixMutationRevision, 0)
        let acceptedProvenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: fixture.provenanceURL))
        XCTAssertEqual(acceptedProvenance.argv, originalProvenance.argv)
        XCTAssertEqual(acceptedProvenance.durableReplayArgv, originalProvenance.durableReplayArgv)
        XCTAssertEqual(acceptedProvenance.options.explicit["action"], originalProvenance.options.explicit["action"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.appendingPathComponent("acceptance-provenance.json").path))
        XCTAssertFalse(try GenotypeEditableWorkbookService.hasUnreviewedExternalEdits(in: fixture.bundleURL))
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("input.xlsx")), try Data(contentsOf: workbook))
    }
    func testFirstNormalizedHomozygousH2OverrideRetainsRawBaselineAndClearsBackToEffectiveCall() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let service = try prepareEditableWorkbook(fixture, normalizedH2: true)
        let workbook = fixture.bundleURL.appendingPathComponent("current.xlsx")
        try editWorkbook(workbook, code: "w['Edit Calls']['G3']='set'; w['Edit Calls']['H3']='M2B'")
        _ = try fixture.store.applyEditableWorkbook(service.inspect(bundleURL: fixture.bundleURL), using: service, analysisIdentity: identity().sidecarIdentity, author: "Analyst")
        XCTAssertEqual(fixture.store.sidecar.callOverrides.first?.originalCall, "-")
        let analysis = GenotypeHaplotypeAnalysis(assayID: "MHC-exon2-miSeq", definitionSetID: "definition-2", definitionSetName: "Definition", speciesName: "Macaque", analysisRevisionID: "revision-7", samples: [.init(sample: "Animal-1", calls: [.init(locus: "MHC-A", sourceLocus: "MHC-A", haplotype1: "M1A", haplotype2: "-", status: .called, matchedHaplotypes: [], observedGenotypeCount: 1, observedGenotypes: [], aiMetadata: nil)])])
        let reloaded = try GenotypeAnnotationSidecar.decode(Data(contentsOf: fixture.annotationURL))
        XCTAssertEqual(GenotypeEffectiveCallAuthority.resolve(analysis: analysis, sidecar: reloaded).value(sample: "Animal-1", locus: "MHC-A", slot: .h2)?.effective, "M2B")
        _ = try prepareEditableWorkbook(fixture, normalizedH2: true)
        try editWorkbook(workbook, code: "w['Edit Calls']['G3']='clear'")
        _ = try fixture.store.applyEditableWorkbook(service.inspect(bundleURL: fixture.bundleURL), using: service, analysisIdentity: identity().sidecarIdentity, author: "Analyst")
        XCTAssertTrue(fixture.store.sidecar.callOverrides.isEmpty)
        XCTAssertEqual(GenotypeEffectiveCallAuthority.resolve(analysis: analysis, sidecar: fixture.store.sidecar).value(sample: "Animal-1", locus: "MHC-A", slot: .h2)?.effective, "M1A")
    }
    func testEditableWorkbookImportsMixedChangesPreservesInputAndAcceptanceAcrossLaterSave() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let workbook = fixture.bundleURL.appendingPathComponent("current.xlsx")
        let service = try prepareEditableWorkbook(fixture)
        try editWorkbook(workbook, code: "w['Edit Calls']['G2']='set'; w['Edit Calls']['H2']='M2A'\nfor row in w['Edit Matrix'].iter_rows(min_row=2):\n if '\"kind\": \"cell\"' in str(row[1].value):\n  row[5].value='set'; row[6].value='false-positive'; row[7].value='set'; row[8].value='Reviewed in Excel'\n")
        let bytes = try Data(contentsOf: workbook)
        XCTAssertTrue(try GenotypeEditableWorkbookService.hasUnreviewedExternalEdits(in: fixture.bundleURL))
        let inspection = try service.inspect(bundleURL: fixture.bundleURL)
        XCTAssertEqual(inspection.changes.count, 3)
        let directory = try fixture.store.applyEditableWorkbook(inspection, using: service, analysisIdentity: identity().sidecarIdentity, author: "Analyst")
        XCTAssertEqual(fixture.store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(fixture.store.sidecar.matrixReviews.first?.disposition, .falsePositive)
        XCTAssertEqual(fixture.store.sidecar.matrixComments.first?.body, "Reviewed in Excel")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("input.xlsx")), bytes)
        XCTAssertEqual(try Data(contentsOf: workbook), bytes)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("provenance.json"))) as? [String: Any])
        let inputs = try XCTUnwrap(receipt["inputs"] as? [[String: Any]])
        XCTAssertTrue(inputs.contains { ($0["path"] as? String)?.hasSuffix("baseline.json") == true })
        for input in inputs {
            let path = try XCTUnwrap(input["path"] as? String)
            XCTAssertEqual(input["sha256"] as? String, try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: path)))
        }
        for index in 1...3 {
            let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: directory.appendingPathComponent("operation-\(index)-provenance.json")))
            let output = try XCTUnwrap(envelope.steps.flatMap(\.outputs).first { $0.path.hasSuffix("operation-\(index)-annotations.json") })
            XCTAssertEqual(output.checksumSHA256, try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: output.path)))
        }
        XCTAssertFalse(try GenotypeEditableWorkbookService.hasUnreviewedExternalEdits(in: fixture.bundleURL))
        let finalEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: fixture.provenanceURL))
        XCTAssertNotNil(finalEnvelope.options.explicit["acceptedEditableWorkbook"])
        try fixture.store.upsertMatrixCommentSynchronously(body: "Further review before refresh retry", targets: [.column(sample: "Animal-1")], author: "Analyst")
        XCTAssertFalse(try GenotypeEditableWorkbookService.hasUnreviewedExternalEdits(in: fixture.bundleURL))
        try editWorkbook(workbook, code: "w['Edit Calls']['H2']='M3A'")
        XCTAssertTrue(try GenotypeEditableWorkbookService.hasUnreviewedExternalEdits(in: fixture.bundleURL))
    }

    func testEditableWorkbookChangedAfterInspectionCannotPublish() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let service = try prepareEditableWorkbook(fixture)
        let inspection = try service.inspect(bundleURL: fixture.bundleURL)
        let before = try Data(contentsOf: fixture.annotationURL)
        try editWorkbook(fixture.bundleURL.appendingPathComponent("current.xlsx"), code: "w['Reads']['B2']=999")
        XCTAssertThrowsError(try fixture.store.applyEditableWorkbook(inspection, using: service, analysisIdentity: identity().sidecarIdentity, author: "Analyst")) { error in
            XCTAssertTrue(error is GenotypeEditableWorkbookService.EditError)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.annotationURL), before)
    }

    func testWorkbookBatchRejectsMixedInvalidEditWithoutPartialPublication() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let before = try Data(contentsOf: fixture.annotationURL)
        let provenance = try Data(contentsOf: fixture.provenanceURL)
        let original = fixture.store.sidecar
        XCTAssertThrowsError(try fixture.store.bufferedWorkbookTransaction { draft in
            _ = try draft.mutateCallOverrides(self.mutations(), author: "Analyst", analysisIdentity: self.identity())
            try draft.upsertMatrixCommentSynchronously(body: "", targets: [.column(sample: "Animal-1")], author: "Analyst")
        }) { error in
            XCTAssertEqual(error as? GenotypeMatrixReviewMutationError, .emptyCommentBody)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.annotationURL), before)
        XCTAssertEqual(try Data(contentsOf: fixture.provenanceURL), provenance)
        XCTAssertEqual(fixture.store.sidecar, original)
        XCTAssertEqual(fixture.store.callOverrideMutationRevision, 0)
        XCTAssertEqual(fixture.store.matrixMutationRevision, 0)
    }

    func testWorkbookBatchCommitsCallsAndCommentInSingleVisibleRevision() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        try fixture.store.bufferedWorkbookTransaction { draft in
            _ = try draft.mutateCallOverrides(self.mutations(), author: "Analyst", analysisIdentity: self.identity())
            try draft.upsertMatrixCommentSynchronously(body: "Checked in Excel", targets: [.column(sample: "Animal-1")], author: "Analyst")
        }
        XCTAssertEqual(fixture.store.sidecar.callOverrides.count, 2)
        XCTAssertEqual(fixture.store.sidecar.matrixComments.first?.body, "Checked in Excel")
        XCTAssertEqual(fixture.store.callOverrideMutationRevision, 1)
        XCTAssertEqual(fixture.store.matrixMutationRevision, 1)
        XCTAssertEqual(try GenotypeAnnotationSidecar.decode(Data(contentsOf: fixture.annotationURL)), fixture.store.sidecar)
    }

    func testWorkbookBatchPublicationFailureRollsBackAllChanges() throws {
        let fixture = try makeStore(faultPoint: .beforeProvenancePublication)
        defer { try? FileManager.default.removeItem(at: fixture.bundleURL) }
        let before = try Data(contentsOf: fixture.annotationURL)
        let provenance = try Data(contentsOf: fixture.provenanceURL)
        XCTAssertThrowsError(try fixture.store.bufferedWorkbookTransaction { draft in
            _ = try draft.mutateCallOverrides(self.mutations(), author: "Analyst", analysisIdentity: self.identity())
            try draft.upsertMatrixCommentSynchronously(body: "Checked", targets: [.column(sample: "Animal-1")], author: "Analyst")
        }) { error in
            let transaction = error as? GenotypeAnnotationPublicationTransactionError
            XCTAssertTrue(transaction?.primaryError is InjectedCallOverrideFailure)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.annotationURL), before)
        XCTAssertEqual(try Data(contentsOf: fixture.provenanceURL), provenance)
        XCTAssertTrue(fixture.store.sidecar.callOverrides.isEmpty)
    }

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

    private var editablePython: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path) }

    private func prepareEditableWorkbook(_ fixture: Fixture, normalizedH2: Bool = false) throws -> GenotypeEditableWorkbookService {
        let workbook = fixture.bundleURL.appendingPathComponent("current.xlsx")
        let process = Process()
        process.executableURL = editablePython
        let h2 = fixture.store.sidecar.callOverrides.last(where: { $0.sample == "Animal-1" && $0.locus == "MHC-A" && $0.slot == .h2 })?.overrideCall ?? (normalizedH2 ? "M1A" : "M1B")
        let baselineH2 = normalizedH2 ? "-" : "M1B"
        process.arguments = ["-c", "import sys, json\nfrom openpyxl import Workbook\nw=Workbook(); w.active.title='Reads'; w.active.append(['Sample','Reads']); w.active.append(['Animal-1',12])\n" + GenotypeEditableWorkbookService.seedScript + "\nseed_editable_tables(w, [{'sample':'Animal-1','locus':'MHC-A','haplotype1':'M1A','haplotype2':'" + h2 + "','baselineHaplotype1':'M1A','baselineHaplotype2':'" + baselineH2 + "'}], {}, {'samples':['Animal-1'],'rows':[{'locus':'MHC-A','display_name':'G1','support_by_sample':[{'sample':'Animal-1','support':12}]}]}); w.save(sys.argv[1])", workbook.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let service = GenotypeEditableWorkbookService(pythonExecutableURL: editablePython)
        try service.attestGeneratedWorkbook(workbookURL: workbook, bundleURL: fixture.bundleURL, callEditingSupported: true)
        return service
    }

    private func editWorkbook(_ workbook: URL, code: String) throws {
        let process = Process(); process.executableURL = editablePython
        process.arguments = ["-c", "import sys\nfrom openpyxl import load_workbook\nw=load_workbook(sys.argv[1])\n" + code + "\nw.save(sys.argv[1])", workbook.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
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
