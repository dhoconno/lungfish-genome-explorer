import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AIHaplotypingPatchValidatorTests: XCTestCase {
    func testValidatorAcceptsClosedEvidencePatchAndNormalizesCall() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    supportEvidenceRefs: ["obs:DW472:MHC-B:12_M9_B_001_01"],
                    counterevidenceRefs: ["sample:DW472"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator().validate(result, registry: registry)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        XCTAssertEqual(report.normalizedCalls[0].patchOpID, "patch-001")
        XCTAssertEqual(report.normalizedCalls[0].sample, "DW472")
        XCTAssertEqual(report.normalizedCalls[0].locus, "MHC-B")
        XCTAssertEqual(report.normalizedCalls[0].slot, "h1")
        XCTAssertEqual(report.normalizedCalls[0].status, .called)
        XCTAssertEqual(report.normalizedCalls[0].primaryHaplotypeLabel, "M9B")
        XCTAssertEqual(report.normalizedCalls[0].proposedHaplotypeLabel, "M9B")
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.source, .ai)
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.reviewState, .needsReview)
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.supportEvidenceRefs, ["obs:DW472:MHC-B:12_M9_B_001_01"])
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.counterevidenceRefs, ["sample:DW472"])
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.provenancePath, AIHaplotypingPatchValidator.pendingProvenancePath)
        XCTAssertEqual(report.run, result.run)
        XCTAssertEqual(report.chunkID, "chunk-0001")
        XCTAssertEqual(report.registryDigest, registry.digest)
        XCTAssertEqual(report.inputSnapshotDigest, registry.inputSnapshotDigest)
        XCTAssertEqual(try JSONDecoder().decode(AIHaplotypingValidationReport.self, from: JSONEncoder().encode(report)), report)
    }

    func testRejectsUnknownEvidenceID() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(supportEvidenceRefs: ["obs:hallucinated"], counterevidenceRefs: ["sample:DW472"])
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.unknownEvidenceID("obs:hallucinated")])
        XCTAssertEqual(report.normalizedCalls, [])
        XCTAssertEqual(report.run, result.run)
        XCTAssertEqual(report.chunkID, "chunk-0001")
        XCTAssertEqual(report.registryDigest, registry.digest)
        XCTAssertEqual(report.inputSnapshotDigest, registry.inputSnapshotDigest)
    }

    func testRejectsDuplicateSlotPatchForSameSampleLocusSlot() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(patchOpID: "patch-001", slot: "h1"),
                makeCall(patchOpID: "patch-002", slot: "h1", haplotypeLabel: "M8B"),
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.duplicateCallTarget("DW472", "MHC-B", "h1")])
    }

    func testRejectsCalledPatchWithoutSubstantiveSupportEvidence() throws {
        let registry = makeRegistry()

        let emptySupport = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(supportEvidenceRefs: [], counterevidenceRefs: ["sample:DW472"])
            ]
        ))
        XCTAssertEqual(emptySupport.errors, [.missingSupportEvidence("patch-001")])

        let cohortOnlySupport = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    supportEvidenceRefs: ["cohort:MHC-A:M7"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        ))
        XCTAssertEqual(cohortOnlySupport.errors, [.missingSupportEvidence("patch-001")])
    }

    func testRejectsPositiveReviewableLabelsWithoutSubstantiveSupportEvidence() throws {
        let registry = makeRegistry()

        for callState in [GenotypeHaplotypeAICallState.novelCandidate, .ambiguousTie] {
            let report = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
                registry: registry,
                calls: [
                    makeCall(
                        callState: callState,
                        supportEvidenceRefs: [],
                        counterevidenceRefs: ["sample:DW472"]
                    )
                ]
            ))
            XCTAssertEqual(report.errors, [.missingSupportEvidence("patch-001")])
        }
    }

    func testBlankValidatorProvenancePathFallsBackToPendingPlaceholder() throws {
        let registry = makeRegistry()
        let result = makeResult(registry: registry, calls: [makeCall()])

        let report = AIHaplotypingPatchValidator(
            registry: registry,
            provenancePath: " \n "
        ).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.provenancePath, AIHaplotypingPatchValidator.pendingProvenancePath)
    }

    func testExpectedRunAndChunkMetadataAreValidated() throws {
        let registry = makeRegistry()
        let result = makeResult(registry: registry, calls: [makeCall()])

        let matching = AIHaplotypingPatchValidator(registry: registry).validate(
            result,
            registry: registry,
            expectedRun: result.run,
            expectedChunkID: "chunk-0001"
        )
        XCTAssertTrue(matching.accepted)

        let mismatchedRun = AIHaplotypingRunMetadata(
            mode: result.run.mode,
            promptTemplateID: result.run.promptTemplateID,
            promptTemplateVersion: result.run.promptTemplateVersion,
            promptHash: "sha256:\(String(repeating: "9", count: 64))",
            provider: result.run.provider,
            model: result.run.model,
            generationParameters: result.run.generationParameters,
            parentRevisionID: result.run.parentRevisionID,
            registryDigest: result.run.registryDigest,
            inputSnapshotDigest: result.run.inputSnapshotDigest
        )
        let runMismatch = AIHaplotypingPatchValidator(registry: registry).validate(
            result,
            registry: registry,
            expectedRun: mismatchedRun
        )
        XCTAssertEqual(runMismatch.errors, [.runMetadataMismatch("promptHash")])

        let chunkMismatch = AIHaplotypingPatchValidator(registry: registry).validate(
            result,
            registry: registry,
            expectedChunkID: "chunk-9999"
        )
        XCTAssertEqual(chunkMismatch.errors, [.chunkIDMismatch(expected: "chunk-9999", actual: "chunk-0001")])
    }

    func testStrictJSONSchemaClosesObjectsAndBoundsArrays() throws {
        let schema = AIHaplotypingResultSchema.jsonSchema()

        XCTAssertNoThrow(try assertClosedSchema(JSONValue.object(schema), context: "$"))
        XCTAssertFalse(containsForbiddenSchemaProperty(JSONValue.object(schema)))

        let root = try XCTUnwrap(schema.object("properties"))
        XCTAssertNotNil(root["schemaVersion"])
        XCTAssertNotNil(root["registryDigest"])
        XCTAssertNotNil(root["inputSnapshotDigest"])
        let runProperties = try XCTUnwrap(root["run"]?.objectValue?.object("properties"))
        let generationParameters = try XCTUnwrap(runProperties["generationParameters"]?.objectValue)
        XCTAssertNil(generationParameters["patternProperties"])
    }

    func testRejectsUnknownSampleLocusAndMismatchedEvidenceTargetsUnlessCohortRecurrence() throws {
        let registry = makeRegistry()

        let unknownTarget = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(sample: "DW999", locus: "MHC-Z")
            ]
        ))
        XCTAssertEqual(unknownTarget.errors, [.unknownCallTarget("DW999", "MHC-Z")])

        let mismatchedEvidence = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    supportEvidenceRefs: ["obs:DW473:MHC-A:12_M7_A_001_01"],
                    counterevidenceRefs: ["sample:DW472"]
                )
            ]
        ))
        XCTAssertEqual(
            mismatchedEvidence.errors,
            [.evidenceTargetMismatch("obs:DW473:MHC-A:12_M7_A_001_01", "DW472", "MHC-B")]
        )

        let cohortAllowed = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    supportEvidenceRefs: ["obs:DW472:MHC-B:12_M9_B_001_01", "cohort:MHC-A:M7"],
                    counterevidenceRefs: ["sample:DW472"]
                )
            ]
        ))
        XCTAssertTrue(cohortAllowed.accepted)
        XCTAssertEqual(cohortAllowed.errors, [])
    }

    func testRejectsCurrentAndManualConflictsUnlessCallStateExplainsConflict() throws {
        let registry = makeRegistry()

        let currentConflict = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(haplotypeLabel: "M8B", counterevidenceRefs: ["current:DW472:MHC-B:h1"])
            ]
        ))
        XCTAssertEqual(currentConflict.errors, [.conflictsCurrentCall("DW472", "MHC-B", "h1")])

        let currentExplained = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    haplotypeLabel: "M8B",
                    callState: .conflictsCurrent,
                    counterevidenceRefs: ["current:DW472:MHC-B:h1"]
                )
            ]
        ))
        XCTAssertTrue(currentExplained.accepted)
        XCTAssertEqual(currentExplained.normalizedCalls[0].status, .noHaplotype)
        XCTAssertNil(currentExplained.normalizedCalls[0].primaryHaplotypeLabel)
        XCTAssertEqual(currentExplained.normalizedCalls[0].proposedHaplotypeLabel, "M8B")

        let manualConflict = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    slot: "h2",
                    haplotypeLabel: "M5B",
                    counterevidenceRefs: ["manual:DW472:MHC-B:h2"]
                )
            ]
        ))
        XCTAssertEqual(manualConflict.errors, [.conflictsManualReview("DW472", "MHC-B", "h2")])

        let manualExplained = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    slot: "h2",
                    haplotypeLabel: "M5B",
                    callState: .conflictsManual,
                    counterevidenceRefs: ["manual:DW472:MHC-B:h2"]
                )
            ]
        ))
        XCTAssertTrue(manualExplained.accepted)
        XCTAssertEqual(manualExplained.normalizedCalls[0].status, .noHaplotype)
    }

    func testManualOverrideSupersedesCurrentCallAsConflictBaseline() throws {
        let registry = makeRegistryWithManualH1Override()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    haplotypeLabel: "Manual-M8B",
                    supportEvidenceRefs: ["manual:DW472:MHC-B:h1"],
                    counterevidenceRefs: ["current:DW472:MHC-B:h1"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.normalizedCalls[0].status, .called)
        XCTAssertEqual(report.normalizedCalls[0].primaryHaplotypeLabel, "Manual-M8B")
    }

    func testRejectsConflictStatesWithoutActualConflictEvidence() throws {
        let registry = makeRegistry()

        let noCurrentConflict = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(callState: .conflictsCurrent, counterevidenceRefs: ["current:DW472:MHC-B:h1"])
            ]
        ))
        XCTAssertEqual(noCurrentConflict.errors, [.missingCurrentConflict("DW472", "MHC-B", "h1")])

        let noManualConflict = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    slot: "h2",
                    haplotypeLabel: "Manual-M7B",
                    callState: .conflictsManual,
                    supportEvidenceRefs: ["manual:DW472:MHC-B:h2"],
                    counterevidenceRefs: ["manual:DW472:MHC-B:h2"]
                )
            ]
        ))
        XCTAssertEqual(noManualConflict.errors, [.missingManualConflict("DW472", "MHC-B", "h2")])
    }

    func testRejectsUnsupportedBiologicalClaimsInAllModelTextFields() throws {
        let registry = makeRegistry()
        let claimCases: [(String, AIHaplotypingStructuredResult)] = [
            ("phase-supported", makeResult(registry: registry, calls: [makeCall(haplotypeLabel: "phase-supported")])),
            ("requires phasing", makeResult(registry: registry, calls: [makeCall(rationale: "requires phasing")])),
            ("homozygous family", makeResult(registry: registry, calls: [makeCall(normalizedFamily: "homozygous family")])),
            ("homozygosity inferred", makeResult(registry: registry, calls: [makeCall(rationaleCode: "homozygosity inferred")])),
            ("copy number gain", makeResult(registry: registry, calls: [makeCall(alternates: ["copy number gain"])])),
            ("inherited from parent", makeResult(
                registry: registry,
                discoveredDefinitions: [
                    makeDefinition(proposedLabel: "M12B", rationale: "inherited from parent")
                ],
                calls: [makeCall()]
            )),
            ("inheritance from parent", makeResult(registry: registry, calls: [makeCall(rationale: "inheritance from parent")])),
            ("absent marker", makeResult(
                registry: registry,
                discoveredDefinitions: [
                    makeDefinition(proposedLabel: "absent marker")
                ],
                calls: [makeCall()]
            )),
            ("absence of marker", makeResult(registry: registry, calls: [makeCall(rationale: "absence of marker")])),
            ("clinical interpretation required", makeResult(registry: registry, calls: [
                makeCall(),
            ], warnings: ["clinical interpretation required"])),
        ]

        for (term, result) in claimCases {
            let report = AIHaplotypingPatchValidator(registry: registry).validate(result)
            XCTAssertEqual(report.errors, [.unsupportedClaim(term)])
        }
    }

    func testMapsAICallStateToHaplotypeStatus() throws {
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .called), .called)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .novelCandidate), .specialCase)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .ambiguousTie), .specialCase)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .insufficientEvidence), .noHaplotype)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .lowSupportOrDropout), .noHaplotype)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .conflictsCurrent), .noHaplotype)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .conflictsManual), .noHaplotype)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .unresolved), .noHaplotype)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .notAssayed), .notAssayed)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .outOfScope), .notAssayed)
    }

    func testKeepsNonFinalProposedLabelsOutOfPrimaryHaplotypeFields() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M7A-provisional",
                    callState: .novelCandidate,
                    supportEvidenceRefs: ["obs:DW473:MHC-A:12_M7_A_001_01"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.normalizedCalls[0].status, .specialCase)
        XCTAssertNil(report.normalizedCalls[0].primaryHaplotypeLabel)
        XCTAssertEqual(report.normalizedCalls[0].proposedHaplotypeLabel, "M7A-provisional")
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.proposedHaplotypeLabel, "M7A-provisional")
    }

    func testRejectsDuplicateProposedLabelsAcrossSlotsWithoutExplicitSupport() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(patchOpID: "patch-001", slot: "h1", haplotypeLabel: "M9B"),
                makeCall(patchOpID: "patch-002", slot: "h2", haplotypeLabel: "M9B"),
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.unsupportedDuplicateSlotLabel("DW472", "MHC-B", "M9B")])
    }

    func testValidatesDiscoveredDefinitionsAgainstClosedEvidence() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            discoveredDefinitions: [
                makeDefinition(
                    definitionID: "def-001",
                    locus: "MHC-B",
                    proposedLabel: "M12B",
                    normalizedFamily: "M12",
                    supportEvidenceRefs: ["obs:DW472:MHC-B:12_M9_B_001_01"],
                    counterevidenceRefs: ["locus:MHC-B"]
                )
            ],
            calls: [
                makeCall()
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.validatedDefinitions, [
            AIHaplotypingValidatedDefinition(
                definitionID: "def-001",
                locus: "MHC-B",
                proposedLabel: "M12B",
                normalizedFamily: "M12",
                supportEvidenceRefs: ["obs:DW472:MHC-B:12_M9_B_001_01"],
                counterevidenceRefs: ["locus:MHC-B"],
                confidenceTier: .medium
            )
        ])

        let unknownEvidence = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            discoveredDefinitions: [
                makeDefinition(supportEvidenceRefs: ["obs:missing"])
            ],
            calls: [makeCall()]
        ))
        XCTAssertEqual(unknownEvidence.errors, [.unknownEvidenceID("obs:missing")])

        let unknownLocus = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            discoveredDefinitions: [
                makeDefinition(locus: "MHC-Z")
            ],
            calls: [makeCall()]
        ))
        XCTAssertEqual(unknownLocus.errors, [.unknownDefinitionLocus("MHC-Z")])

        let missingSupport = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            discoveredDefinitions: [
                makeDefinition(definitionID: "def-002", supportEvidenceRefs: [])
            ],
            calls: [makeCall()]
        ))
        XCTAssertEqual(missingSupport.errors, [.missingSupportEvidence("def-002")])

        let cohortOnlySupport = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            discoveredDefinitions: [
                makeDefinition(
                    definitionID: "def-003",
                    locus: "MHC-A",
                    supportEvidenceRefs: ["cohort:MHC-A:M7"],
                    counterevidenceRefs: ["locus:MHC-A"]
                )
            ],
            calls: [makeCall()]
        ))
        XCTAssertEqual(cohortOnlySupport.errors, [.missingSupportEvidence("def-003")])

        let crossLocusCohortEvidence = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            discoveredDefinitions: [
                makeDefinition(
                    definitionID: "def-004",
                    locus: "MHC-B",
                    supportEvidenceRefs: [
                        "obs:DW472:MHC-B:12_M9_B_001_01",
                        "cohort:MHC-A:M7",
                    ],
                    counterevidenceRefs: ["locus:MHC-B"]
                )
            ],
            calls: [makeCall()]
        ))
        XCTAssertEqual(crossLocusCohortEvidence.errors, [.evidenceTargetMismatch("cohort:MHC-A:M7", "", "MHC-B")])

        let duplicateDefinition = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            discoveredDefinitions: [
                makeDefinition(definitionID: "def-001"),
                makeDefinition(definitionID: "def-001", proposedLabel: "M13B"),
            ],
            calls: [makeCall()]
        ))
        XCTAssertEqual(duplicateDefinition.errors, [.duplicateDiscoveredDefinition("def-001")])

        let collision = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            discoveredDefinitions: [
                makeDefinition(definitionID: "def-001", proposedLabel: "M12B"),
                makeDefinition(
                    definitionID: "def-002",
                    proposedLabel: "M12B",
                    supportEvidenceRefs: ["cohort:MHC-A:M7"]
                ),
            ],
            calls: [makeCall()]
        ))
        XCTAssertEqual(collision.errors, [.provisionalDefinitionCollision("MHC-B:M12B")])

        let identicalDuplicateLabel = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            discoveredDefinitions: [
                makeDefinition(definitionID: "def-001", proposedLabel: "M14B"),
                makeDefinition(definitionID: "def-002", proposedLabel: "M14B"),
            ],
            calls: [makeCall()]
        ))
        XCTAssertEqual(identicalDuplicateLabel.errors, [.provisionalDefinitionCollision("MHC-B:M14B")])
    }

    func testCurrentAndManualEvidenceIDsAreRecognizedFromRegistry() throws {
        let registry = makeRegistry()
        XCTAssertTrue(registry.evidenceIDs.contains("current:DW472:MHC-B:h1"))
        XCTAssertTrue(registry.evidenceIDs.contains("manual:DW472:MHC-B:h2"))

        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    haplotypeLabel: "M8B",
                    callState: .conflictsCurrent,
                    supportEvidenceRefs: ["current:DW472:MHC-B:h1"],
                    counterevidenceRefs: ["manual:DW472:MHC-B:h2"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls[0].supportEvidenceRefs, ["current:DW472:MHC-B:h1"])
        XCTAssertEqual(report.normalizedCalls[0].counterevidenceRefs, ["manual:DW472:MHC-B:h2"])
    }

    func testValidationErrorCodableUsesStableObjectShape() throws {
        let error = AIHaplotypingValidationError.unknownEvidenceID("obs:missing")

        let data = try JSONEncoder().encode(error)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["code"] as? String, "unknown_evidence_id")
        XCTAssertEqual(object["message"] as? String, "Structured result cites unknown evidence ID 'obs:missing'.")
        XCTAssertEqual((object["fields"] as? [String: Any])?["evidenceID"] as? String, "obs:missing")
        XCTAssertEqual(try JSONDecoder().decode(AIHaplotypingValidationError.self, from: data), error)
    }
}

