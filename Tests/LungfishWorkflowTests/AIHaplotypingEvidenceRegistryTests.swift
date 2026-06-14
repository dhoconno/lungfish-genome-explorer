import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class AIHaplotypingEvidenceRegistryTests: XCTestCase {
    func testRawONTGenotypeCallBuildsStableEvidenceIDsAndDigest() throws {
        let result = makeResult(
            calls: [
                makeCall(
                    sample: " DW472 ",
                    genotype: "12_M9_B_001_01",
                    passedAlignments: 120,
                    passedUniqueReads: 80,
                    sampleUniqueRetainedReads: 800
                )
            ]
        )

        let registry = try AIHaplotypingEvidenceBuilder.build(
            result: result,
            sidecar: nil,
            mode: .aiDiscovery,
            parentRevisionID: nil
        )
        let rebuilt = try AIHaplotypingEvidenceBuilder.build(
            result: result,
            sidecar: nil,
            mode: .aiDiscovery,
            parentRevisionID: nil
        )

        XCTAssertEqual(registry.schemaVersion, 1)
        XCTAssertEqual(registry.mode, .aiDiscovery)
        XCTAssertEqual(registry.samples, [SampleEvidence(id: "sample:DW472", sample: "DW472")])
        XCTAssertEqual(registry.loci, [LocusEvidence(id: "locus:MHC-B", locus: "MHC-B")])
        XCTAssertEqual(
            registry.observations,
            [
                ObservationEvidence(
                    id: "obs:DW472:MHC-B:12_M9_B_001_01",
                    evidenceClass: .directObservation,
                    sampleID: "sample:DW472",
                    locusID: "locus:MHC-B",
                    genotype: "12_M9_B_001_01",
                    passedAlignments: 120,
                    passedUniqueReads: 80,
                    sampleUniqueRetainedReads: 800
                )
            ]
        )
        XCTAssertTrue(registry.digest.hasPrefix("sha256:"))
        XCTAssertEqual(registry.digest.count, "sha256:".count + 64)
        XCTAssertEqual(registry.digest, rebuilt.digest)
        XCTAssertTrue(registry.inputSnapshotDigest.hasPrefix("sha256:"))
    }

    func testRegistryIncludesCurrentAICallAndManualSidecarOverrideContextInRefinementMode() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-14T00:00:00Z")
        sidecar.callOverrides = [
            GenotypeAnnotationSidecar.CallOverride(
                sample: "DW472",
                locus: "MHC-B",
                slot: .h1,
                originalCall: "M9B",
                overrideCall: "M8B",
                reasonTag: .analystJudgment,
                rationale: "Reviewer saw dropout evidence.",
                author: "curator",
                timestamp: "2026-06-14T10:00:00Z"
            )
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "test-assay",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Macaca fascicularis",
            generatedAt: "2026-06-14T09:00:00Z",
            analysisRevisionID: "analysis-rev-1",
            source: .ai,
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "MHC-B",
                            haplotype1: "M9B",
                            haplotype2: "M7B",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M9_B_001_01"]
                        )
                    ]
                )
            ]
        )
        let result = makeResult(
            calls: [makeCall(sample: "DW472", genotype: "12_M9_B_001_01")],
            activeHaplotypeAnalysisRevisionID: "analysis-rev-1",
            haplotypeAnalysis: analysis
        )

        let registry = try AIHaplotypingEvidenceBuilder.build(
            result: result,
            sidecar: sidecar,
            mode: .aiRefinement,
            parentRevisionID: "analysis-rev-1"
        )

        XCTAssertEqual(registry.mode, .aiRefinement)
        XCTAssertEqual(registry.parentRevisionID, "analysis-rev-1")
        XCTAssertEqual(
            registry.currentCalls,
            [
                CurrentCallEvidence(
                    id: "current:DW472:MHC-B:h1",
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h1",
                    haplotypeLabel: "M9B",
                    source: .ai,
                    parentRevisionID: "analysis-rev-1"
                ),
                CurrentCallEvidence(
                    id: "current:DW472:MHC-B:h2",
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h2",
                    haplotypeLabel: "M7B",
                    source: .ai,
                    parentRevisionID: "analysis-rev-1"
                )
            ]
        )
        XCTAssertEqual(
            registry.manualReviews,
            [
                ManualReviewEvidence(
                    id: "manual:DW472:MHC-B:h1",
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h1",
                    overrideCall: "M8B",
                    rationale: "Reviewer saw dropout evidence."
                )
            ]
        )
    }

    func testDiscoveryEvidenceIgnoresExistingAnalysisAndManualSidecarState() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-14T00:00:00Z")
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "DW472",
                locus: "MHC-B",
                slot: .h1,
                label: "Manual-M9B",
                colorTokenIndex: 2,
                diagnosticAlleles: ["12_M9_B_001_01"],
                notes: "Manual discovery should not leak into AI discovery."
            )
        ]
        let result = makeResult(
            calls: [makeCall(sample: "DW472", genotype: "12_M9_B_001_01")],
            activeHaplotypeAnalysisRevisionID: "analysis-rev-1",
            haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                assayID: "test-assay",
                definitionSetID: "test-definitions",
                definitionSetName: "Test definitions",
                speciesName: "Macaca fascicularis",
                analysisRevisionID: "analysis-rev-1",
                source: .deterministic,
                samples: [
                    GenotypeHaplotypeSampleAnalysis(
                        sample: "DW472",
                        calls: [
                            GenotypeHaplotypeLocusCall(
                                locus: "MHC-B",
                                sourceLocus: "MHC-B",
                                haplotype1: "M9B",
                                haplotype2: "-",
                                status: .called,
                                matchedHaplotypes: [],
                                observedGenotypeCount: 1,
                                observedGenotypes: ["12_M9_B_001_01"]
                            )
                        ]
                    )
                ]
            )
        )

        let discovery = try AIHaplotypingEvidenceBuilder.build(
            result: result,
            sidecar: sidecar,
            mode: .aiDiscovery,
            parentRevisionID: nil
        )
        let rawOnly = try AIHaplotypingEvidenceBuilder.build(
            result: makeResult(calls: [makeCall(sample: "DW472", genotype: "12_M9_B_001_01")]),
            sidecar: nil,
            mode: .aiDiscovery,
            parentRevisionID: nil
        )

        XCTAssertTrue(discovery.currentCalls.isEmpty)
        XCTAssertTrue(discovery.manualReviews.isEmpty)
        XCTAssertEqual(discovery.inputSnapshotDigest, rawOnly.inputSnapshotDigest)
    }

    func testRefinementEvidenceIncludesManualHaplotypeAssignments() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-14T00:00:00Z")
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "DW472",
                locus: "MHC-B",
                slot: .h2,
                label: "Manual-M7B",
                colorTokenIndex: 3,
                diagnosticAlleles: ["12_M7_B_001_01"],
                notes: "Analyst-defined manual haplotype."
            )
        ]
        let result = makeResult(
            calls: [
                makeCall(sample: "DW472", genotype: "12_M9_B_001_01"),
                makeCall(sample: "DW472", genotype: "12_M7_B_001_01"),
            ],
            haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                assayID: "test-assay",
                definitionSetID: "test-definitions",
                definitionSetName: "Test definitions",
                speciesName: "Macaca fascicularis",
                source: .deterministic,
                samples: []
            )
        )

        let registry = try AIHaplotypingEvidenceBuilder.build(
            result: result,
            sidecar: sidecar,
            mode: .aiRefinement,
            parentRevisionID: nil
        )

        XCTAssertEqual(
            registry.manualReviews,
            [
                ManualReviewEvidence(
                    id: "manual:DW472:MHC-B:h2",
                    sample: "DW472",
                    locus: "MHC-B",
                    slot: "h2",
                    overrideCall: "Manual-M7B",
                    rationale: "Analyst-defined manual haplotype."
                )
            ]
        )
        XCTAssertTrue(registry.evidenceIDs.contains("manual:DW472:MHC-B:h2"))
    }

    func testChunkerCreatesDeterministicChunkIDsAndRecomputesChunkDigests() throws {
        let result = makeResult(
            calls: [
                makeCall(sample: "DW472", genotype: "12_M9_B_001_01"),
                makeCall(sample: "DW473", genotype: "12_M7_A_001_01")
            ]
        )
        let registry = try AIHaplotypingEvidenceBuilder.build(
            result: result,
            sidecar: nil,
            mode: .aiDiscovery,
            parentRevisionID: nil
        )

        let chunks = try AIHaplotypingEvidenceChunker(maxObservationsPerChunk: 1).chunks(from: registry)

        XCTAssertEqual(chunks.map(\.id), ["chunk-0001", "chunk-0002"])
        XCTAssertEqual(chunks[0].allowedEvidenceIDs, [
            chunks[0].registry.loci[0].id,
            chunks[0].registry.observations[0].id,
            chunks[0].registry.samples[0].id,
        ])
        XCTAssertEqual(chunks[1].allowedEvidenceIDs, [
            chunks[1].registry.loci[0].id,
            chunks[1].registry.observations[0].id,
            chunks[1].registry.samples[0].id,
        ])
        XCTAssertNotEqual(chunks[0].registry.digest, registry.digest)
        XCTAssertNotEqual(chunks[1].registry.digest, registry.digest)
        XCTAssertNotEqual(chunks[0].registry.digest, chunks[1].registry.digest)
        XCTAssertEqual(chunks[0].registry.inputSnapshotDigest, registry.inputSnapshotDigest)
        XCTAssertEqual(chunks[1].registry.inputSnapshotDigest, registry.inputSnapshotDigest)
    }

    func testDuplicateRawRowsReceiveDeterministicDistinctObservationIDs() throws {
        let result = makeResult(
            calls: [
                makeCall(sample: "DW472", genotype: "12_M9_B_001_01", passedAlignments: 10),
                makeCall(sample: "DW472", genotype: "12_M9_B_001_01", passedAlignments: 11),
            ]
        )

        let registry = try AIHaplotypingEvidenceBuilder.build(
            result: result,
            sidecar: nil,
            mode: .aiDiscovery,
            parentRevisionID: nil
        )

        XCTAssertEqual(registry.observations.map(\.id), [
            "obs:DW472:MHC-B:12_M9_B_001_01#row-0001",
            "obs:DW472:MHC-B:12_M9_B_001_01#row-0002",
        ])
        XCTAssertEqual(Set(registry.observations.map(\.id)).count, 2)
    }

    func testChunkerKeepsSampleLocusEvidenceClustersClosedAndAllowsAllChunkEvidenceIDs() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-14T00:00:00Z")
        sidecar.callOverrides = [
            GenotypeAnnotationSidecar.CallOverride(
                sample: "DW472",
                locus: "MHC-B",
                slot: .h1,
                originalCall: "M9B",
                overrideCall: "Manual-M9B",
                reasonTag: .analystJudgment,
                rationale: "Manual review context.",
                author: "curator",
                timestamp: "2026-06-14T10:00:00Z"
            )
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "test-assay",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Macaca fascicularis",
            analysisRevisionID: "analysis-rev-1",
            source: .ai,
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "MHC-B",
                            haplotype1: "M9B",
                            haplotype2: "M7B",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M9_B_001_01", "12_M7_B_001_01"]
                        )
                    ]
                )
            ]
        )
        let result = makeResult(
            calls: [
                makeCall(sample: "DW472", genotype: "12_M9_B_001_01"),
                makeCall(sample: "DW472", genotype: "12_M7_B_001_01"),
                makeCall(sample: "DW473", genotype: "12_M8_A_001_01"),
            ],
            activeHaplotypeAnalysisRevisionID: "analysis-rev-1",
            haplotypeAnalysis: analysis
        )
        let registry = try AIHaplotypingEvidenceBuilder.build(
            result: result,
            sidecar: sidecar,
            mode: .aiRefinement,
            parentRevisionID: "analysis-rev-1"
        )

        let chunks = try AIHaplotypingEvidenceChunker(maxObservationsPerChunk: 1).chunks(from: registry)

        XCTAssertEqual(chunks.map(\.id), ["chunk-0001", "chunk-0002"])
        XCTAssertEqual(chunks[0].registry.observations.map(\.id), [
            "obs:DW473:MHC-A:12_M8_A_001_01",
        ])
        XCTAssertEqual(chunks[1].registry.observations.map(\.id), [
            "obs:DW472:MHC-B:12_M7_B_001_01",
            "obs:DW472:MHC-B:12_M9_B_001_01",
        ])
        XCTAssertEqual(chunks[1].allowedEvidenceIDs, [
            "current:DW472:MHC-B:h1",
            "current:DW472:MHC-B:h2",
            "locus:MHC-B",
            "manual:DW472:MHC-B:h1",
            "obs:DW472:MHC-B:12_M7_B_001_01",
            "obs:DW472:MHC-B:12_M9_B_001_01",
            "sample:DW472",
        ])
    }

    private func makeCall(
        sample: String,
        genotype: String,
        passedAlignments: Int = 42,
        passedUniqueReads: Int = 21,
        sampleUniqueRetainedReads: Int? = nil
    ) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: passedAlignments,
            passedUniqueReads: passedUniqueReads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: sampleUniqueRetainedReads,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    private func makeResult(
        calls: [ONTGenotypeCall],
        activeHaplotypeAnalysisRevisionID: String? = nil,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil
    ) -> ONTGenotypeResultBundleData {
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "out",
            analysisName: "Test",
            primaryWorkbookPath: "workbook.xlsx",
            longSummaryCSVPath: "long.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json",
            activeHaplotypeAnalysisRevisionID: activeHaplotypeAnalysisRevisionID
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: URL(fileURLWithPath: "/tmp/workbook.xlsx"),
            longSummaryCSVURL: URL(fileURLWithPath: "/tmp/long.csv"),
            sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/samples.csv"),
            statsJSONURL: URL(fileURLWithPath: "/tmp/stats.json"),
            provenanceURL: URL(fileURLWithPath: "/tmp/provenance.json")
        )
        return ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/out.lungfishgenotype"),
            manifest: manifest,
            artifacts: artifacts,
            stats: ONTGenotypeRunStats(),
            calls: calls,
            samples: [],
            haplotypeAnalysis: haplotypeAnalysis
        )
    }
}
