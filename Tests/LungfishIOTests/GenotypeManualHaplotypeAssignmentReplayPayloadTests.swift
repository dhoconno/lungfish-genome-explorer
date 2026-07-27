import CryptoKit
import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeManualHaplotypeAssignmentReplayPayloadTests: XCTestCase {
    func testReplayExactlyReconstructsAssignmentsAndAuditWhilePreservingUnrelatedState() throws {
        let bundleURL = URL(fileURLWithPath: "/tmp/replay-target.lungfishgenotype")
        let manifestData = Data(#"{"revision":"revision-7"}"#.utf8)
        var prior = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-26T15:00:00Z")
        prior.sampleNotes = [
            .init(
                sample: "Animal-2",
                body: "unrelated note",
                author: "reviewer",
                timestamp: "2026-07-26T15:01:00Z"
            ),
        ]
        let before = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "A-left",
            color: 2,
            alleles: ["Mafa-A1*001:01"],
            notes: "preserve me",
            id: "assignment-a-h1",
            timestamp: "2026-07-26T15:02:00Z",
            author: "First Analyst"
        )
        let unrelated = assignment(
            sample: "Animal-2",
            locus: "MHC-B",
            slot: .h2,
            label: "B-right",
            color: 8,
            alleles: ["Mafa-B*007:01"],
            notes: "other sample",
            id: "assignment-b-h2",
            timestamp: "2026-07-26T15:03:00Z",
            author: "Other Analyst"
        )
        prior.manualHaplotypeAssignments = [before, unrelated]
        let priorData = try prior.encoded()
        let after = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "A-renamed",
            color: 4,
            alleles: ["Mafa-A1*001:01"],
            notes: "preserve me",
            id: "assignment-a-h1",
            timestamp: "2026-07-26T15:04:00Z",
            author: "Replay Analyst"
        )
        let added = assignment(
            sample: "Animal-1",
            locus: "MHC-DPB",
            slot: .h2,
            label: "DPB-new",
            color: 11,
            alleles: [],
            notes: "",
            id: "assignment-dpb-h2",
            timestamp: "2026-07-26T15:04:00Z",
            author: "Replay Analyst"
        )
        let operationID = "manual-operation-001"
        let mutationAudit = audit(
            action: "updateManualHaplotypeAssignment",
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            operationID: operationID,
            priorSHA256: sha256(priorData),
            before: before,
            after: after,
            copySource: "Animal-Source"
        )
        let additionAudit = audit(
            action: "addManualHaplotypeAssignment",
            sample: "Animal-1",
            locus: "MHC-DPB",
            slot: .h2,
            operationID: operationID,
            priorSHA256: sha256(priorData),
            before: nil,
            after: added,
            copySource: "Animal-Source"
        )
        let aggregateAudit = audit(
            action: "replaceManualHaplotypeAssignments",
            sample: "Animal-1",
            locus: nil,
            slot: nil,
            operationID: operationID,
            priorSHA256: sha256(priorData),
            before: nil,
            after: nil,
            copySource: "Animal-Source"
        )
        let payload = makePayload(
            bundleURL: bundleURL,
            manifestData: manifestData,
            priorData: priorData,
            operationID: operationID,
            beforeAssignments: [before, unrelated],
            afterAssignments: [after, unrelated, added],
            audits: [mutationAudit, additionAudit, aggregateAudit],
            copySource: "Animal-Source"
        )

        let replayed = try payload.applying(
            to: priorData,
            targetBundleURL: bundleURL,
            targetManifestData: manifestData
        )

        XCTAssertEqual(replayed.manualHaplotypeAssignments, [after, unrelated, added])
        XCTAssertEqual(replayed.sampleNotes, prior.sampleNotes)
        XCTAssertEqual(
            replayed.auditLog,
            [mutationAudit, additionAudit, aggregateAudit]
        )
        XCTAssertEqual(replayed.lastEditor, "Replay Analyst")
        XCTAssertEqual(replayed.lastEditedAt, "2026-07-26T15:04:00Z")
        var expected = prior
        expected.manualHaplotypeAssignments = [after, unrelated, added]
        expected.append(audit: mutationAudit)
        expected.append(audit: additionAudit)
        expected.append(audit: aggregateAudit)
        XCTAssertEqual(replayed, expected)
        XCTAssertEqual(try replayed.encoded(), try expected.encoded())
        XCTAssertEqual(payload.operation.operationID, operationID)
        XCTAssertEqual(payload.operation.author, "Replay Analyst")
        XCTAssertEqual(payload.operation.timestamp, "2026-07-26T15:04:00Z")
        XCTAssertEqual(payload.operation.copySourceSample, "Animal-Source")
        XCTAssertEqual(payload.beforeAssignments.first, before)
        XCTAssertEqual(payload.afterAssignments.last, added)
        XCTAssertEqual(payload.auditEntries.last, aggregateAudit)
        XCTAssertEqual(
            payload.priorSidecar.descriptor.checksumSHA256,
            sha256(priorData)
        )
        XCTAssertEqual(payload.priorSidecar.revisionSHA256, sha256(priorData))
    }

    func testReplayCollapsesSelectedLegacyDuplicatesUsingTimestampAuthorityAndPreservesRawOrphansAndUnrelatedDuplicates() throws {
        let fixture = try legacyDuplicateFixture()

        let replayed = try fixture.payload.applying(
            to: fixture.priorData,
            targetBundleURL: fixture.bundleURL,
            targetManifestData: fixture.manifestData
        )

        XCTAssertEqual(
            replayed.manualHaplotypeAssignments,
            fixture.afterAssignments
        )
        XCTAssertEqual(
            replayed.manualHaplotypeAssignments.filter {
                $0.sample == "Animal-2"
            },
            fixture.unrelatedAssignments
        )
        XCTAssertEqual(
            replayed.auditLog.first?.manualHaplotypeAssignment?.before,
            fixture.authoritativeBefore
        )
        XCTAssertEqual(
            replayed.auditLog.first?.action,
            "updateManualHaplotypeAssignment"
        )
        XCTAssertEqual(
            replayed.manualHaplotypeAssignments.filter {
                $0.sample == "Animal-1"
                    && GenotypeManualHaplotypeLocus(
                        normalizing: $0.locus
                    ) == nil
            },
            [fixture.selectedOrphan]
        )
    }

    func testReplayCanonicalizesWhitespaceAndDecomposedSelectedSampleIdentityWhilePreservingOrphanAndUnrelatedRecords() throws {
        let bundleURL = URL(
            fileURLWithPath:
                "/tmp/replay-legacy-sample-identity.lungfishgenotype"
        )
        let manifestData = Data(#"{"revision":"legacy-sample"}"#.utf8)
        let canonicalSample = "\u{00C1}nimal-1"
        let legacySample = "  A\u{0301}nimal-1  "
        let legacy = assignment(
            sample: legacySample,
            locus: "MHC-A",
            slot: .h1,
            label: "Legacy-A",
            color: 2,
            alleles: ["Mafa-A1*001:01"],
            notes: "preserve legacy metadata",
            id: "legacy-a-id",
            timestamp: "2026-07-26T15:02:00Z",
            author: "Legacy Analyst"
        )
        let selectedOrphan = assignment(
            sample: legacySample,
            locus: "MHC-OPAQUE",
            slot: .h2,
            label: "Opaque",
            color: 8,
            alleles: ["opaque"],
            notes: "preserve exact orphan",
            id: nil,
            timestamp: "not-a-date",
            author: "Legacy Analyst"
        )
        let unrelated = assignment(
            sample: "Animal-2",
            locus: "MHC-B",
            slot: .h1,
            label: "Other",
            color: 4,
            alleles: ["other"],
            notes: "unrelated exact",
            id: "other-id",
            timestamp: "2026-07-26T15:03:00Z",
            author: "Other Analyst"
        )
        var prior = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T15:00:00Z"
        )
        prior.manualHaplotypeAssignments = [
            legacy,
            selectedOrphan,
            unrelated,
        ]
        let priorData = try prior.encoded()
        let canonical = assignment(
            sample: canonicalSample,
            locus: "MHC-A",
            slot: .h1,
            label: legacy.label,
            color: legacy.colorTokenIndex,
            alleles: legacy.diagnosticAlleles,
            notes: legacy.notes,
            id: legacy.assignmentID,
            timestamp: "2026-07-26T15:04:00Z",
            author: "Replay Analyst"
        )
        let operationID = "legacy-sample-operation"
        let detail = audit(
            action: "updateManualHaplotypeAssignment",
            sample: canonicalSample,
            locus: "MHC-A",
            slot: .h1,
            operationID: operationID,
            priorSHA256: sha256(priorData),
            before: legacy,
            after: canonical,
            copySource: nil
        )
        let aggregate = audit(
            action: "replaceManualHaplotypeAssignments",
            sample: canonicalSample,
            locus: nil,
            slot: nil,
            operationID: operationID,
            priorSHA256: sha256(priorData),
            before: nil,
            after: nil,
            copySource: nil
        )
        let after = [unrelated, selectedOrphan, canonical]
        let payload = makePayload(
            bundleURL: bundleURL,
            manifestData: manifestData,
            priorData: priorData,
            operationID: operationID,
            operationSample: canonicalSample,
            beforeAssignments: prior.manualHaplotypeAssignments,
            afterAssignments: after,
            audits: [detail, aggregate],
            copySource: nil
        )

        let replayed = try payload.applying(
            to: priorData,
            targetBundleURL: bundleURL,
            targetManifestData: manifestData
        )

        XCTAssertEqual(replayed.manualHaplotypeAssignments, after)
        XCTAssertEqual(
            replayed.manualHaplotypeAssignments[1],
            selectedOrphan
        )
        XCTAssertEqual(replayed.auditLog, [detail, aggregate])
    }

    func testReplayCanonicalizesAliasAndCreatesMissingAssignmentIDWithoutLabelOrColorChange() throws {
        let bundleURL = URL(
            fileURLWithPath: "/tmp/replay-legacy-alias.lungfishgenotype"
        )
        let manifestData = Data(#"{"revision":"legacy-alias"}"#.utf8)
        let legacy = assignment(
            sample: "Animal-1",
            locus: "A",
            slot: .h1,
            label: "unchanged",
            color: 4,
            alleles: ["Mafa-A1*001:01"],
            notes: "preserve legacy metadata",
            id: nil,
            timestamp: "2026-07-26T15:02:00Z",
            author: "Legacy Analyst"
        )
        var prior = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T15:00:00Z"
        )
        prior.manualHaplotypeAssignments = [legacy]
        let priorData = try prior.encoded()
        let canonical = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: legacy.label,
            color: legacy.colorTokenIndex,
            alleles: legacy.diagnosticAlleles,
            notes: legacy.notes,
            id: "migrated-assignment-id",
            timestamp: "2026-07-26T15:04:00Z",
            author: "Replay Analyst"
        )
        let operationID = "legacy-alias-operation"
        let detail = audit(
            action: "updateManualHaplotypeAssignment",
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            operationID: operationID,
            priorSHA256: sha256(priorData),
            before: legacy,
            after: canonical,
            copySource: nil
        )
        let aggregate = audit(
            action: "replaceManualHaplotypeAssignments",
            sample: "Animal-1",
            locus: nil,
            slot: nil,
            operationID: operationID,
            priorSHA256: sha256(priorData),
            before: nil,
            after: nil,
            copySource: nil
        )
        let payload = makePayload(
            bundleURL: bundleURL,
            manifestData: manifestData,
            priorData: priorData,
            operationID: operationID,
            beforeAssignments: [legacy],
            afterAssignments: [canonical],
            audits: [detail, aggregate],
            copySource: nil
        )

        let replayed = try payload.applying(
            to: priorData,
            targetBundleURL: bundleURL,
            targetManifestData: manifestData
        )

        XCTAssertEqual(replayed.manualHaplotypeAssignments, [canonical])
        XCTAssertEqual(
            replayed.auditLog.first?.manualHaplotypeAssignment?.before,
            legacy
        )
        XCTAssertEqual(
            replayed.auditLog.first?.manualHaplotypeAssignment?.after,
            canonical
        )
    }

    func testReplayRejectsLegacyCanonicalizationAuditThatDoesNotUseEffectiveWinner() throws {
        let fixture = try legacyDuplicateFixture()
        let nonAuthoritativeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    fixture.nonAuthoritativeBefore
                )
            ) as? [String: Any]
        )
        let contradictory = try mutatedPayload(fixture.payload) { object in
            Self.mutateArray("auditEntries", in: &object) { audits in
                var audit = audits[0] as! [String: Any]
                var structured =
                    audit["manualHaplotypeAssignment"] as! [String: Any]
                structured["before"] = nonAuthoritativeObject
                audit["manualHaplotypeAssignment"] = structured
                audits[0] = audit
            }
        }

        XCTAssertThrowsError(
            try contradictory.applying(
                to: fixture.priorData,
                targetBundleURL: fixture.bundleURL,
                targetManifestData: fixture.manifestData
            )
        ) { error in
            guard case .invalidOperation(let reason) =
                    error as? GenotypeManualHaplotypeAssignmentReplayPayload
                        .ReplayError else {
                return XCTFail("Expected invalid operation, got \(error)")
            }
            XCTAssertTrue(reason.contains("detailed audit"), reason)
        }
    }

    func testReplayRejectsContradictoryAggregateOperationPayloads() throws {
        let fixture = try coherentValidationFixture()
        let cases: [(
            name: String,
            mutate: (inout [String: Any]) -> Void
        )] = [
            ("empty operation ID", { object in
                Self.mutateDictionary("operation", in: &object) {
                    $0["operationID"] = "   "
                }
            }),
            ("repeated operation ID", { object in
                Self.mutateDictionary("operation", in: &object) {
                    $0["operationID"] = "existing-operation"
                }
                Self.mutateAuditPayloads(in: &object) {
                    $0["operationID"] = "existing-operation"
                }
            }),
            ("unrelated sample changed", { object in
                Self.mutateArray("afterAssignments", in: &object) { records in
                    var record = records[2] as! [String: Any]
                    record["label"] = "tampered unrelated"
                    records[2] = record
                }
            }),
            ("duplicate canonical key", { object in
                Self.mutateArray("afterAssignments", in: &object) { records in
                    records.append(records[0])
                }
            }),
            ("invalid changed label", { object in
                Self.mutateArray("afterAssignments", in: &object) { records in
                    var record = records[0] as! [String: Any]
                    record["label"] = "\u{0001}"
                    records[0] = record
                }
            }),
            ("missing detailed audit", { object in
                Self.mutateArray("auditEntries", in: &object) { audits in
                    audits.removeFirst()
                }
            }),
            ("duplicate detailed audit", { object in
                Self.mutateArray("auditEntries", in: &object) { audits in
                    audits.insert(audits[0], at: 0)
                }
            }),
            ("wrong detailed action", { object in
                Self.mutateArray("auditEntries", in: &object) { audits in
                    var audit = audits[0] as! [String: Any]
                    audit["action"] = "removeManualHaplotypeAssignment"
                    audits[0] = audit
                }
            }),
            ("wrong detailed author", { object in
                Self.mutateArray("auditEntries", in: &object) { audits in
                    var audit = audits[0] as! [String: Any]
                    audit["author"] = "Other Analyst"
                    audits[0] = audit
                }
            }),
            ("no-op operation", { object in
                object["afterAssignments"] = object["beforeAssignments"]
            }),
        ]

        for testCase in cases {
            let payload = try mutatedPayload(
                fixture.payload,
                mutation: testCase.mutate
            )
            XCTAssertThrowsError(
                try payload.applying(
                    to: fixture.priorData,
                    targetBundleURL: fixture.bundleURL,
                    targetManifestData: fixture.manifestData
                ),
                testCase.name
            )
        }
    }

    func testReplayRejectsAssignmentMetadataThatViolatesReplacementRules() throws {
        let fixture = try coherentValidationFixture()
        let cases: [(
            name: String,
            assignmentIndex: Int,
            field: String,
            value: Any
        )] = [
            ("update changes diagnostic alleles", 0, "diagnosticAlleles", ["other"]),
            ("update changes notes", 0, "notes", "changed note"),
            ("update changes assignment ID", 0, "assignmentID", "different-id"),
            ("update author differs from operation", 0, "author", "Other Analyst"),
            ("update timestamp differs from operation", 0, "updatedAt", "2026-07-26T16:00:00Z"),
            ("new assignment has diagnostic alleles", 1, "diagnosticAlleles", ["not-empty"]),
            ("new assignment has notes", 1, "notes", "not empty"),
        ]

        for testCase in cases {
            let payload = try mutatedPayload(fixture.payload) { object in
                Self.mutateArray("afterAssignments", in: &object) { records in
                    var record = records[testCase.assignmentIndex] as! [String: Any]
                    record[testCase.field] = testCase.value
                    records[testCase.assignmentIndex] = record
                }
                Self.mutateArray("auditEntries", in: &object) { audits in
                    var audit = audits[testCase.assignmentIndex] as! [String: Any]
                    var structured = audit["manualHaplotypeAssignment"] as! [String: Any]
                    var after = structured["after"] as! [String: Any]
                    after[testCase.field] = testCase.value
                    structured["after"] = after
                    audit["manualHaplotypeAssignment"] = structured
                    audits[testCase.assignmentIndex] = audit
                }
            }
            XCTAssertThrowsError(
                try payload.applying(
                    to: fixture.priorData,
                    targetBundleURL: fixture.bundleURL,
                    targetManifestData: fixture.manifestData
                ),
                testCase.name
            )
        }
    }

    func testReplayRejectsEmptyOrUnnormalizedAggregateMetadata() throws {
        let fixture = try coherentValidationFixture()
        let cases: [(
            name: String,
            field: String,
            value: String
        )] = [
            ("empty author", "author", "   "),
            ("invalid timestamp", "timestamp", "not-a-timestamp"),
            ("empty copy source", "copySourceSample", "   "),
        ]

        for testCase in cases {
            let payload = try mutatedPayload(fixture.payload) { object in
                Self.mutateDictionary("operation", in: &object) {
                    $0[testCase.field] = testCase.value
                }
                if testCase.field == "author" || testCase.field == "timestamp" {
                    Self.mutateArray("afterAssignments", in: &object) { records in
                        for index in records.indices {
                            var record = records[index] as! [String: Any]
                            guard record["sample"] as? String == "Animal-1" else {
                                continue
                            }
                            let assignmentField =
                                testCase.field == "timestamp" ? "updatedAt" : "author"
                            record[assignmentField] = testCase.value
                            records[index] = record
                        }
                    }
                    Self.mutateArray("auditEntries", in: &object) { audits in
                        for index in audits.indices {
                            var audit = audits[index] as! [String: Any]
                            audit[testCase.field] = testCase.value
                            if var structured =
                                audit["manualHaplotypeAssignment"] as? [String: Any],
                               var after = structured["after"] as? [String: Any] {
                                let assignmentField =
                                    testCase.field == "timestamp"
                                    ? "updatedAt" : "author"
                                after[assignmentField] = testCase.value
                                structured["after"] = after
                                audit["manualHaplotypeAssignment"] = structured
                            }
                            audits[index] = audit
                        }
                    }
                } else {
                    Self.mutateAuditPayloads(in: &object) {
                        $0["copySourceSample"] = testCase.value
                    }
                }
            }
            XCTAssertThrowsError(
                try payload.applying(
                    to: fixture.priorData,
                    targetBundleURL: fixture.bundleURL,
                    targetManifestData: fixture.manifestData
                ),
                testCase.name
            )
        }
    }

    func testReplayRejectsPriorSidecarHashMismatch() throws {
        let fixture = try fixture()
        var changedPrior = fixture.prior
        changedPrior.sampleNotes.append(.init(
            sample: "Animal-9",
            body: "concurrent",
            author: "other",
            timestamp: "2026-07-26T15:05:00Z"
        ))
        let changedData = try changedPrior.encoded()

        XCTAssertThrowsError(
            try fixture.payload.applying(
                to: changedData,
                targetBundleURL: fixture.bundleURL,
                targetManifestData: fixture.manifestData
            )
        ) { error in
            guard case .priorSidecarChecksumMismatch? =
                    error as? GenotypeManualHaplotypeAssignmentReplayPayload.ReplayError else {
                return XCTFail("Expected prior-sidecar checksum mismatch, got \(error)")
            }
        }
    }

    func testReplayRejectsPriorSidecarRevisionMismatchEvenWhenDescriptorMatches() throws {
        let fixture = try fixture()
        var payloadObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try fixture.payload.encoded())
                as? [String: Any]
        )
        var priorIdentity = try XCTUnwrap(
            payloadObject["priorSidecar"] as? [String: Any]
        )
        priorIdentity["revisionSHA256"] = String(repeating: "0", count: 64)
        payloadObject["priorSidecar"] = priorIdentity
        let mismatched = try GenotypeManualHaplotypeAssignmentReplayPayload.decode(
            JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
        )

        XCTAssertThrowsError(
            try mismatched.applying(
                to: fixture.priorData,
                targetBundleURL: fixture.bundleURL,
                targetManifestData: fixture.manifestData
            )
        ) { error in
            guard case .priorSidecarRevisionMismatch? =
                    error as? GenotypeManualHaplotypeAssignmentReplayPayload.ReplayError else {
                return XCTFail("Expected prior-sidecar revision mismatch, got \(error)")
            }
        }
    }

    func testReplayRejectsTargetBundleRevisionMismatch() throws {
        let fixture = try fixture()
        let newerManifest = Data(#"{"revision":"revision-8"}"#.utf8)

        XCTAssertThrowsError(
            try fixture.payload.applying(
                to: fixture.priorData,
                targetBundleURL: fixture.bundleURL,
                targetManifestData: newerManifest
            )
        ) { error in
            guard case .targetManifestChecksumMismatch? =
                    error as? GenotypeManualHaplotypeAssignmentReplayPayload.ReplayError else {
                return XCTFail("Expected target manifest revision mismatch, got \(error)")
            }
        }
    }

    func testReplayRejectsFuturePayloadAndSidecarSchemas() throws {
        let fixture = try fixture()
        var payloadObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try fixture.payload.encoded())
                as? [String: Any]
        )
        payloadObject["schemaVersion"] =
            GenotypeManualHaplotypeAssignmentReplayPayload.currentSchemaVersion + 1
        let futurePayloadData = try JSONSerialization.data(
            withJSONObject: payloadObject,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try GenotypeManualHaplotypeAssignmentReplayPayload.decode(futurePayloadData)
        ) { error in
            XCTAssertEqual(
                error as? GenotypeManualHaplotypeAssignmentReplayPayload.ReplayError,
                .unsupportedSchemaVersion(
                    GenotypeManualHaplotypeAssignmentReplayPayload.currentSchemaVersion + 1
                )
            )
        }

        var futureSidecar = fixture.prior
        futureSidecar.schemaVersion = GenotypeAnnotationSidecar.currentSchemaVersion + 1
        let futureSidecarData = try futureSidecar.encoded()
        let futurePayload = makePayload(
            bundleURL: fixture.bundleURL,
            manifestData: fixture.manifestData,
            priorData: futureSidecarData,
            operationID: "future-sidecar-operation",
            beforeAssignments: futureSidecar.manualHaplotypeAssignments,
            afterAssignments: futureSidecar.manualHaplotypeAssignments,
            audits: [],
            copySource: nil
        )
        XCTAssertThrowsError(
            try futurePayload.applying(
                to: futureSidecarData,
                targetBundleURL: fixture.bundleURL,
                targetManifestData: fixture.manifestData
            )
        ) { error in
            XCTAssertEqual(
                error as? GenotypeAnnotationSidecar.SchemaMutationError,
                .unsupportedFutureSchemaVersion(
                    found: GenotypeAnnotationSidecar.currentSchemaVersion + 1,
                    current: GenotypeAnnotationSidecar.currentSchemaVersion
                )
            )
        }
    }

    private func fixture() throws -> (
        payload: GenotypeManualHaplotypeAssignmentReplayPayload,
        bundleURL: URL,
        manifestData: Data,
        prior: GenotypeAnnotationSidecar,
        priorData: Data
    ) {
        let bundleURL = URL(fileURLWithPath: "/tmp/replay-target.lungfishgenotype")
        let manifestData = Data(#"{"revision":"revision-7"}"#.utf8)
        var prior = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-26T15:00:00Z")
        let before = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "before",
            color: 1,
            alleles: ["A*001"],
            notes: "note",
            id: "assignment-1",
            timestamp: "2026-07-26T15:01:00Z",
            author: "First Analyst"
        )
        let after = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "after",
            color: 2,
            alleles: ["A*001"],
            notes: "note",
            id: "assignment-1",
            timestamp: "2026-07-26T15:04:00Z",
            author: "Replay Analyst"
        )
        prior.manualHaplotypeAssignments = [before]
        let priorData = try prior.encoded()
        let payload = makePayload(
            bundleURL: bundleURL,
            manifestData: manifestData,
            priorData: priorData,
            operationID: "manual-operation-001",
            beforeAssignments: [before],
            afterAssignments: [after],
            audits: [],
            copySource: nil
        )
        return (payload, bundleURL, manifestData, prior, priorData)
    }

    private func coherentValidationFixture() throws -> (
        payload: GenotypeManualHaplotypeAssignmentReplayPayload,
        bundleURL: URL,
        manifestData: Data,
        priorData: Data
    ) {
        let bundleURL = URL(fileURLWithPath: "/tmp/replay-validation.lungfishgenotype")
        let manifestData = Data(#"{"revision":"revision-validation"}"#.utf8)
        let updateBefore = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "before",
            color: 1,
            alleles: ["Mafa-A1*001:01"],
            notes: "preserved",
            id: "assignment-update",
            timestamp: "2026-07-26T15:00:00Z",
            author: "First Analyst"
        )
        let updateAfter = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "after",
            color: 2,
            alleles: ["Mafa-A1*001:01"],
            notes: "preserved",
            id: "assignment-update",
            timestamp: "2026-07-26T15:04:00Z",
            author: "Replay Analyst"
        )
        let addition = assignment(
            sample: "Animal-1",
            locus: "MHC-DPB",
            slot: .h2,
            label: "new",
            color: 3,
            alleles: [],
            notes: "",
            id: "assignment-new",
            timestamp: "2026-07-26T15:04:00Z",
            author: "Replay Analyst"
        )
        let unrelated = assignment(
            sample: "Animal-2",
            locus: "MHC-B",
            slot: .h2,
            label: "unrelated",
            color: 4,
            alleles: ["Mafa-B*001:01"],
            notes: "other",
            id: "assignment-other",
            timestamp: "2026-07-26T14:00:00Z",
            author: "Other Analyst"
        )
        var prior = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T14:00:00Z"
        )
        prior.manualHaplotypeAssignments = [updateBefore, unrelated]
        prior.auditLog = [
            audit(
                action: "replaceManualHaplotypeAssignments",
                sample: "Animal-9",
                locus: nil,
                slot: nil,
                operationID: "existing-operation",
                priorSHA256: String(repeating: "e", count: 64),
                before: nil,
                after: nil,
                copySource: nil
            ),
        ]
        let priorData = try prior.encoded()
        let operationID = "validation-operation"
        let audits = [
            audit(
                action: "updateManualHaplotypeAssignment",
                sample: "Animal-1",
                locus: "MHC-A",
                slot: .h1,
                operationID: operationID,
                priorSHA256: sha256(priorData),
                before: updateBefore,
                after: updateAfter,
                copySource: "Animal-Source"
            ),
            audit(
                action: "addManualHaplotypeAssignment",
                sample: "Animal-1",
                locus: "MHC-DPB",
                slot: .h2,
                operationID: operationID,
                priorSHA256: sha256(priorData),
                before: nil,
                after: addition,
                copySource: "Animal-Source"
            ),
            audit(
                action: "replaceManualHaplotypeAssignments",
                sample: "Animal-1",
                locus: nil,
                slot: nil,
                operationID: operationID,
                priorSHA256: sha256(priorData),
                before: nil,
                after: nil,
                copySource: "Animal-Source"
            ),
        ]
        return (
            makePayload(
                bundleURL: bundleURL,
                manifestData: manifestData,
                priorData: priorData,
                operationID: operationID,
                beforeAssignments: [updateBefore, unrelated],
                afterAssignments: [updateAfter, addition, unrelated],
                audits: audits,
                copySource: "Animal-Source"
            ),
            bundleURL,
            manifestData,
            priorData
        )
    }

    private func legacyDuplicateFixture() throws -> (
        payload: GenotypeManualHaplotypeAssignmentReplayPayload,
        bundleURL: URL,
        manifestData: Data,
        priorData: Data,
        authoritativeBefore: ManualHaplotypeAssignment,
        nonAuthoritativeBefore: ManualHaplotypeAssignment,
        selectedOrphan: ManualHaplotypeAssignment,
        afterAssignments: [ManualHaplotypeAssignment],
        unrelatedAssignments: [ManualHaplotypeAssignment]
    ) {
        let bundleURL = URL(
            fileURLWithPath: "/tmp/replay-legacy-duplicates.lungfishgenotype"
        )
        let manifestData = Data(#"{"revision":"legacy-duplicates"}"#.utf8)
        let older = assignment(
            sample: "Animal-1",
            locus: "A",
            slot: .h1,
            label: "older",
            color: 1,
            alleles: ["older-allele"],
            notes: "older metadata",
            id: "older-id",
            timestamp: "2026-07-26T15:01:00Z",
            author: "Legacy Analyst"
        )
        let winner = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "authoritative",
            color: 3,
            alleles: ["winner-allele"],
            notes: "winner metadata",
            id: "winner-id",
            timestamp: "2026-07-26T15:03:00Z",
            author: "Legacy Analyst"
        )
        let unrelatedOlder = assignment(
            sample: "Animal-2",
            locus: "B",
            slot: .h2,
            label: "unrelated older",
            color: 5,
            alleles: ["unrelated-old"],
            notes: "raw older",
            id: "unrelated-old-id",
            timestamp: "2026-07-26T14:00:00Z",
            author: "Other Analyst"
        )
        let unrelatedNewer = assignment(
            sample: "Animal-2",
            locus: "MHC-B",
            slot: .h2,
            label: "unrelated newer",
            color: 6,
            alleles: ["unrelated-new"],
            notes: "raw newer",
            id: "unrelated-new-id",
            timestamp: "2026-07-26T14:30:00Z",
            author: "Other Analyst"
        )
        let selectedOrphan = assignment(
            sample: "Animal-1",
            locus: "MHC-LEGACY-ORPHAN",
            slot: .h2,
            label: "opaque orphan",
            color: 17,
            alleles: ["opaque-allele"],
            notes: "must remain byte-for-byte model exact",
            id: nil,
            timestamp: "not-a-date",
            author: "Legacy Analyst"
        )
        var prior = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T14:00:00Z"
        )
        prior.manualHaplotypeAssignments = [
            older,
            unrelatedOlder,
            selectedOrphan,
            winner,
            unrelatedNewer,
        ]
        let priorData = try prior.encoded()
        let canonicalWinner = assignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: winner.label,
            color: winner.colorTokenIndex,
            alleles: winner.diagnosticAlleles,
            notes: winner.notes,
            id: winner.assignmentID,
            timestamp: "2026-07-26T15:04:00Z",
            author: "Replay Analyst"
        )
        let afterAssignments = [
            unrelatedOlder,
            selectedOrphan,
            canonicalWinner,
            unrelatedNewer,
        ]
        let operationID = "legacy-duplicate-operation"
        let detail = audit(
            action: "updateManualHaplotypeAssignment",
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            operationID: operationID,
            priorSHA256: sha256(priorData),
            before: winner,
            after: canonicalWinner,
            copySource: nil
        )
        let aggregate = audit(
            action: "replaceManualHaplotypeAssignments",
            sample: "Animal-1",
            locus: nil,
            slot: nil,
            operationID: operationID,
            priorSHA256: sha256(priorData),
            before: nil,
            after: nil,
            copySource: nil
        )
        return (
            makePayload(
                bundleURL: bundleURL,
                manifestData: manifestData,
                priorData: priorData,
                operationID: operationID,
                beforeAssignments: prior.manualHaplotypeAssignments,
                afterAssignments: afterAssignments,
                audits: [detail, aggregate],
                copySource: nil
            ),
            bundleURL,
            manifestData,
            priorData,
            winner,
            older,
            selectedOrphan,
            afterAssignments,
            [unrelatedOlder, unrelatedNewer]
        )
    }

    private func mutatedPayload(
        _ payload: GenotypeManualHaplotypeAssignmentReplayPayload,
        mutation: (inout [String: Any]) -> Void
    ) throws -> GenotypeManualHaplotypeAssignmentReplayPayload {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try payload.encoded())
                as? [String: Any]
        )
        mutation(&object)
        return try GenotypeManualHaplotypeAssignmentReplayPayload.decode(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private static func mutateDictionary(
        _ key: String,
        in object: inout [String: Any],
        mutation: (inout [String: Any]) -> Void
    ) {
        var dictionary = object[key] as! [String: Any]
        mutation(&dictionary)
        object[key] = dictionary
    }

    private static func mutateArray(
        _ key: String,
        in object: inout [String: Any],
        mutation: (inout [Any]) -> Void
    ) {
        var array = object[key] as! [Any]
        mutation(&array)
        object[key] = array
    }

    private static func mutateAuditPayloads(
        in object: inout [String: Any],
        mutation: (inout [String: Any]) -> Void
    ) {
        mutateArray("auditEntries", in: &object) { audits in
            for index in audits.indices {
                var audit = audits[index] as! [String: Any]
                var structured =
                    audit["manualHaplotypeAssignment"] as! [String: Any]
                mutation(&structured)
                audit["manualHaplotypeAssignment"] = structured
                audits[index] = audit
            }
        }
    }

    private func makePayload(
        bundleURL: URL,
        manifestData: Data,
        priorData: Data,
        operationID: String,
        operationSample: String = "Animal-1",
        beforeAssignments: [ManualHaplotypeAssignment],
        afterAssignments: [ManualHaplotypeAssignment],
        audits: [GenotypeAnnotationSidecar.AuditEntry],
        copySource: String?
    ) -> GenotypeManualHaplotypeAssignmentReplayPayload {
        let manifestPath = ONTGenotypeResultBundleManifest.filename
        let sidecarPath = GenotypeAnnotationSidecar.filename
        return GenotypeManualHaplotypeAssignmentReplayPayload(
            operation: .init(
                operationID: operationID,
                sample: operationSample,
                author: "Replay Analyst",
                timestamp: "2026-07-26T15:04:00Z",
                copySourceSample: copySource
            ),
            targetBundle: .init(
                bundlePath: bundleURL.standardizedFileURL.path,
                manifest: .init(
                    path: manifestPath,
                    checksumSHA256: sha256(manifestData),
                    fileSize: UInt64(manifestData.count)
                )
            ),
            priorSidecar: .init(
                descriptor: .init(
                    path: sidecarPath,
                    checksumSHA256: sha256(priorData),
                    fileSize: UInt64(priorData.count)
                ),
                revisionSHA256: sha256(priorData)
            ),
            beforeAssignments: beforeAssignments,
            afterAssignments: afterAssignments,
            auditEntries: audits
        )
    }

    private func assignment(
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        label: String,
        color: Int,
        alleles: [String],
        notes: String,
        id: String?,
        timestamp: String,
        author: String
    ) -> ManualHaplotypeAssignment {
        ManualHaplotypeAssignment(
            sample: sample,
            locus: locus,
            slot: slot,
            label: label,
            colorTokenIndex: color,
            diagnosticAlleles: alleles,
            notes: notes,
            assignmentID: id,
            updatedAt: timestamp,
            author: author
        )
    }

    private func audit(
        action: String,
        sample: String,
        locus: String?,
        slot: HaplotypeSlot?,
        operationID: String,
        priorSHA256: String,
        before: ManualHaplotypeAssignment?,
        after: ManualHaplotypeAssignment?,
        copySource: String?
    ) -> GenotypeAnnotationSidecar.AuditEntry {
        GenotypeAnnotationSidecar.AuditEntry(
            action: action,
            sample: sample,
            locus: locus,
            slot: slot,
            before: before?.label,
            after: after?.label,
            color: after.map { String($0.colorTokenIndex) },
            reason: "manual-haplotype-assignment",
            rationale: "replay fixture",
            author: "Replay Analyst",
            timestamp: "2026-07-26T15:04:00Z",
            manualHaplotypeAssignment: .init(
                operationID: operationID,
                priorSidecarSHA256: priorSHA256,
                before: before,
                after: after,
                copySourceSample: copySource
            )
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