private extension AIHaplotypingPatchValidatorTests {
    func makeRegistry() -> AIHaplotypingEvidenceRegistry {
        AIHaplotypingEvidenceRegistry(
            mode: .aiRefinement,
            parentRevisionID: "analysis-rev-1",
            inputSnapshotDigest: "sha256:\(String(repeating: "1", count: 64))",
            samples: [
                SampleEvidence(id: "sample:DW472", sample: "DW472"),
                SampleEvidence(id: "sample:DW473", sample: "DW473"),
            ],
            loci: [
                LocusEvidence(id: "locus:MHC-A", locus: "MHC-A"),
                LocusEvidence(id: "locus:MHC-B", locus: "MHC-B"),
            ],
            observations: [
                ObservationEvidence(
                    id: "obs:DW472:MHC-B:12_M9_B_001_01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW472",
                    locusID: "locus:MHC-B",
                    genotype: "12_M9_B_001_01",
                    passedAlignments: 40,
                    passedUniqueReads: 22,
                    sampleUniqueRetainedReads: 120
                ),
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:12_M7_A_001_01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "12_M7_A_001_01",
                    passedAlignments: 41,
                    passedUniqueReads: 23,
                    sampleUniqueRetainedReads: 130
                ),
                ObservationEvidence(
                    id: "cohort:MHC-A:M7",
                    evidenceClass: .cohortRecurrence,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "12_M7_A_001_01",
                    passedAlignments: 100,
                    passedUniqueReads: 50,
                    sampleUniqueRetainedReads: nil
                ),
            ],
            currentCalls: [
                CurrentCallEvidence(
                    id: "current:DW472:MHC-B:h1",
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h1",
                    haplotypeLabel: "M9B",
                    source: .ai,
                    parentRevisionID: "analysis-rev-1"
                ),
            ],
            manualReviews: [
                ManualReviewEvidence(
                    id: "manual:DW472:MHC-B:h2",
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h2",
                    overrideCall: "Manual-M7B",
                    rationale: "Manual review context."
                ),
            ]
        )
    }

    func makeRegistryWithManualH1Override() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations,
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews + [
                ManualReviewEvidence(
                    id: "manual:DW472:MHC-B:h1",
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h1",
                    overrideCall: "Manual-M8B",
                    rationale: "Manual review supersedes current call."
                )
            ]
        )
    }

    func makeResult(
        registry: AIHaplotypingEvidenceRegistry,
        discoveredDefinitions: [AIHaplotypingDiscoveredDefinition] = [],
        calls: [AIHaplotypingStructuredCall],
        warnings: [String] = []
    ) -> AIHaplotypingStructuredResult {
        AIHaplotypingStructuredResult(
            schemaVersion: 1,
            run: AIHaplotypingRunMetadata(
                mode: .aiRefinement,
                promptTemplateID: "lungfish.ai-haplotyping.refinement",
                promptTemplateVersion: "2026-06-14.1",
                promptHash: "sha256:\(String(repeating: "2", count: 64))",
                provider: "openai",
                model: "test-model",
                generationParameters: ["temperature": "0"],
                parentRevisionID: "analysis-rev-1",
                registryDigest: registry.digest,
                inputSnapshotDigest: registry.inputSnapshotDigest
            ),
            registryDigest: registry.digest,
            inputSnapshotDigest: registry.inputSnapshotDigest,
            chunkID: "chunk-0001",
            discoveredDefinitions: discoveredDefinitions,
            calls: calls,
            warnings: warnings
        )
    }

    func makeCall(
        patchOpID: String = "patch-001",
        sample: String = "DW472",
        locus: String = "MHC-B",
        slot: String = "h1",
        haplotypeLabel: String = "M9B",
        normalizedFamily: String? = "M9",
        source: GenotypeHaplotypeAnalysisSource = .ai,
        sourceState: GenotypeHaplotypeAICallSourceState = .raw,
        reviewState: GenotypeHaplotypeAICallReviewState = .needsReview,
        callState: GenotypeHaplotypeAICallState = .called,
        confidenceTier: GenotypeHaplotypeAIConfidenceTier = .high,
        supportEvidenceRefs: [String] = ["obs:DW472:MHC-B:12_M9_B_001_01"],
        counterevidenceRefs: [String] = ["sample:DW472"],
        alternates: [String] = [],
        rationaleCode: String = "direct_observation",
        rationale: String = "Direct observed genotype support.",
    ) -> AIHaplotypingStructuredCall {
        AIHaplotypingStructuredCall(
            patchOpID: patchOpID,
            sample: sample,
            locus: locus,
            slot: slot,
            haplotypeLabel: haplotypeLabel,
            normalizedFamily: normalizedFamily,
            source: source,
            sourceState: sourceState,
            reviewState: reviewState,
            callState: callState,
            confidenceTier: confidenceTier,
            supportEvidenceRefs: supportEvidenceRefs,
            counterevidenceRefs: counterevidenceRefs,
            alternates: alternates,
            rationaleCode: rationaleCode,
            rationale: rationale
        )
    }

    func makeDefinition(
        definitionID: String = "def-001",
        locus: String = "MHC-B",
        proposedLabel: String = "M12B",
        normalizedFamily: String? = nil,
        supportEvidenceRefs: [String] = ["obs:DW472:MHC-B:12_M9_B_001_01"],
        counterevidenceRefs: [String] = ["locus:MHC-B"],
        confidenceTier: GenotypeHaplotypeAIConfidenceTier = .medium,
        rationaleCode: String = "direct_observation",
        rationale: String = "Potential new definition."
    ) -> AIHaplotypingDiscoveredDefinition {
        AIHaplotypingDiscoveredDefinition(
            definitionID: definitionID,
            locus: locus,
            proposedLabel: proposedLabel,
            normalizedFamily: normalizedFamily,
            supportEvidenceRefs: supportEvidenceRefs,
            counterevidenceRefs: counterevidenceRefs,
            confidenceTier: confidenceTier,
            rationaleCode: rationaleCode,
            rationale: rationale
        )
    }

    func assertClosedSchema(_ value: JSONValue, context: String) throws {
        guard case .object(let object) = value else { return }
        if object["properties"] != nil {
            XCTAssertEqual(object["additionalProperties"], .bool(false), context)
            let properties = try XCTUnwrap(object.object("properties"), context)
            let required = try XCTUnwrap(object["required"]?.arrayValue?.compactMap(\.stringValue), context)
            XCTAssertEqual(Set(required), Set(properties.keys), context)
            for (propertyName, propertySchema) in properties {
                try assertClosedSchema(propertySchema, context: "\(context).\(propertyName)")
            }
        }
        if let items = object["items"] {
            XCTAssertNotNil(object["maxItems"], context)
            try assertClosedSchema(items, context: "\(context)[]")
        }
        if let anyOf = object["anyOf"]?.arrayValue {
            for nested in anyOf {
                try assertClosedSchema(nested, context: "\(context).anyOf")
            }
        }
        if let type = object["type"]?.arrayValue {
            XCTAssertTrue(type.contains(.string("null")), context)
        }
    }

    func containsForbiddenSchemaProperty(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let object):
            if let properties = object["properties"]?.objectValue {
                for key in properties.keys {
                    let lower = key.lowercased()
                    if ["path", "file", "directory", "uri", "url", "filesystem"].contains(where: lower.contains) {
                        return true
                    }
                }
            }
            return object.values.contains(where: containsForbiddenSchemaProperty)
        case .array(let values):
            return values.contains(where: containsForbiddenSchemaProperty)
        default:
            return false
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func object(_ key: String) -> [String: JSONValue]? {
        self[key]?.objectValue
    }
}
