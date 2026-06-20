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

    func testValidatorAcceptsRegistrySampleAndLocusIDsAsCallTargets() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            discoveredDefinitions: [
                makeDefinition(locus: "locus:MHC-B"),
            ],
            calls: [
                makeCall(sample: "sample:DW472", locus: "locus:MHC-B")
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls[0].sample, "DW472")
        XCTAssertEqual(report.normalizedCalls[0].locus, "MHC-B")
        XCTAssertEqual(report.validatedDefinitions[0].locus, "MHC-B")
    }

    func testValidatorAllowsMHCLEvidenceAsContextButRejectsMHCLReportCalls() throws {
        let registry = makeRegistryWithMHCLEvidence()
        let contextualResult = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M6A",
                    supportEvidenceRefs: ["obs:DW473:MHC-L:Mafa-L*01:06:01:01"],
                    counterevidenceRefs: ["locus:MHC-A"],
                    rationale: "MHC-L context supports the nearby MHC-A block."
                )
            ]
        )

        let contextualReport = AIHaplotypingPatchValidator(registry: registry).validate(contextualResult)

        XCTAssertTrue(contextualReport.accepted)
        XCTAssertEqual(contextualReport.errors, [])
        guard contextualReport.accepted, !contextualReport.normalizedCalls.isEmpty else { return }
        XCTAssertEqual(
            contextualReport.normalizedCalls[0].supportEvidenceRefs,
            ["obs:DW473:MHC-L:Mafa-L*01:06:01:01"]
        )

        let reportLevelMHCL = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-L",
                    haplotypeLabel: "M6L",
                    supportEvidenceRefs: ["obs:DW473:MHC-L:Mafa-L*01:06:01:01"],
                    counterevidenceRefs: ["locus:MHC-L"]
                )
            ]
        )

        let reportLevelResult = AIHaplotypingPatchValidator(registry: registry).validate(reportLevelMHCL)

        XCTAssertFalse(reportLevelResult.accepted)
        XCTAssertEqual(reportLevelResult.errors, [.unknownCallTarget("DW473", "MHC-L")])
    }

    func testValidatorNormalizesSingleMissingGSuffixObservationEvidenceID() throws {
        let registry = makeRegistryWithTrailingGObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M4A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:06_M4M7_A5_30_01"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(report.normalizedCalls[0].supportEvidenceRefs, ["obs:DW473:MHC-A:06_M4M7_A5_30_01g"])
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.supportEvidenceRefs, ["obs:DW473:MHC-A:06_M4M7_A5_30_01g"])
    }

    func testValidatorNormalizesSingleMissingNSuffixObservationEvidenceID() throws {
        let registry = makeRegistryWithTrailingNObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-B",
                    haplotypeLabel: "M5B",
                    supportEvidenceRefs: ["obs:DW473:MHC-B:12_M5_B_167_01"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(report.normalizedCalls[0].supportEvidenceRefs, ["obs:DW473:MHC-B:12_M5_B_167_01N"])
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.supportEvidenceRefs, ["obs:DW473:MHC-B:12_M5_B_167_01N"])
    }

    func testValidatorNormalizesDuplicatedEvidenceNamespacePrefix() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(counterevidenceRefs: ["sample:sample:DW472", "locus:locus:MHC-B"])
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(report.normalizedCalls[0].counterevidenceRefs, ["sample:DW472", "locus:MHC-B"])
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.counterevidenceRefs, ["sample:DW472", "locus:MHC-B"])
    }

    func testValidatorNormalizesPipeDuplicatedEvidenceReference() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(counterevidenceRefs: ["locus:MHC-B|locus:MHC-B"])
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(report.normalizedCalls[0].counterevidenceRefs, ["locus:MHC-B"])
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.counterevidenceRefs, ["locus:MHC-B"])
    }

    func testValidatorNormalizesUniquePipedObservationEvidenceIDPrefix() throws {
        let registry = makeRegistryWithPipedObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M4A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_06g1"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(
            report.normalizedCalls[0].supportEvidenceRefs,
            ["obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_06g1|AG_06_02,_AG_06_05,_AG_06_w_01"]
        )
        XCTAssertEqual(
            report.normalizedCalls[0].aiMetadata.supportEvidenceRefs,
            ["obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_06g1|AG_06_02,_AG_06_05,_AG_06_w_01"]
        )
    }

    func testValidatorNormalizesTrailingPipeOnExactObservationEvidenceID() throws {
        let registry = makeRegistryWithPipedObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M4A",
                    supportEvidenceRefs: [
                        "obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_06g1|AG_06_02,_AG_06_05,_AG_06_w_01|"
                    ],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(
            report.normalizedCalls[0].supportEvidenceRefs,
            ["obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_06g1|AG_06_02,_AG_06_05,_AG_06_w_01"]
        )
    }

    func testValidatorNormalizesObservationEvidenceIDWithWrongPipeMetadataWhenBaseIDIsUnique() throws {
        let registry = makeRegistryWithPipedObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M4A",
                    supportEvidenceRefs: [
                        "obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_06g1|wrong_metadata"
                    ],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(
            report.normalizedCalls[0].supportEvidenceRefs,
            ["obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_06g1|AG_06_02,_AG_06_05,_AG_06_w_01"]
        )
    }

    func testValidatorRejectsAmbiguousPipedObservationEvidenceIDPrefix() throws {
        let base = makeRegistryWithPipedObservation()
        let registry = AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_06g1|AG_06_07",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "04_M1M2M3M4M5M6M7_AG_06g1|AG_06_07",
                    passedAlignments: 10,
                    passedUniqueReads: 10,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M4A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_06g1"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.unknownEvidenceID("obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_06g1")])
        XCTAssertEqual(report.normalizedCalls, [])
    }

    func testValidatorNormalizesUniquePipedObservationAliasEvidenceID() throws {
        let registry = makeRegistryWithPipedAliasObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M2A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:11_M2M3_E_02_nov_12"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(
            report.normalizedCalls[0].supportEvidenceRefs,
            ["obs:DW473:MHC-A:11_M2M3_E_02g2|E_02_03,_E_02_nov_12"]
        )
        XCTAssertEqual(
            report.normalizedCalls[0].aiMetadata.supportEvidenceRefs,
            ["obs:DW473:MHC-A:11_M2M3_E_02g2|E_02_03,_E_02_nov_12"]
        )
    }

    func testValidatorRejectsAmbiguousPipedObservationAliasEvidenceID() throws {
        let base = makeRegistryWithPipedAliasObservation()
        let registry = AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:11_M3_E_02g9|E_02_nov_12",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "11_M3_E_02g9|E_02_nov_12",
                    passedAlignments: 12,
                    passedUniqueReads: 12,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M2A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:11_M2M3_E_02_nov_12"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.unknownEvidenceID("obs:DW473:MHC-A:11_M2M3_E_02_nov_12")])
        XCTAssertEqual(report.normalizedCalls, [])
    }

    func testValidatorNormalizesUniqueCollapsedMarkerObservationEvidenceID() throws {
        let registry = makeRegistryWithCollapsedMarkerObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M1A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:11_M1_E_02g1|E_02_01,_E_02_02"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(
            report.normalizedCalls[0].supportEvidenceRefs,
            ["obs:DW473:MHC-A:11_M1M4_E_02g1|E_02_01,_E_02_02"]
        )
        XCTAssertEqual(
            report.normalizedCalls[0].aiMetadata.supportEvidenceRefs,
            ["obs:DW473:MHC-A:11_M1M4_E_02g1|E_02_01,_E_02_02"]
        )
    }

    func testValidatorRejectsAmbiguousCollapsedMarkerObservationEvidenceID() throws {
        let base = makeRegistryWithCollapsedMarkerObservation()
        let registry = AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:11_M1M5_E_02g1|E_02_01,_E_02_02",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "11_M1M5_E_02g1|E_02_01,_E_02_02",
                    passedAlignments: 11,
                    passedUniqueReads: 11,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M1A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:11_M1_E_02g1|E_02_01,_E_02_02"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.unknownEvidenceID("obs:DW473:MHC-A:11_M1_E_02g1|E_02_01,_E_02_02")])
        XCTAssertEqual(report.normalizedCalls, [])
    }

    func testValidatorNormalizesUniqueExpandedMarkerObservationEvidenceID() throws {
        let registry = makeRegistryWithExpandedMarkerObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M1A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_g3ex"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(
            report.normalizedCalls[0].supportEvidenceRefs,
            ["obs:DW473:MHC-A:04_M1M2M3M4_AG_g3ex"]
        )
        XCTAssertEqual(
            report.normalizedCalls[0].aiMetadata.supportEvidenceRefs,
            ["obs:DW473:MHC-A:04_M1M2M3M4_AG_g3ex"]
        )
    }

    func testValidatorRejectsAmbiguousExpandedMarkerObservationEvidenceID() throws {
        let base = makeRegistryWithExpandedMarkerObservation()
        let registry = AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:04_M1M2M3M4M5_AG_g3ex",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "04_M1M2M3M4M5_AG_g3ex",
                    passedAlignments: 22,
                    passedUniqueReads: 22,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M1A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_g3ex"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.unknownEvidenceID("obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_g3ex")])
        XCTAssertEqual(report.normalizedCalls, [])
    }

    func testValidatorNormalizesUniqueOverlappingMarkerObservationEvidenceID() throws {
        let registry = makeRegistryWithOverlappingMarkerObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M5A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:11_M5M6_E_02_nov_01"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(
            report.normalizedCalls[0].supportEvidenceRefs,
            ["obs:DW473:MHC-A:11_M4M5_E_02_nov_01"]
        )
    }

    func testValidatorRejectsAmbiguousOverlappingMarkerObservationEvidenceID() throws {
        let base = makeRegistryWithOverlappingMarkerObservation()
        let registry = AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:11_M5M7_E_02_nov_01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "11_M5M7_E_02_nov_01",
                    passedAlignments: 19,
                    passedUniqueReads: 19,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M5A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:11_M5M6_E_02_nov_01"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.unknownEvidenceID("obs:DW473:MHC-A:11_M5M6_E_02_nov_01")])
        XCTAssertEqual(report.normalizedCalls, [])
    }

    func testValidatorNormalizesUniqueTerminalAssaySuffixObservationEvidenceID() throws {
        let registry = makeRegistryWithTerminalAssaySuffixObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M3A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:02_M3_G_02_0508_g48c"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(
            report.normalizedCalls[0].supportEvidenceRefs,
            ["obs:DW473:MHC-A:02_M3_G_02_0508_g48c_156bp"]
        )
        XCTAssertEqual(
            report.normalizedCalls[0].aiMetadata.supportEvidenceRefs,
            ["obs:DW473:MHC-A:02_M3_G_02_0508_g48c_156bp"]
        )
    }

    func testValidatorRejectsAmbiguousTerminalAssaySuffixObservationEvidenceID() throws {
        let base = makeRegistryWithTerminalAssaySuffixObservation()
        let registry = AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:02_M3_G_02_0508_g48c_200bp",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "02_M3_G_02_0508_g48c_200bp",
                    passedAlignments: 21,
                    passedUniqueReads: 21,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M3A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:02_M3_G_02_0508_g48c"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.unknownEvidenceID("obs:DW473:MHC-A:02_M3_G_02_0508_g48c")])
        XCTAssertEqual(report.normalizedCalls, [])
    }

    func testValidatorNormalizesUniqueTerminalNumericSuffixObservationEvidenceID() throws {
        let registry = makeRegistryWithTerminalNumericSuffixObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-B",
                    haplotypeLabel: "M1B",
                    supportEvidenceRefs: ["obs:DW473:MHC-B:12_M1_B_046_01"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(
            report.normalizedCalls[0].supportEvidenceRefs,
            ["obs:DW473:MHC-B:12_M1_B_046_01_01"]
        )
        XCTAssertEqual(
            report.normalizedCalls[0].aiMetadata.supportEvidenceRefs,
            ["obs:DW473:MHC-B:12_M1_B_046_01_01"]
        )
    }

    func testValidatorRejectsAmbiguousTerminalNumericSuffixObservationEvidenceID() throws {
        let base = makeRegistryWithTerminalNumericSuffixObservation()
        let registry = AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-B:12_M1_B_046_01_02",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-B",
                    genotype: "12_M1_B_046_01_02",
                    passedAlignments: 2,
                    passedUniqueReads: 2,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-B",
                    haplotypeLabel: "M1B",
                    supportEvidenceRefs: ["obs:DW473:MHC-B:12_M1_B_046_01"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.unknownEvidenceID("obs:DW473:MHC-B:12_M1_B_046_01")])
        XCTAssertEqual(report.normalizedCalls, [])
    }

    func testValidatorNormalizesUniqueLeadingRegionTokenObservationEvidenceID() throws {
        let registry = makeRegistryWithLeadingRegionTokenObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M1A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:02_M1_F_01_w_06"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(
            report.normalizedCalls[0].supportEvidenceRefs,
            ["obs:DW473:MHC-A:01_M1_F_01_w_06"]
        )
        XCTAssertEqual(
            report.normalizedCalls[0].aiMetadata.supportEvidenceRefs,
            ["obs:DW473:MHC-A:01_M1_F_01_w_06"]
        )
    }

    func testValidatorRejectsAmbiguousLeadingRegionTokenObservationEvidenceID() throws {
        let base = makeRegistryWithLeadingRegionTokenObservation()
        let registry = AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:03_M1_F_01_w_06",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "03_M1_F_01_w_06",
                    passedAlignments: 3,
                    passedUniqueReads: 3,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M1A",
                    supportEvidenceRefs: ["obs:DW473:MHC-A:02_M1_F_01_w_06"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.unknownEvidenceID("obs:DW473:MHC-A:02_M1_F_01_w_06")])
        XCTAssertEqual(report.normalizedCalls, [])
    }

    func testValidatorNormalizesUniqueAlleleFamilySuffixObservationEvidenceID() throws {
        let registry = makeRegistryWithAlleleFamilySuffixObservation()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-B",
                    haplotypeLabel: "M7B",
                    supportEvidenceRefs: ["obs:DW473:MHC-B:12_M7_B11L_01g2ex"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(report.normalizedCalls[0].supportEvidenceRefs, ["obs:DW473:MHC-B:12_M7_B11L_01_05"])
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.supportEvidenceRefs, ["obs:DW473:MHC-B:12_M7_B11L_01_05"])
    }

    func testValidatorRejectsAmbiguousAlleleFamilySuffixObservationEvidenceID() throws {
        let base = makeRegistryWithAlleleFamilySuffixObservation()
        let registry = AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-B:12_M7_B11L_01_06",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-B",
                    genotype: "12_M7_B11L_01_06",
                    passedAlignments: 12,
                    passedUniqueReads: 12,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-B",
                    haplotypeLabel: "M7B",
                    supportEvidenceRefs: ["obs:DW473:MHC-B:12_M7_B11L_01g2ex"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors, [.unknownEvidenceID("obs:DW473:MHC-B:12_M7_B11L_01g2ex")])
        XCTAssertEqual(report.normalizedCalls, [])
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

    func testValidatorCoalescesSubstantivelyDuplicateCallTarget() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(patchOpID: "patch-001", slot: "h1", haplotypeLabel: "M9B"),
                makeCall(
                    patchOpID: "patch-002",
                    slot: "h1",
                    haplotypeLabel: "M9B",
                    rationaleCode: "same_call_duplicate",
                    rationale: "Same call repeated by model output."
                ),
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.map(\.patchOpID), ["patch-001"])
    }

    func testRejectsBlankPatchOperationID() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(patchOpID: " \n ")
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors.first?.code, "invalid_patch_op_id")
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

    func testDowngradesCalledPatchWithPlaceholderHaplotypeLabelToUnresolved() throws {
        let registry = makeRegistry()

        let report = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    haplotypeLabel: "-",
                    callState: .called,
                    supportEvidenceRefs: ["obs:DW472:MHC-B:12_M9_B_001_01"],
                    counterevidenceRefs: ["sample:DW472"]
                )
            ]
        ))

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(report.normalizedCalls[0].status, .noHaplotype)
        XCTAssertNil(report.normalizedCalls[0].primaryHaplotypeLabel)
        XCTAssertEqual(report.normalizedCalls[0].proposedHaplotypeLabel, "-")
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.callState, .unresolved)
    }

    func testDowngradesNonConflictingCurrentConflictWithPlaceholderHaplotypeLabelToUnresolved() throws {
        let registry = makeRegistry()

        let report = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h1",
                    haplotypeLabel: "-",
                    callState: .conflictsCurrent,
                    supportEvidenceRefs: ["obs:DW472:MHC-B:12_M9_B_001_01"],
                    counterevidenceRefs: ["sample:DW472"]
                )
            ]
        ))

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.count, 1)
        guard report.accepted, report.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(report.normalizedCalls[0].status, .noHaplotype)
        XCTAssertNil(report.normalizedCalls[0].primaryHaplotypeLabel)
        XCTAssertEqual(report.normalizedCalls[0].proposedHaplotypeLabel, "-")
        XCTAssertEqual(report.normalizedCalls[0].aiMetadata.callState, .unresolved)
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
        let generationParameterProperties = try XCTUnwrap(generationParameters.object("properties"))
        XCTAssertNotNil(generationParameterProperties["compactKnowledgePack"])
        XCTAssertNotNil(generationParameterProperties["maxProviderRetries"])
        XCTAssertNotNil(generationParameterProperties["reasoningEffort"])
        XCTAssertNotNil(generationParameterProperties["reviewScope"])
        let callsSchema = try XCTUnwrap(root["calls"]?.objectValue)
        let callSchema = try XCTUnwrap(callsSchema["items"]?.objectValue)
        let callProperties = try XCTUnwrap(callSchema.object("properties"))
        XCTAssertEqual(callProperties["patchOpID"]?.objectValue?["minLength"], .integer(1))
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

    func testValidatorAllowsTightlyLinkedDQDPEvidenceButRejectsUnrelatedCrossLocusEvidence() throws {
        let registry = makeRegistryWithDQDPEvidence()

        let linkedDQDP = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW472",
                    locus: "MHC-DQ",
                    haplotypeLabel: "M4DQ",
                    supportEvidenceRefs: ["obs:DW472:MHC-DP:MCM_MHC_MiSeq_0153"],
                    counterevidenceRefs: ["locus:MHC-DQ"]
                )
            ]
        ))
        XCTAssertTrue(linkedDQDP.accepted)
        XCTAssertEqual(linkedDQDP.errors, [])

        let unrelatedCrossLocus = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW472",
                    locus: "MHC-DP",
                    haplotypeLabel: "M4DP",
                    supportEvidenceRefs: ["obs:DW472:MHC-L:Mafa-L*01:06:01:01"],
                    counterevidenceRefs: ["locus:MHC-DP"]
                )
            ]
        ))
        XCTAssertEqual(
            unrelatedCrossLocus.errors,
            [.evidenceTargetMismatch("obs:DW472:MHC-L:Mafa-L*01:06:01:01", "DW472", "MHC-DP")]
        )
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

        let explicitCurrentSuperseded = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    haplotypeLabel: "M8B",
                    counterevidenceRefs: ["current:DW472:MHC-B:h1"],
                    rationaleCode: "current_call_superseded",
                    rationale: "Observed M8B support conflicts with the current M9B call; the current call is superseded by stronger observation evidence."
                )
            ]
        ))
        XCTAssertTrue(explicitCurrentSuperseded.accepted)
        XCTAssertEqual(explicitCurrentSuperseded.errors, [])
        guard explicitCurrentSuperseded.accepted else { return }
        XCTAssertEqual(explicitCurrentSuperseded.normalizedCalls[0].status, .noHaplotype)
        XCTAssertNil(explicitCurrentSuperseded.normalizedCalls[0].primaryHaplotypeLabel)
        XCTAssertEqual(explicitCurrentSuperseded.normalizedCalls[0].proposedHaplotypeLabel, "M8B")
        XCTAssertEqual(explicitCurrentSuperseded.normalizedCalls[0].aiMetadata.callState, .conflictsCurrent)

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

    func testErrorCurrentCallsDoNotRequireConflictStateForAIRefinement() throws {
        let registry = makeRegistryWithErrorCurrentCall()
        let report = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    haplotypeLabel: "M8B",
                    supportEvidenceRefs: ["obs:DW472:MHC-B:12_M9_B_001_01"],
                    counterevidenceRefs: ["current:DW472:MHC-B:h1"]
                )
            ]
        ))

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.map(\.primaryHaplotypeLabel), ["M8B"])
    }

    func testRetainCurrentIsCarryForwardOnly() throws {
        let registry = makeRegistry()

        let retainedCurrent = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sourceState: .current,
                    callState: .retainCurrent,
                    supportEvidenceRefs: ["current:DW472:MHC-B:h1"],
                    counterevidenceRefs: ["sample:DW472"]
                )
            ]
        ))
        XCTAssertTrue(retainedCurrent.accepted)
        XCTAssertEqual(retainedCurrent.normalizedCalls[0].status, .called)
        XCTAssertNil(retainedCurrent.normalizedCalls[0].primaryHaplotypeLabel)
        XCTAssertEqual(retainedCurrent.normalizedCalls[0].proposedHaplotypeLabel, "M9B")
        XCTAssertEqual(retainedCurrent.normalizedCalls[0].aiMetadata.callState, .retainCurrent)

        let retainedManual = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    slot: "h2",
                    haplotypeLabel: "Manual-M7B",
                    sourceState: .manual,
                    callState: .retainCurrent,
                    supportEvidenceRefs: ["manual:DW472:MHC-B:h2"],
                    counterevidenceRefs: ["sample:DW472"]
                )
            ]
        ))
        XCTAssertTrue(retainedManual.accepted)
        XCTAssertNil(retainedManual.normalizedCalls[0].primaryHaplotypeLabel)

        let missingCarryForward = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    sample: "DW473",
                    locus: "MHC-A",
                    haplotypeLabel: "M7A",
                    sourceState: .current,
                    callState: .retainCurrent,
                    supportEvidenceRefs: ["obs:DW473:MHC-A:12_M7_A_001_01"],
                    counterevidenceRefs: ["sample:DW473"]
                )
            ]
        ))
        XCTAssertEqual(missingCarryForward.errors, [.missingCurrentCarryForward("DW473", "MHC-A", "h1")])

        let mismatchedCarryForward = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    haplotypeLabel: "M8B",
                    sourceState: .current,
                    callState: .retainCurrent,
                    supportEvidenceRefs: ["current:DW472:MHC-B:h1"],
                    counterevidenceRefs: ["sample:DW472"]
                )
            ]
        ))
        XCTAssertEqual(mismatchedCarryForward.errors, [.retainCurrentMismatch("DW472", "MHC-B", "h1")])
    }

    func testRetainCurrentRejectsPlaceholderCarryForwardLabels() throws {
        let registry = makeRegistryWithPlaceholderCurrentCall()
        let report = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    haplotypeLabel: "-",
                    sourceState: .current,
                    callState: .retainCurrent,
                    supportEvidenceRefs: ["current:DW472:MHC-B:h1"],
                    counterevidenceRefs: ["sample:DW472"]
                )
            ]
        ))

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors.first, .invalidCarryForwardLabel("DW472", "MHC-B", "h1"))
    }

    func testRetainCurrentRejectsErrorCarryForwardLabels() throws {
        let registry = makeRegistryWithErrorCurrentCall()
        let report = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(
                    haplotypeLabel: "ERR: TMH (M8B, M9B)",
                    sourceState: .current,
                    callState: .retainCurrent,
                    supportEvidenceRefs: ["current:DW472:MHC-B:h1"],
                    counterevidenceRefs: ["sample:DW472"]
                )
            ]
        ))

        XCTAssertFalse(report.accepted)
        XCTAssertEqual(report.errors.first, .invalidCarryForwardLabel("DW472", "MHC-B", "h1"))
    }

    func testRejectsConflictStatesWithoutActualConflictEvidence() throws {
        let registry = makeRegistry()

        let noCurrentConflict = AIHaplotypingPatchValidator(registry: registry).validate(makeResult(
            registry: registry,
            calls: [
                makeCall(callState: .conflictsCurrent, counterevidenceRefs: ["current:DW472:MHC-B:h1"])
            ]
        ))
        XCTAssertTrue(noCurrentConflict.accepted)
        XCTAssertEqual(noCurrentConflict.errors, [])
        XCTAssertEqual(noCurrentConflict.normalizedCalls.count, 1)
        guard noCurrentConflict.accepted, noCurrentConflict.normalizedCalls.count == 1 else { return }
        XCTAssertEqual(noCurrentConflict.normalizedCalls[0].aiMetadata.callState, .called)
        XCTAssertEqual(noCurrentConflict.normalizedCalls[0].status, .called)

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
            ("clinical interpretation required", makeResult(registry: registry, calls: [
                makeCall(),
            ], warnings: ["clinical interpretation required"])),
        ]

        for (term, result) in claimCases {
            let report = AIHaplotypingPatchValidator(registry: registry).validate(result)
            XCTAssertEqual(report.errors, [.unsupportedClaim(term)])
        }
    }

    func testAllowsNegatedNonClinicalDisclaimerInWarnings() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            calls: [makeCall()],
            warnings: [
                "Observed markers support the MCM label; downstream higher-resolution confirmation is not clinical."
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.warnings, [
            "Observed markers support the MCM label; downstream higher-resolution confirmation is not clinical."
        ])
    }

    func testAllowsHomozygousLanguageInCallRationale() throws {
        let registry = makeRegistry()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    rationaleCode: "mcm_m1_homozygous_support",
                    rationale: "Direct support is dominant; homozygous evidence is plausible and absence of a coherent second marker set is reviewable."
                )
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
    }

    func testAllowsHomozygousAndAbsenceLanguageInWarnings() throws {
        let registry = makeRegistry()
        let warning = "h2 assigned as M1A (homozygous) based on coherent marker support and absence of a credible second marker set."
        let result = makeResult(
            registry: registry,
            calls: [makeCall()],
            warnings: [warning]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.warnings, [warning])
    }

    func testMapsAICallStateToHaplotypeStatus() throws {
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .called), .called)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .novelCandidate), .specialCase)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .ambiguousTie), .specialCase)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .insufficientEvidence), .noHaplotype)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .lowSupportOrDropout), .noHaplotype)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .conflictsCurrent), .noHaplotype)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .conflictsManual), .noHaplotype)
        XCTAssertEqual(AIHaplotypingPatchValidator.haplotypeStatus(for: .retainCurrent), .called)
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

    func testAcceptsDuplicateCalledLabelsAcrossSlotsAsImplicitSingleHaplotype() throws {
        let registry = makeRegistryWithoutManualReview()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(patchOpID: "patch-001", slot: "h1", haplotypeLabel: "M9B"),
                makeCall(patchOpID: "patch-002", slot: "h2", haplotypeLabel: "M9B"),
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.map(\.proposedHaplotypeLabel), ["M9B", "M9B"])
        XCTAssertEqual(report.normalizedCalls.map(\.status), [.called, .called])
    }

    func testAcceptsDuplicateLabelsAcrossRetainedAndCalledSlotsAsImplicitSingleHaplotype() throws {
        let registry = makeRegistryWithoutManualReview()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    patchOpID: "patch-001",
                    slot: "h1",
                    haplotypeLabel: "M9B",
                    sourceState: .current,
                    callState: .retainCurrent,
                    supportEvidenceRefs: ["current:DW472:MHC-B:h1"],
                    counterevidenceRefs: ["current:DW472:MHC-B:h1"]
                ),
                makeCall(
                    patchOpID: "patch-002",
                    slot: "h2",
                    haplotypeLabel: "M9B"
                ),
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.map(\.proposedHaplotypeLabel), ["M9B", "M9B"])
        XCTAssertEqual(report.normalizedCalls.map(\.status), [.called, .called])
    }

    func testDuplicateLabelsAcrossSlotsDoNotPreemptCallStateValidation() throws {
        let registry = makeRegistryWithoutManualReview()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(patchOpID: "patch-001", slot: "h1", haplotypeLabel: "M9B"),
                makeCall(
                    patchOpID: "patch-002",
                    slot: "h2",
                    haplotypeLabel: "M9B",
                    callState: .lowSupportOrDropout,
                    supportEvidenceRefs: [],
                    counterevidenceRefs: ["sample:DW472"]
                ),
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.map(\.proposedHaplotypeLabel), ["M9B", "M9B"])
        XCTAssertEqual(report.normalizedCalls.map(\.status), [.called, .noHaplotype])
    }

    func testAcceptsDuplicateProposedLabelsAcrossSlotsWhenHomozygousRationaleIsExplicit() throws {
        let registry = makeRegistryWithoutManualReview()
        let result = makeResult(
            registry: registry,
            calls: [
                makeCall(
                    patchOpID: "patch-001",
                    slot: "h1",
                    haplotypeLabel: "M9B",
                    rationaleCode: "homozygous_m9b_support",
                    rationale: "Dominant marker support is consistent with a homozygous M9B call."
                ),
                makeCall(
                    patchOpID: "patch-002",
                    slot: "h2",
                    haplotypeLabel: "M9B",
                    rationaleCode: "homozygous_m9b_support",
                    rationale: "No credible second-haplotype marker pattern; homozygous M9B is reviewable."
                ),
            ]
        )

        let report = AIHaplotypingPatchValidator(registry: registry).validate(result)

        XCTAssertTrue(report.accepted)
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.normalizedCalls.map(\.proposedHaplotypeLabel), ["M9B", "M9B"])
        XCTAssertEqual(report.normalizedCalls.map(\.status), [.called, .called])
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

    func makeRegistryWithMHCLEvidence() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci + [
                LocusEvidence(id: "locus:MHC-L", locus: "MHC-L")
            ],
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-L:Mafa-L*01:06:01:01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-L",
                    genotype: "Mafa-L*01:06:01:01",
                    passedAlignments: 38,
                    passedUniqueReads: 20,
                    sampleUniqueRetainedReads: 130
                )
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithDQDPEvidence() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci + [
                LocusEvidence(id: "locus:MHC-DQ", locus: "MHC-DQ"),
                LocusEvidence(id: "locus:MHC-DP", locus: "MHC-DP"),
                LocusEvidence(id: "locus:MHC-L", locus: "MHC-L"),
            ],
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW472:MHC-DP:MCM_MHC_MiSeq_0153",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW472",
                    locusID: "locus:MHC-DP",
                    genotype: "MCM_MHC_MiSeq_0153",
                    passedAlignments: 120,
                    passedUniqueReads: 95,
                    sampleUniqueRetainedReads: 180
                ),
                ObservationEvidence(
                    id: "obs:DW472:MHC-A:MCM_MHC_MiSeq_0068",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW472",
                    locusID: "locus:MHC-A",
                    genotype: "MCM_MHC_MiSeq_0068",
                    passedAlignments: 88,
                    passedUniqueReads: 70,
                    sampleUniqueRetainedReads: 180
                ),
                ObservationEvidence(
                    id: "obs:DW472:MHC-L:Mafa-L*01:06:01:01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW472",
                    locusID: "locus:MHC-L",
                    genotype: "Mafa-L*01:06:01:01",
                    passedAlignments: 40,
                    passedUniqueReads: 20,
                    sampleUniqueRetainedReads: 180
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithPipedObservation() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:04_M1M2M3M4M5M6M7_AG_06g1|AG_06_02,_AG_06_05,_AG_06_w_01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "04_M1M2M3M4M5M6M7_AG_06g1|AG_06_02,_AG_06_05,_AG_06_w_01",
                    passedAlignments: 61,
                    passedUniqueReads: 61,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithPipedAliasObservation() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:11_M2M3_E_02g2|E_02_03,_E_02_nov_12",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "11_M2M3_E_02g2|E_02_03,_E_02_nov_12",
                    passedAlignments: 61,
                    passedUniqueReads: 61,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithTrailingGObservation() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:06_M4M7_A5_30_01g",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "06_M4M7_A5_30_01g",
                    passedAlignments: 42,
                    passedUniqueReads: 42,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithTrailingNObservation() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-B:12_M5_B_167_01N",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-B",
                    genotype: "12_M5_B_167_01N",
                    passedAlignments: 42,
                    passedUniqueReads: 42,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithCollapsedMarkerObservation() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:11_M1M4_E_02g1|E_02_01,_E_02_02",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "11_M1M4_E_02g1|E_02_01,_E_02_02",
                    passedAlignments: 12,
                    passedUniqueReads: 12,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithExpandedMarkerObservation() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:04_M1M2M3M4_AG_g3ex",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "04_M1M2M3M4_AG_g3ex",
                    passedAlignments: 20,
                    passedUniqueReads: 20,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithOverlappingMarkerObservation() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:11_M4M5_E_02_nov_01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "11_M4M5_E_02_nov_01",
                    passedAlignments: 20,
                    passedUniqueReads: 20,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithTerminalAssaySuffixObservation() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:02_M3_G_02_0508_g48c_156bp",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "02_M3_G_02_0508_g48c_156bp",
                    passedAlignments: 20,
                    passedUniqueReads: 20,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithTerminalNumericSuffixObservation() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-B:12_M1_B_046_01_01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-B",
                    genotype: "12_M1_B_046_01_01",
                    passedAlignments: 1,
                    passedUniqueReads: 1,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithLeadingRegionTokenObservation() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-A:01_M1_F_01_w_06",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-A",
                    genotype: "01_M1_F_01_w_06",
                    passedAlignments: 1,
                    passedUniqueReads: 1,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithAlleleFamilySuffixObservation() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations + [
                ObservationEvidence(
                    id: "obs:DW473:MHC-B:12_M7_B11L_01_05",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW473",
                    locusID: "locus:MHC-B",
                    genotype: "12_M7_B11L_01_05",
                    passedAlignments: 61,
                    passedUniqueReads: 61,
                    sampleUniqueRetainedReads: 130
                ),
            ],
            currentCalls: base.currentCalls,
            manualReviews: base.manualReviews
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

    func makeRegistryWithPlaceholderCurrentCall() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations,
            currentCalls: [
                CurrentCallEvidence(
                    id: "current:DW472:MHC-B:h1",
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h1",
                    haplotypeLabel: "-",
                    source: .deterministic,
                    parentRevisionID: "analysis-rev-1"
                ),
            ],
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithErrorCurrentCall() -> AIHaplotypingEvidenceRegistry {
        let base = makeRegistry()
        return AIHaplotypingEvidenceRegistry(
            schemaVersion: base.schemaVersion,
            mode: base.mode,
            parentRevisionID: base.parentRevisionID,
            inputSnapshotDigest: base.inputSnapshotDigest,
            samples: base.samples,
            loci: base.loci,
            observations: base.observations,
            currentCalls: [
                CurrentCallEvidence(
                    id: "current:DW472:MHC-B:h1",
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h1",
                    haplotypeLabel: "ERR: TMH (M8B, M9B)",
                    source: .deterministic,
                    parentRevisionID: "analysis-rev-1"
                ),
            ],
            manualReviews: base.manualReviews
        )
    }

    func makeRegistryWithoutManualReview() -> AIHaplotypingEvidenceRegistry {
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
            manualReviews: []
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
