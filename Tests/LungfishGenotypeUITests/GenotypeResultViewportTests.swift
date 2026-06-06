import XCTest
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit

@MainActor
final class GenotypeResultViewportTests: XCTestCase {
    func testViewportPublishesSharedGenotypeSelectionForInspector() {
        let controller = GenotypeResultViewController()
        _ = controller.view

        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02",
                passedAlignments: 42,
                passedUniqueReads: 39,
                sampleTotalReads: 100,
                sampleUniqueRetainedReads: 39,
                sampleUniqueRetainedPercent: 39,
                overallInputReads: 1000,
                overallUniqueRetainedReads: 60,
                overallUniqueRetainedPercent: 6
            )
        ]
        let result = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60),
            calls: calls,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 42,
                    passedUniqueReads: 39,
                    sampleTotalReads: 100,
                    sampleUniqueRetainedPercent: 39,
                    calls: calls
                )
            ]
        )

        var selectedState: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { state in
            selectedState = state
        }

        controller.configure(result: result)
        controller.testingSelectFirstSharedCall()

        XCTAssertEqual(selectedState?.title, "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02")
        XCTAssertTrue(selectedState?.detailRows.contains(where: { $0.0 == "Locus" && $0.1 == "MHC-DQB1" }) ?? false)
        XCTAssertTrue(selectedState?.detailRows.contains(where: { $0.0 == "Samples" && $0.1 == "1" }) ?? false)
        XCTAssertTrue(selectedState?.detailRows.contains(where: { $0.0 == "Meaning" }) ?? false)
        XCTAssertTrue(selectedState?.detailRows.contains(where: { $0.0 == "Support Metric" }) ?? false)
    }

    func testViewportDoesNotGrowToFitLongGenotypeLabels() {
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 820, height: 640)

        let longGenotype = "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02,_DQB1_06_02,_DQB1_06_34"
        let calls = [
            ONTGenotypeCall(
                sample: "LF2874",
                genotype: longGenotype,
                passedAlignments: 2_945,
                passedUniqueReads: 2_945,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 19_769,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: 11_197_546,
                overallUniqueRetainedReads: 260_534,
                overallUniqueRetainedPercent: 2.326706
            )
        ]
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "LF2874",
                passedAlignments: 19_852,
                passedUniqueReads: 19_769,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls
            )
        ], calls: calls))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listLeading))

        controller.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(controller.view.fittingSize.width, 900)
        XCTAssertGreaterThanOrEqual(controller.testingSamplePaneWidth, 300)
        XCTAssertLessThanOrEqual(controller.testingDetailPaneWidth, 520)
    }

    func testLensSwitcherShowsConsumerAndArtifactsContent() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        controller.testingSelectLens(.summary)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")

        controller.testingSelectLens(.audit)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "audit")
    }

    func testAnchorLensShowsDerivedAnchorSummaryAndCaveat() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_M1_A_01",
                passedAlignments: 40,
                passedUniqueReads: 40,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "02_M1_B_01",
                passedAlignments: 30,
                passedUniqueReads: 30,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingSelectLens(.summary)

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertTrue(controller.testingAnchorLensText.contains("M1"))
        XCTAssertTrue(controller.testingAnchorLensText.contains("MHC-A, MHC-B"))
        XCTAssertTrue(controller.testingAnchorLensText.localizedCaseInsensitiveContains("not phased"))
    }

    func testHaplotypeLensShowsExplicitDefinitionAndReviewStatuses() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_Mafa_A1_063g"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "ERR: TMH (M1B, M2B, M3B)",
                            haplotype2: "ERR: TMH (M1B, M2B, M3B)",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 4,
                            observedGenotypes: ["B1", "B2", "B3", "B4"]
                        ),
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Mauritian cynomolgus macaques"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW472"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("M1A/-"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Review"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("ERR: TMH"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Review in Analyst"))
    }

    func testHaplotypeLensTreatsWholeMHCHomozygoteAsSimpleDespiteMultipleDiagnosticFamilies() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW474",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 4,
                            observedGenotypes: [
                                "11_M1_E_02g3",
                                "02_M1_G_02_07_2mis_156bp",
                                "04_M1_AG_05_3mis_156bp",
                                "01_M1_F_01_w_06",
                            ]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: [
                                "12_M3_B_075_01",
                                "12_M3_B_079_05",
                                "12_M3_B_165_01",
                            ]
                        ),
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW474"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Simple"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("None"))
        XCTAssertFalse(controller.testingHaplotypeLensText.contains("MHC-A: called"))
        XCTAssertFalse(controller.testingHaplotypeLensText.contains("MHC-B: called"))
    }

    func testHaplotypeLensKeepsMixedFamilyHomozygoteInReview() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW-mixed",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: [
                                "01_M1_F_01_w_06",
                                "02_M1_G_02_07_2mis_156bp",
                                "02_M2_G_02_06_156bp",
                            ]
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW-mixed"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Review"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("MHC-A: called"))
    }

    func testOutlineRendersSingleHaplotypeHomozygoteInBothSlots() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW474",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 4,
                            observedGenotypes: ["01_M1_F_01_w_06"]
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW474").first { $0.locus == "MHC-A" })
        XCTAssertEqual(slot.h1.testingLabel, "M1A")
        XCTAssertEqual(slot.h2.testingLabel, "M1A")
    }

    func testSelectingReviewCellMarksOutlineSampleAndLocus() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M2A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "M4B",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["B1", "B2"]
                        ),
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))

        controller.testingSelectCellEvidence(animalId: "DW472", locus: "MHC-B")

        XCTAssertEqual(controller.testingOutlineSelectedSample, "DW472")
        XCTAssertEqual(controller.testingOutlineSelectedLocus, "MHC-B")
    }

    func testDisplayStateCanSwitchViewportToHaplotypes() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "M3A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(viewportLens: .review))

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW472"))
    }

    func testHaplotypeLensCanFocusSampleInAnalystMatrix() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "M3A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        )
                    ]
                )
            ]
        )
        let call = ONTGenotypeCall(
            sample: "DW472",
            genotype: "01_Mafa_A1_063g",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(samples: [], calls: [call], haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        controller.testingReviewHaplotypeSample("DW472")

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_063g"])
    }

    func testConfirmingReviewCallMarksLocusResolvedAndAdvancesQueue() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReviewConfirm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                reviewSample("DW001"),
                reviewSample("DW002"),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: "DW001", genotype: "12_M1_B_001_01", reads: 100),
                makeCall(sample: "DW002", genotype: "12_M1_B_001_01", reads: 100),
            ],
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectLens(.review)

        XCTAssertEqual(controller.testingCurrentSelectedSample, "DW001")
        XCTAssertEqual(controller.testingCurrentCallEvidenceSample, "DW001")

        controller.testingConfirmCurrentCallEvidence()

        XCTAssertEqual(controller.testingOutlineIssueCount(sample: "DW001"), 0)
        XCTAssertEqual(controller.testingCurrentSelectedSample, "DW002")
        XCTAssertEqual(controller.testingCurrentCallEvidenceSample, "DW002")
        let sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        XCTAssertTrue(sidecar.callStatusFlags.contains {
            $0.sample == "DW001" && $0.locus == "MHC-B" && $0.value == .confirmed
        })
    }

    func testConfirmingReviewCallAdvancesWithinSameSampleBeforeNextSample() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReviewConfirmMultiLocus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                reviewSample("DW001", loci: ["MHC-B", "MHC-DRB"]),
                reviewSample("DW002", loci: ["MHC-B"]),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: "DW001", genotype: "12_M1_B_001_01", reads: 100),
                makeCall(sample: "DW001", genotype: "13_M1_DRB_W5_01", reads: 100),
                makeCall(sample: "DW002", genotype: "12_M1_B_001_01", reads: 100),
            ],
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectLens(.review)

        controller.testingConfirmCurrentCallEvidence()
        controller.testingConfirmCurrentCallEvidence()

        let sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        XCTAssertTrue(sidecar.callStatusFlags.contains {
            $0.sample == "DW001" && $0.locus == "MHC-B" && $0.value == .confirmed
        })
        XCTAssertTrue(sidecar.callStatusFlags.contains {
            $0.sample == "DW001" && $0.locus == "MHC-DRB" && $0.value == .confirmed
        })
        XCTAssertFalse(sidecar.callStatusFlags.contains {
            $0.sample == "DW002" && $0.locus == "MHC-B" && $0.value == .confirmed
        })
        XCTAssertEqual(controller.testingCurrentSelectedSample, "DW002")
        XCTAssertEqual(controller.testingOutlineIssueCount(sample: "DW001"), 0)
    }

    private func reviewSample(
        _ sample: String,
        loci: [String] = ["MHC-B"]
    ) -> GenotypeHaplotypeSampleAnalysis {
        GenotypeHaplotypeSampleAnalysis(
            sample: sample,
            calls: loci.map { locus in
                GenotypeHaplotypeLocusCall(
                    locus: locus,
                    sourceLocus: locus == "MHC-DRB" ? "Mafa-DRB" : "Mafa-B",
                    haplotype1: locus == "MHC-DRB" ? "ERR: TMH (M1DR, M2DR, M3DR)" : "ERR: TMH (M1B, M2B, M3B)",
                    haplotype2: locus == "MHC-DRB" ? "ERR: TMH (M1DR, M2DR, M3DR)" : "ERR: TMH (M1B, M2B, M3B)",
                    status: .tooManyHaplotypes,
                    matchedHaplotypes: [],
                    observedGenotypeCount: 4,
                    observedGenotypes: locus == "MHC-DRB" ? ["DRB1", "DRB2", "DRB3", "DRB4"] : ["B1", "B2", "B3", "B4"]
                )
            }
        )
    }

    func testReviewLensUsesNeedsReviewCohortIncludingLowSupportSamples() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReviewNeedsReview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let lowCalls = [
            makeCall(sample: "LowSupport", genotype: "12_M3_B_075_01", reads: 2),
            makeCall(sample: "LowSupport", genotype: "12_M3_B_165_01", reads: 2),
        ]
        let okCalls = [
            makeCall(sample: "OKSample", genotype: "12_M3_B_075_01", reads: 100),
            makeCall(sample: "OKSample", genotype: "12_M3_B_165_01", reads: 80),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                calledReviewSample("LowSupport"),
                calledReviewSample("OKSample"),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "LowSupport",
                    passedAlignments: 10,
                    passedUniqueReads: 4,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: lowCalls
                ),
                ONTGenotypeSampleResult(
                    sample: "OKSample",
                    passedAlignments: 100,
                    passedUniqueReads: 180,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: okCalls
                ),
            ],
            calls: lowCalls + okCalls,
            haplotypeAnalysis: analysis
        ))

        controller.testingSelectLens(.review)

        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LowSupport"])
        XCTAssertEqual(controller.testingSavedCohortChipTitle, "Saved: Needs review")
    }

    func testOutlineCellSelectionShowsEvidenceWithoutActivatingNeedsReviewCohort() throws {
        let lowCalls = [
            makeCall(sample: "LowSupport", genotype: "12_M3_B_075_01", reads: 2),
            makeCall(sample: "LowSupport", genotype: "12_M3_B_165_01", reads: 2),
        ]
        let okCalls = [
            makeCall(sample: "OKSample", genotype: "12_M3_B_075_01", reads: 100),
            makeCall(sample: "OKSample", genotype: "12_M3_B_165_01", reads: 80),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                calledReviewSample("LowSupport"),
                calledReviewSample("OKSample"),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "LowSupport",
                    passedAlignments: 10,
                    passedUniqueReads: 4,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: lowCalls
                ),
                ONTGenotypeSampleResult(
                    sample: "OKSample",
                    passedAlignments: 100,
                    passedUniqueReads: 180,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: okCalls
                ),
            ],
            calls: lowCalls + okCalls,
            haplotypeAnalysis: analysis
        ))

        controller.testingSelectCellEvidence(animalId: "OKSample", locus: "MHC-B")

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertEqual(controller.testingCurrentCallEvidenceSample, "OKSample")
        XCTAssertNil(controller.testingSavedCohortChipTitle)
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LowSupport", "OKSample"])
    }

    private func calledReviewSample(_ sample: String) -> GenotypeHaplotypeSampleAnalysis {
        GenotypeHaplotypeSampleAnalysis(
            sample: sample,
            calls: [
                GenotypeHaplotypeLocusCall(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotype1: "M3B",
                    haplotype2: "-",
                    status: .called,
                    matchedHaplotypes: [],
                    observedGenotypeCount: 1,
                    observedGenotypes: ["12_M3_B_075_01"]
                )
            ]
        )
    }

    func testLocusFilterKeepsAGSeparateFromClassicalA() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "DW472",
                genotype: "01_Mafa_A1_063g|A1_063_01,_A1_063_02",
                passedAlignments: 148,
                passedUniqueReads: 148,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "DW472",
                genotype: "18_Mafa_AG_05_AG_06g|AG_05_02_01,_AG_06_04",
                passedAlignments: 204,
                passedUniqueReads: 204,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))

        XCTAssertEqual(controller.testingLocusFilterTitles, ["All Loci", "MHC-A", "MHC-AG"])
    }

    func testMatrixDefaultsToAlleleNameSort() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "02_Mafa_A2_001_01",
                passedAlignments: 300,
                passedUniqueReads: 300,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 20,
                passedUniqueReads: 20,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))

        XCTAssertEqual(controller.testingVisibleGenotypes, [
            "01_Mafa_A1_001_01",
            "02_Mafa_A2_001_01",
        ])
    }

    func testSelectingRowDoesNotBecomeLocusFilter() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 20,
                passedUniqueReads: 20,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "04_Mafa_B_001_01",
                passedAlignments: 30,
                passedUniqueReads: 30,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingSelectFirstSampleCell(sample: "AnimalA")
        controller.testingSetComparisonFilter("")

        XCTAssertEqual(controller.testingVisibleGenotypes, [
            "01_Mafa_A1_001_01",
            "04_Mafa_B_001_01",
        ])
    }

    func testComparisonMatrixExportSnapshotUsesCohortSampleColumns() {
        let matrix = GenotypeComparisonMatrixView()
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW474", genotype: "12_M3_B_075_01", reads: 119),
        ]
        matrix.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "DW472",
                passedAlignments: 148,
                passedUniqueReads: 148,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[0]]
            ),
            ONTGenotypeSampleResult(
                sample: "DW474",
                passedAlignments: 119,
                passedUniqueReads: 119,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[1]]
            ),
        ], calls: calls))

        matrix.applyCohortFilter(["DW472"])
        let snapshot = matrix.exportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            analysisName: "Example",
            lens: "summary.matrix"
        )

        XCTAssertEqual(snapshot.sampleNames, ["DW472"])
        XCTAssertEqual(snapshot.rows.first?.sampleReads, ["DW472": 148])
    }

    func testControllerExportSnapshotIncludesSavedFilterContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeExportContext-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW474", genotype: "12_M3_B_075_01", reads: 119),
        ]
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "DW472",
                passedAlignments: 148,
                passedUniqueReads: 148,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[0]]
            ),
            ONTGenotypeSampleResult(
                sample: "DW474",
                passedAlignments: 119,
                passedUniqueReads: 119,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[1]]
            ),
        ], calls: calls))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix))

        controller.testingSetUnifiedSampleFilter("DW472")
        try controller.testingSaveCurrentFilterAsSmartCohort()
        controller.testingSetUnifiedSampleFilter("")
        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())

        XCTAssertEqual(snapshot.sampleNames, ["DW472"])
        XCTAssertEqual(snapshot.filters["activeSmartCohortName"], "Filter: DW472")
        XCTAssertEqual(snapshot.filters["activeSmartCohortScope"], "bundle")
        XCTAssertTrue(snapshot.filters["activeSmartCohortPredicate"]?.contains("DW472") ?? false)
    }

    func testControllerExportSnapshotUsesVisibleHaplotypeMatrixRows() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())

        XCTAssertEqual(snapshot.lens, "summary.matrix.haplotypeDefinitions")
        XCTAssertTrue(snapshot.sampleNames.contains("12_M3_B_075_01"))
        XCTAssertTrue(snapshot.rows.contains { $0.genotype == "M3B" && $0.locus == "DW472 MHC-B" })
        XCTAssertFalse(snapshot.rows.contains { $0.genotype == "12_M3_B_075_01" })
    }

    func testExportRevealTargetsExportedWorkbookFile() {
        let controller = GenotypeResultViewController()
        let outputURL = URL(fileURLWithPath: "/tmp/export.xlsx")
        let result = GenotypeViewportExportResult(
            outputURL: outputURL,
            provenanceURL: outputURL.appendingPathExtension("lungfish-provenance.json")
        )

        XCTAssertEqual(controller.testingFileViewerSelectionURLs(for: result), [outputURL])
    }

    func testDisplayStateCanMoveListRightAndTop() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTrailing))

        XCTAssertTrue(controller.testingSplitIsVertical)
        XCTAssertFalse(controller.testingFirstPaneIsMatrix)

        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTop))

        XCTAssertFalse(controller.testingSplitIsVertical)
        XCTAssertTrue(controller.testingFirstPaneIsMatrix)
    }

    func testTopLayoutSplitMinimumsLeaveUsableViewportContent() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTop))

        let extents = controller.testingMinimumSplitExtents

        XCTAssertGreaterThanOrEqual(extents.leading, 128)
        XCTAssertGreaterThanOrEqual(extents.trailing, 100)
    }

    func testSplitMaxCoordinateReservesTrailingPaneAndDivider() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTop))

        let maxCoordinate = controller.testingConstrainedMaxSplitCoordinate(containerExtent: 600)

        XCTAssertEqual(
            maxCoordinate,
            600 - controller.testingSplitDividerThickness - controller.testingMinimumSplitExtents.trailing,
            accuracy: 0.5
        )
    }

    func testSupportThresholdFiltersRowsAndCells() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let high = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 990,
            passedUniqueReads: 990,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 1_000,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let low = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_002_01",
            passedAlignments: 9,
            passedUniqueReads: 9,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 1_000,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(samples: [], calls: [high, low]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: true, minimumSupportPercent: 1.0))

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }

    func testMinimumReadsThresholdHidesRowsWhoseEverySupporterIsBelowThreshold() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let highRow = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_HIGH", reads: 6_000)
        let lowRow = makeCall(sample: "AnimalB", genotype: "01_Mafa_A1_LOW", reads: 1_000)
        controller.configure(result: makeResult(samples: [], calls: [highRow, lowRow]))

        // With the filter off (default 0) both rows stay visible.
        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: false, minimumReads: 0))
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_HIGH", "01_Mafa_A1_LOW"])

        // At 5,000 the low-support row drops because its only supporter has 1,000 reads.
        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: false, minimumReads: 5_000))
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_HIGH"])
    }

    func testMinimumReadsThresholdKeepsRowWithAtLeastOneSupporterAboveThreshold() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        // One shared genotype supported by a strong sample and a weak sample.
        let strong = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_SHARED", reads: 6_000)
        let weak = makeCall(sample: "AnimalB", genotype: "01_Mafa_A1_SHARED", reads: 1_000)
        controller.configure(result: makeResult(samples: [], calls: [strong, weak]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: false, minimumReads: 5_000))

        // The row survives because at least one supporter clears the threshold.
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_SHARED"])
    }

    func testFilteredSampleCellsCanHideManualRowHighlights() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let sharedGenotype = "01_Mafa_A1_001_01"
        let denominatorGenotype = "02_Mafa_A2_001_01"
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: sharedGenotype,
                passedAlignments: 5,
                passedUniqueReads: 5,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 1_000,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalB",
                genotype: sharedGenotype,
                passedAlignments: 100,
                passedUniqueReads: 100,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 100,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: denominatorGenotype,
                passedAlignments: 995,
                passedUniqueReads: 995,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 1_000,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]
        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.applyHighlight(GenotypeResultHighlightRequest(
            target: GenotypeResultHighlightTarget(genotype: sharedGenotype, locus: "MHC-A"),
            scope: .selectedRow,
            channel: .fill,
            color: AnnotationColor(red: 0.9, green: 0.2, blue: 0.7, alpha: 1.0)
        ))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            hideLowSupport: true,
            minimumSupportPercent: 1.0,
            hideFilteredHighlights: true
        ))

        XCTAssertNil(controller.testingBackgroundColor(genotype: sharedGenotype, sample: "AnimalA"))
        XCTAssertNotNil(controller.testingBackgroundColor(genotype: sharedGenotype, sample: "AnimalB"))
    }

    func testMatrixSearchMatchesImportedSampleMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try """
        Sample\tCohort
        AnimalA\ttreated
        """.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"), atomically: true, encoding: .utf8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )

        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))
        controller.testingSetComparisonFilter("treated")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }

    func testUnifiedMatrixFilterAppliesGenotypeTextAsRowFilter() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "04_Mafa_B_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]
        controller.configure(result: makeResult(samples: [], calls: calls))

        controller.testingSetUnifiedSampleFilter("MHC-B")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
    }

    func testUnifiedMatrixFilterMatchesMetadataFieldQueries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try """
        Sample\tCohort
        AnimalA\ttreated
        AnimalB\tcontrol
        """.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"), atomically: true, encoding: .utf8)
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalB",
                genotype: "02_Mafa_A2_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: calls))

        controller.testingSetUnifiedSampleFilter("Cohort=treated")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }

    func testApplyingImportedSampleMetadataRefreshesExistingMatrixSearch() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )

        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.testingSetComparisonFilter("treated")
        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)

        let metadata = Data("""
        Sample\tCohort
        AnimalA\ttreated
        """.utf8)
        let store = try SampleMetadataStore(csvData: metadata, knownSampleIds: ["AnimalA"])
        controller.applySampleMetadataStore(store)

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }

    func testUnifiedSampleFilterMatchesImportedMetadataFieldsInOutline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try """
        Sample\tCohort\tAnimal Type
        AnimalA\ttreated\tcase
        AnimalB\tcontrol\tcontrol
        """.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"), atomically: true, encoding: .utf8)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "AnimalA",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["A1"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "AnimalB",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["A2"]
                        )
                    ]
                ),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [], haplotypeAnalysis: analysis))

        controller.testingSetUnifiedSampleFilter("Cohort=treated")

        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["AnimalA"])
    }

    func testSaveCurrentFilterPersistsMetadataSmartCohortWithAudit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: []))
        controller.testingSetUnifiedSampleFilter("Cohort=Kenyon20")

        try controller.testingSaveCurrentFilterAsSmartCohort()

        let sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        let saved = sidecar.smartCohorts.first { $0.name == "Filter: Cohort=Kenyon20" }
        XCTAssertEqual(saved?.predicate, .metadataFieldContains(field: "Cohort", value: "Kenyon20"))
        XCTAssertTrue(sidecar.auditLog.contains { $0.action == "saveSmartCohort" && $0.after?.contains("Cohort=Kenyon20") == true })
    }

    func testSavedTextFilterRoundTripsAsMatrixRowFilter() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
            makeCall(sample: "AnimalA", genotype: "04_Mafa_B_001_01", reads: 42),
        ]
        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingSetUnifiedSampleFilter("MHC-B")
        try controller.testingSaveCurrentFilterAsSmartCohort()
        controller.testingSetUnifiedSampleFilter("")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
    }

    func testScopedSaveCurrentFilterOnlyMutatesMatchingWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleA = root.appendingPathComponent("a.lungfishgenotype", isDirectory: true)
        let bundleB = root.appendingPathComponent("b.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleB, withIntermediateDirectories: true)
        let scopeA = WindowStateScope()
        let scopeB = WindowStateScope()
        let controllerA = GenotypeResultViewController()
        let controllerB = GenotypeResultViewController()
        controllerA.windowStateScope = scopeA
        controllerB.windowStateScope = scopeB
        _ = controllerA.view
        _ = controllerB.view
        controllerA.configure(result: makeResult(bundleURL: bundleA, samples: [], calls: []))
        controllerB.configure(result: makeResult(bundleURL: bundleB, samples: [], calls: []))
        controllerA.testingSetUnifiedSampleFilter("Cohort=Kenyon20")
        controllerB.testingSetUnifiedSampleFilter("Cohort=Control")

        NotificationCenter.default.post(
            name: .genotypeResultSmartCohortSaveRequested,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: scopeA]
        )

        let sidecarA = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleA)
        let sidecarB = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleB)
        XCTAssertTrue(sidecarA.smartCohorts.contains { $0.name == "Filter: Cohort=Kenyon20" })
        XCTAssertFalse(sidecarB.smartCohorts.contains { $0.name == "Filter: Cohort=Control" })
    }

    func testOutlineLayoutLeavesViewportVisibleBelowQuickFilterBar() throws {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M2A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_500, height: 900)
        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .outline, layout: .listTop))

        controller.view.layoutSubtreeIfNeeded()

        let quickFilterBar = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeQuickFilterBarView.self))
        let outlineView = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeOutlineView.self))
        XCTAssertLessThanOrEqual(quickFilterBar.frame.height, 72)
        XCTAssertGreaterThan(outlineView.frame.height, 200)
    }

    func testMatrixViewShowsDiagnosticGenotypesUsedForHaplotypeDefinitions() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
            makeCall(sample: "DW472", genotype: "12_M2_B_019_03", reads: 123),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "M2B",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_098_05", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M2B",
                                    diagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04", "12_M2_B_150_01_01", "12_M2_B_162"],
                                    observedDiagnosticAlleles: ["12_M2_B_019_03"]
                                ),
                            ],
                            observedGenotypeCount: 3,
                            observedGenotypes: ["12_M2_B_019_03", "12_M3_B_075_01", "12_M3_B_165_01"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        let text = controller.testingHaplotypeMatrixText

        XCTAssertTrue(text.contains("Diagnostic allele matrix"))
        XCTAssertTrue(text.contains("DW472"))
        XCTAssertTrue(text.contains("MHC-B"))
        XCTAssertTrue(text.contains("M3B"))
        XCTAssertTrue(text.contains("12_M3_B_075_01"))
        XCTAssertTrue(text.contains("12_M3_B_098_05 [not observed]"))
        XCTAssertTrue(text.contains("M2B"))
        XCTAssertTrue(text.contains("12_M2_B_019_03"))
    }

    func testObservedOnlyLociSwitchesMatrixToSharedGenotypeRows() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
            makeCall(sample: "DW472", genotype: "04_M3_AG_04g1_156bp", reads: 100),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            summaryViewMode: .matrix,
            layout: .listTop,
            showsAncillaryLoci: true
        ))

        let haplotypeMatrix = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self))
        let sharedMatrix = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeComparisonMatrixView.self))

        XCTAssertTrue(haplotypeMatrix.isHidden)
        XCTAssertFalse(sharedMatrix.isHidden)
        XCTAssertTrue(controller.testingVisibleGenotypes.contains("04_M3_AG_04g1_156bp"))
    }

    func testHaplotypeDefinitionMatrixHeadersExposeSortDescriptors() throws {
        let view = GenotypeHaplotypeDefinitionMatrixView()
        view.configure(rows: [
            GenotypeHaplotypeDefinitionMatrixView.Row(
                sample: "DW472",
                locus: "MHC-B",
                callName: "M3B",
                haplotypeName: "M3B",
                observedCount: 2,
                diagnosticCount: 3,
                minimumMatches: 2,
                status: .called,
                alleles: [GenotypeHaplotypeDefinitionMatrixView.DiagnosticAllele(name: "12_M3_B_075_01", reads: 100)]
            ),
            GenotypeHaplotypeDefinitionMatrixView.Row(
                sample: "DW472",
                locus: "MHC-A",
                callName: "M1A",
                haplotypeName: "M1A",
                observedCount: 1,
                diagnosticCount: 4,
                minimumMatches: 2,
                status: .candidate,
                alleles: [GenotypeHaplotypeDefinitionMatrixView.DiagnosticAllele(name: "01_M1_F_01_w_06", reads: 30)]
            ),
        ], definitionName: "Test")

        let table = try XCTUnwrap(view.firstDescendant(ofType: NSTableView.self))
        XCTAssertTrue(table.tableColumns.allSatisfy { $0.sortDescriptorPrototype != nil })
    }

    func testHaplotypeMatrixSearchFiltersDefinitionRowsRatherThanWholeSamples() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "01_M1_F_01_w_06", reads: 200),
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1A",
                                    diagnosticAlleles: ["01_M1_F_01_w_06"],
                                    observedDiagnosticAlleles: ["01_M1_F_01_w_06"]
                                ),
                            ],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_M1_F_01_w_06"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        ),
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        controller.testingSetUnifiedSampleFilter("MHC-B")

        let text = controller.testingHaplotypeMatrixText
        XCTAssertTrue(text.contains("MHC-B"))
        XCTAssertTrue(text.contains("M3B"))
        XCTAssertTrue(text.contains("12_M3_B_075_01"))
        XCTAssertFalse(text.contains("MHC-A"))
        XCTAssertFalse(text.contains("M1A"))
        XCTAssertFalse(text.contains("01_M1_F_01_w_06"))
    }

    func testHaplotypeMatrixUsesSavedTextFilterWhenQuickSearchIsCleared() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSavedMatrixFilter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "01_M1_F_01_w_06", reads: 200),
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1A",
                                    diagnosticAlleles: ["01_M1_F_01_w_06"],
                                    observedDiagnosticAlleles: ["01_M1_F_01_w_06"]
                                ),
                            ],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_M1_F_01_w_06"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        ),
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        controller.testingSetUnifiedSampleFilter("MHC-B")
        try controller.testingSaveCurrentFilterAsSmartCohort()
        controller.testingSetUnifiedSampleFilter("")

        let text = controller.testingHaplotypeMatrixText
        XCTAssertTrue(text.contains("MHC-B"))
        XCTAssertTrue(text.contains("M3B"))
        XCTAssertTrue(text.contains("12_M3_B_075_01"))
        XCTAssertFalse(text.contains("MHC-A"))
        XCTAssertFalse(text.contains("M1A"))
        XCTAssertFalse(text.contains("01_M1_F_01_w_06"))
    }

    func testSavingActiveHaplotypeDefinitionRefreshesLiveCalls() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeActiveDefinition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.active-definition"
        let store = HaplotypeDefinitionStore(projectRoot: projectRoot)
        try store.save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "OldB",
            diagnosticAllele: "12_M8_B_001_01"
        ))
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "DW472",
                    passedAlignments: 150,
                    passedUniqueReads: 150,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ],
            calls: calls,
            haplotypeDefinitionSetID: definitionID
        ))
        XCTAssertEqual(controller.callEvidence(sample: "DW472", locus: "MHC-B")?.h1Name, "ERR: NO HAP")

        try controller.testingSaveHaplotypeDefinition(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "NewB",
            diagnosticAllele: "12_M9_B_001_01"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "NewB")
        XCTAssertEqual(evidence.status, .called)
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))
        XCTAssertTrue(controller.testingHaplotypeMatrixText.contains("NewB"))
        XCTAssertFalse(controller.testingHaplotypeMatrixText.contains("OldB"))
    }

    func testUsingCustomHaplotypeDefinitionPersistsActiveDefinitionAndRefreshesCalls() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeUseDefinition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.use-definition"
        let customDefinition = makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "NewB",
            diagnosticAllele: "12_M9_B_001_01"
        )
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(customDefinition)
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "DW472",
                    passedAlignments: 150,
                    passedUniqueReads: 150,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ],
            calls: calls,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))
        XCTAssertNotEqual(controller.callEvidence(sample: "DW472", locus: "MHC-B")?.h1Name, "NewB")

        try controller.testingUseHaplotypeDefinition(id: definitionID)

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "NewB")
        XCTAssertEqual(evidence.status, .called)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
        XCTAssertEqual(sidecar.settings.activeHaplotypeDefinitionSetID, definitionID)
        XCTAssertEqual(sidecar.settings.activeHaplotypeAssayID, "custom-assay")
        XCTAssertTrue(sidecar.auditLog.contains { entry in
            entry.action == "updateSettings" && (entry.after?.contains(definitionID) ?? false)
        })
        let definitionURL = try XCTUnwrap(HaplotypeDefinitionStore(projectRoot: projectRoot).definitionURL(for: definitionID))
        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())
        XCTAssertTrue(snapshot.provenanceInputURLs.contains(definitionURL))
        XCTAssertEqual(snapshot.filters["activeHaplotypeDefinitionSetID"], definitionID)
        XCTAssertEqual(snapshot.filters["activeHaplotypeAssayID"], "custom-assay")
    }

    func testReviewEvidenceIncludesCrossFamilyMCMClassIDiagnostics() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW474", genotype: "01_M1_F_01_w_06", reads: 200),
            makeCall(sample: "DW474", genotype: "02_M1_G_02_07_2mis_156bp", reads: 180),
            makeCall(sample: "DW474", genotype: "04_M1_AG_05_3mis_156bp", reads: 160),
            makeCall(sample: "DW474", genotype: "14_M2_DQA1_01_04", reads: 140),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW474",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1A",
                                    diagnosticAlleles: [
                                        "01_M1_F_01_w_06",
                                        "02_M1_G_02_07_2mis_156bp",
                                        "04_M1_AG_05_3mis_156bp",
                                    ],
                                    observedDiagnosticAlleles: [
                                        "01_M1_F_01_w_06",
                                        "02_M1_G_02_07_2mis_156bp",
                                        "04_M1_AG_05_3mis_156bp",
                                    ]
                                )
                            ],
                            observedGenotypeCount: 3,
                            observedGenotypes: [
                                "01_M1_F_01_w_06",
                                "02_M1_G_02_07_2mis_156bp",
                                "04_M1_AG_05_3mis_156bp",
                            ]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW474", locus: "MHC-A"))
        let alleles = evidence.diagnosticAlleles.map(\.allele)
        XCTAssertTrue(alleles.contains("01_M1_F_01_w_06"))
        XCTAssertTrue(alleles.contains("02_M1_G_02_07_2mis_156bp"))
        XCTAssertTrue(alleles.contains("04_M1_AG_05_3mis_156bp"))
        XCTAssertFalse(alleles.contains("14_M2_DQA1_01_04"))
    }

    func testConfigureRendersHaplotypeCallFromRecordedAnalysisInOutline() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M2_B_019_03", reads: 400),
            makeCall(sample: "DW472", genotype: "12_M2_B_109_04", reads: 300),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M2B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M2B",
                                    diagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04"],
                                    observedDiagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M2_B_019_03", "12_M2_B_109_04"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })
        XCTAssertEqual(slot.h1.testingLabel, "M2B")
    }

    func testConfigureUsesPersistedHaplotypeAnalysisWhenSavedDropoutThresholdsExist() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
        sidecar.settings.dropoutAbsolute = 50
        sidecar.settings.dropoutSampleFraction = nil
        sidecar.settings.dropoutLocusFraction = 0.05
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "13_M3_DRB1_10_02", reads: 1491),
            makeCall(sample: "DW472", genotype: "13_M2_DRB_W4_02", reads: 1117),
            makeCall(sample: "DW472", genotype: "13_M2_DRB1_10_01", reads: 570),
            makeCall(sample: "DW472", genotype: "13_M3_DRB_W49_01_01", reads: 153),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W21_01", reads: 5),
            makeCall(sample: "DW472", genotype: "13_M6_DRB1_04_02_01", reads: 2),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W5_01", reads: 1),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "Mafa-DRB",
                            haplotype1: "ERR: TMH (M1DR, M2DR, M3DR)",
                            haplotype2: "ERR: TMH (M1DR, M2DR, M3DR)",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: calls.count,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-DRB"))
        XCTAssertEqual(evidence.status, .tooManyHaplotypes)
        XCTAssertEqual(evidence.h1Name, "ERR: TMH (M1DR, M2DR, M3DR)")
        XCTAssertEqual(evidence.h2Name, "ERR: TMH (M1DR, M2DR, M3DR)")
    }

    func testConfigureUsesPersistedHaplotypeAnalysisWithoutSavedSidecar() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "13_M3_DRB1_10_02", reads: 1491),
            makeCall(sample: "DW472", genotype: "13_M2_DRB_W4_02", reads: 1117),
            makeCall(sample: "DW472", genotype: "13_M2_DRB1_10_01", reads: 570),
            makeCall(sample: "DW472", genotype: "13_M3_DRB_W49_01_01", reads: 153),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W21_01", reads: 5),
            makeCall(sample: "DW472", genotype: "13_M6_DRB1_04_02_01", reads: 2),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W5_01", reads: 1),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "Mafa-DRB",
                            haplotype1: "ERR: TMH (M1DR, M2DR, M3DR)",
                            haplotype2: "ERR: TMH (M1DR, M2DR, M3DR)",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: calls.count,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-DRB"))
        XCTAssertEqual(evidence.status, .tooManyHaplotypes)
        XCTAssertEqual(evidence.h1Name, "ERR: TMH (M1DR, M2DR, M3DR)")
        XCTAssertEqual(evidence.h2Name, "ERR: TMH (M1DR, M2DR, M3DR)")
    }

    func testReviewEvidenceReportsDiagnosticAllelesOmittedByRunThresholds() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.threshold-omission"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "M9B",
            diagnosticAlleles: ["12_M9_B_high", "12_M9_B_low"]
        ))

        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_high", reads: 100),
            makeCall(sample: "DW472", genotype: "12_M9_B_low", reads: 3),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "custom-assay",
            definitionSetID: definitionID,
            definitionSetName: "Custom Test Definition",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "ERR: NO HAP",
                            haplotype2: "ERR: NO HAP",
                            status: .noHaplotype,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M9_B_high"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: definitionID,
            stats: ONTGenotypeRunStats(
                totalInputReads: 1_000,
                retainedUniqueReads: 103,
                rawMetrics: ["minSupport": "10"]
            )
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.observedGenotypes, ["12_M9_B_high"])
        XCTAssertEqual(evidence.omittedHaplotypeGenotypes.map(\.genotype), ["12_M9_B_low"])
        XCTAssertEqual(evidence.omittedHaplotypeGenotypes.first?.reads, 3)
        XCTAssertTrue(evidence.omittedHaplotypeGenotypes.first?.reason.contains("read minimum 10") ?? false)
    }

    func testDW472bLikeMHCBReviewEvidenceReflectsRecordedHaplotypeCall() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472b", genotype: "12_M3_B_165_01", reads: 150),
            makeCall(sample: "DW472b", genotype: "12_M2_B_109_04", reads: 100),
            makeCall(sample: "DW472b", genotype: "12_M2_B_109_06", reads: 84),
            makeCall(sample: "DW472b", genotype: "12_M2_B_019_03", reads: 75),
            makeCall(sample: "DW472b", genotype: "12_M3_B_075_01", reads: 69),
            makeCall(sample: "DW472b", genotype: "12_M2_B_162", reads: 33),
            makeCall(sample: "DW472b", genotype: "12_M2_B_150_01_01", reads: 26),
            makeCall(sample: "DW472b", genotype: "12_M2M5_B_098g|B_098_01,_B_098_04", reads: 22),
            makeCall(sample: "DW472b", genotype: "12_M3_B_098_05", reads: 20),
            makeCall(sample: "DW472b", genotype: "12_M2M3_B_079g", reads: 15),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472b",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M2B",
                            haplotype2: "M3B",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M2B",
                                    diagnosticAlleles: [
                                        "12_M2_B_019_03",
                                        "12_M2_B_109_04",
                                        "12_M2_B_150_01_01",
                                        "12_M2_B_162",
                                    ],
                                    observedDiagnosticAlleles: [
                                        "12_M2_B_019_03",
                                        "12_M2_B_109_04",
                                        "12_M2_B_150_01_01",
                                        "12_M2_B_162",
                                    ]
                                ),
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: [
                                        "12_M3_B_075_01",
                                        "12_M3_B_098_05",
                                        "12_M3_B_165_01",
                                    ],
                                    observedDiagnosticAlleles: [
                                        "12_M3_B_075_01",
                                        "12_M3_B_098_05",
                                        "12_M3_B_165_01",
                                    ]
                                ),
                            ],
                            observedGenotypeCount: calls.count,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472b", locus: "MHC-B"))
        XCTAssertEqual(evidence.status, .called)
        XCTAssertEqual(evidence.h1Name, "M2B")
        XCTAssertEqual(evidence.h2Name, "M3B")
        XCTAssertEqual(evidence.errorExplanation, "")
        XCTAssertEqual(evidence.candidateHaplotypes.first?.name, "M2B")
    }

    func testMatrixModeRendersHaplotypeDefinitionMatrixFromRecordedAnalysis() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "13_M2_DRB_W4_02", reads: 1117),
            makeCall(sample: "DW472", genotype: "13_M2_DRB1_10_01", reads: 570),
            makeCall(sample: "DW472", genotype: "13_M3_DRB_W49_01_01", reads: 153),
            makeCall(sample: "DW472", genotype: "13_M3_DRB1_10_02", reads: 1491),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "Mafa-DRB",
                            haplotype1: "M2DR",
                            haplotype2: "M3DR",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M2DR",
                                    diagnosticAlleles: ["13_M2_DRB_W4_02", "13_M2_DRB1_10_01"],
                                    observedDiagnosticAlleles: ["13_M2_DRB_W4_02", "13_M2_DRB1_10_01"]
                                ),
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3DR",
                                    diagnosticAlleles: ["13_M3_DRB_W49_01_01", "13_M3_DRB1_10_02"],
                                    observedDiagnosticAlleles: ["13_M3_DRB_W49_01_01", "13_M3_DRB1_10_02"]
                                ),
                            ],
                            observedGenotypeCount: 4,
                            observedGenotypes: [
                                "13_M2_DRB1_10_01",
                                "13_M2_DRB_W4_02",
                                "13_M3_DRB1_10_02",
                                "13_M3_DRB_W49_01_01",
                            ]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        let matrixView = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self))
        XCTAssertFalse(matrixView.isHidden)
        let text = controller.testingHaplotypeMatrixText
        XCTAssertTrue(text.contains("Diagnostic allele matrix"))
        XCTAssertTrue(text.contains("MHC-DRB"))
        XCTAssertTrue(text.contains("M2DR"))
        XCTAssertTrue(text.contains("M3DR"))
    }

    func testRhesusHaplotypeMatrixCountsOnlyClassicalReadsForClassicalAAlleles() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "A11N094", genotype: "01_Mamu-A1_006g|A1_006_02_01_01,A1_006_03", reads: 100),
            makeCall(sample: "A11N094", genotype: "15_Mamu-AG2_01g1|A1_006_02_01_01,A1_006_03", reads: 500),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.rhesus-macaques",
            definitionSetName: "Rhesus macaques",
            speciesName: "Rhesus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "A11N094",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mamu-A",
                            haplotype1: "A006.01",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "A006.01",
                                    diagnosticAlleles: ["A1_006"],
                                    observedDiagnosticAlleles: ["A1_006"]
                                ),
                            ],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_Mamu-A1_006g|A1_006_02_01_01,A1_006_03"]
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: nil
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        let text = controller.testingHaplotypeMatrixText
        XCTAssertTrue(text.contains("Rhesus macaques"))
        XCTAssertTrue(text.contains("A006.01"))
        XCTAssertTrue(text.contains("A1_006 100"))
        XCTAssertFalse(text.contains("A1_006 600"))
    }

    func testNotAssayedOutlineDetailRendersAsSingleCoverageState() {
        let view = GenotypeOutlineView()
        view.configure(rows: [
            GenotypeOutlineView.Row(
                animalId: "DW474",
                gsId: nil,
                loci: ["MHC-DPB"],
                tapeSlots: [
                    GenotypeHaplotypeTapeView.Slot(
                        locus: "MHC-DPB",
                        h1: .reference(tokenIndex: 1, label: "Not assayed"),
                        h2: .reference(tokenIndex: 1, label: "Not assayed")
                    ),
                ],
                blockKind: .blockCoherent,
                commentSummary: "",
                noteIssueCount: 0,
                perLocusCallText: [
                    (
                        locus: "MHC-DPB",
                        h1: "Not assayed",
                        h2: "Not assayed",
                        status: .notAssayed
                    )
                ]
            )
        ])
        view.testingSetExpandedSamples(["DW474"])

        let text = view.testingVisibleText

        XCTAssertTrue(text.contains("MHC-DPB"))
        XCTAssertTrue(text.contains("Not assayed"))
        XCTAssertFalse(text.contains("Not assayed / Not assayed"))
    }

    func testNotAssayedCallsDoNotMakeClearWholeMHCHomozygote() {
        let controller = GenotypeResultViewController()

        XCTAssertFalse(controller.testingIsClearWholeMHCHomozygote(calls: [
            (
                locus: "MHC-DPB",
                h1: "Not assayed",
                h2: "Not assayed",
                status: .notAssayed,
                observedGenotypeCount: 0,
                observedGenotypes: []
            ),
        ]))
    }

    func testNotAssayedCallsAreIgnoredWhenCalledLociAreClearHomozygous() {
        let controller = GenotypeResultViewController()

        XCTAssertTrue(controller.testingIsClearWholeMHCHomozygote(calls: [
            (
                locus: "MHC-A",
                h1: "M1A",
                h2: "-",
                status: .called,
                observedGenotypeCount: 3,
                observedGenotypes: ["01_M1_F_01_w_06", "04_M1_AG_05_3mis_156bp", "11_M1_E_02g3"]
            ),
            (
                locus: "MHC-DPB",
                h1: "Not assayed",
                h2: "Not assayed",
                status: .notAssayed,
                observedGenotypeCount: 0,
                observedGenotypes: []
            ),
        ]))
    }

    func testSelectedSampleCellCanBeHighlightedFromInspectorRequest() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.testingSelectFirstSampleCell(sample: "AnimalA")

        controller.applyHighlight(
            GenotypeResultHighlightRequest(
                target: GenotypeResultHighlightTarget(genotype: call.genotype, locus: "MHC-A", sample: "AnimalA"),
                scope: .selectedCell,
                color: AnnotationColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1.0)
            )
        )

        XCTAssertEqual(controller.testingHighlightedCellCount, 1)
    }

    func testSelectedSampleCellCanCarrySeparateFillAndBorderHighlights() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.testingSelectFirstSampleCell(sample: "AnimalA")

        let target = GenotypeResultHighlightTarget(genotype: call.genotype, locus: "MHC-A", sample: "AnimalA")
        controller.applyHighlight(GenotypeResultHighlightRequest(
            target: target,
            scope: .selectedCell,
            channel: .fill,
            color: AnnotationColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1.0)
        ))
        controller.applyHighlight(GenotypeResultHighlightRequest(
            target: target,
            scope: .selectedCell,
            channel: .border,
            color: AnnotationColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1.0)
        ))

        XCTAssertEqual(controller.testingHighlightedCellCount, 1)
        XCTAssertEqual(controller.testingBorderedCellCount, 1)
        XCTAssertEqual(controller.testingCurrentSelectionStyle.fillColor, AnnotationColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1.0))
        XCTAssertEqual(controller.testingCurrentSelectionStyle.borderColor, AnnotationColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1.0))

        controller.applyHighlight(GenotypeResultHighlightRequest(
            target: target,
            scope: .selectedCell,
            channel: .border,
            color: nil
        ))

        XCTAssertEqual(controller.testingHighlightedCellCount, 1)
        XCTAssertEqual(controller.testingBorderedCellCount, 0)
        XCTAssertNil(controller.testingCurrentSelectionStyle.borderColor)
    }

    func testSharedGenotypeDetailContentIsAnchoredAtTopOfDetailPane() {
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )

        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(controller.testingDetailContentTopInset, 24)
    }

    func testConfigureRetainedDemuxSizedBundleDoesNotBlockViewportLoad() {
        let controller = GenotypeResultViewController()
        _ = controller.view

        var calls: [ONTGenotypeCall] = []
        for sampleIndex in 0..<52 {
            let sample = "LF\(2800 + sampleIndex)"
            for genotypeIndex in 0..<120 {
                let locus = genotypeIndex.isMultiple(of: 2) ? "A1" : "DQB1"
                calls.append(ONTGenotypeCall(
                    sample: sample,
                    genotype: String(format: "%02d_Mafa_%@_%03d_01", genotypeIndex % 20, locus, genotypeIndex),
                    passedAlignments: genotypeIndex.isMultiple(of: 17) ? 1 : 100,
                    passedUniqueReads: genotypeIndex.isMultiple(of: 17) ? 1 : 100,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedReads: 12_000,
                    sampleUniqueRetainedPercent: nil,
                    overallInputReads: nil,
                    overallUniqueRetainedReads: nil,
                    overallUniqueRetainedPercent: nil
                ))
            }
        }

        let start = Date()
        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingRenderVisibleCells(rowLimit: 30)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "Genotype viewport configuration and cell rendering should not rescan support denominators per row")
        XCTAssertFalse(controller.testingVisibleGenotypes.isEmpty)
    }

    func testManualHaplotypeOverrideAppearsInReviewEvidenceAndOutlineTape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
        sidecar.callOverrides = [
            GenotypeAnnotationSidecar.CallOverride(
                sample: "DW472",
                locus: "MHC-B",
                slot: .h2,
                originalCall: "-",
                overrideCall: "M2B",
                reasonTag: .misCall,
                rationale: "Promoted M2B from Review inspector candidate matrix.",
                author: "test",
                timestamp: "2026-05-23T00:00:01Z"
            )
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .noHaplotype,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "DW472",
                passedAlignments: 442,
                passedUniqueReads: 442,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls
            )
        ], calls: calls, haplotypeAnalysis: analysis))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "M3B")
        XCTAssertEqual(evidence.h2Name, "M2B")
        XCTAssertEqual(evidence.status, .called)
        XCTAssertEqual(evidence.errorExplanation, "")
        XCTAssertFalse(evidence.isHomozygous)

        let mhcBSlot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })
        XCTAssertEqual(mhcBSlot.h1.testingLabel, "M3B")
        XCTAssertEqual(mhcBSlot.h2.testingLabel, "M2B")
    }

    func testInspectorOverrideAppliesExplicitSelectedHaplotypeSlot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultExplicitOverride-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DP",
                            sourceLocus: "Mafa-DP",
                            haplotype1: "M4DP",
                            haplotype2: "M7DP",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: ["15_M3_DPA1_01", "15_M4_DPA1_01", "15_M7_DPB1_01"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectCellEvidence(animalId: "DW472", locus: "MHC-DP")

        controller.testingApplyOverrideFromInspector(haplotype: "M3DP", slot: .h1)
        controller.testingApplyOverrideFromInspector(haplotype: "M5DP", slot: .h2)

        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
        let h1Override = try XCTUnwrap(sidecar.callOverrides.first { $0.sample == "DW472" && $0.locus == "MHC-DP" && $0.slot == .h1 })
        let h2Override = try XCTUnwrap(sidecar.callOverrides.first { $0.sample == "DW472" && $0.locus == "MHC-DP" && $0.slot == .h2 })

        XCTAssertEqual(h1Override.originalCall, "M4DP")
        XCTAssertEqual(h1Override.overrideCall, "M3DP")
        XCTAssertEqual(h2Override.originalCall, "M7DP")
        XCTAssertEqual(h2Override.overrideCall, "M5DP")
        XCTAssertTrue(h1Override.rationale.contains("MHC-DP H1 M4DP -> M3DP"))
        XCTAssertTrue(h2Override.rationale.contains("MHC-DP H2 M7DP -> M5DP"))
    }

    func testQuestionMarkOverrideRemainsUnresolvedInEvidenceAndOutline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultUnknownOverride-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DP",
                            sourceLocus: "Mafa-DP",
                            haplotype1: "M4DP",
                            haplotype2: "M7DP",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: ["15_M4M7_DPA1_04_01", "15_M4M7_DPB1_03_03"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectCellEvidence(animalId: "DW472", locus: "MHC-DP")

        controller.testingApplyOverrideFromInspector(haplotype: "?", slot: .h1)

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-DP"))
        XCTAssertEqual(evidence.h1Name, "?")
        XCTAssertEqual(evidence.status, .tooManyHaplotypes)
        let dpSlot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-DP" })
        XCTAssertEqual(dpSlot.h1.testingLabel, "?")
        XCTAssertTrue(dpSlot.h1.testingIsError)
    }

    private func makeResult(
        bundleURL: URL = URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
        samples: [ONTGenotypeSampleResult],
        calls: [ONTGenotypeCall],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil,
        haplotypeDefinitionSetID: String? = nil,
        stats: ONTGenotypeRunStats = ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60)
    ) -> ONTGenotypeResultBundleData {
        ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json",
                haplotypeDefinitionSetID: haplotypeDefinitionSetID
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis
        )
    }

    private func makeCall(sample: String, genotype: String, reads: Int) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    private func makeCustomHaplotypeDefinitionSet(
        id: String,
        haplotypeName: String,
        diagnosticAllele: String
    ) -> GenotypeHaplotypeDefinitionSet {
        makeCustomHaplotypeDefinitionSet(
            id: id,
            haplotypeName: haplotypeName,
            diagnosticAlleles: [diagnosticAllele]
        )
    }

    private func makeCustomHaplotypeDefinitionSet(
        id: String,
        haplotypeName: String,
        diagnosticAlleles: [String]
    ) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: "custom-assay",
            displayName: "Custom Test Definition",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: haplotypeName,
                            diagnosticAlleles: diagnosticAlleles
                        )
                    ]
                )
            ]
        )
    }
}

private extension GenotypeHaplotypeTapeView.Cell {
    var testingLabel: String? {
        switch self {
        case .reference(_, let label),
             .manual(_, let label),
             .recombinant(_, _, let label),
             .notAssayed(let label),
             .error(let label):
            return label
        case .empty, .unanalyzed:
            return nil
        }
    }

    var testingIsError: Bool {
        if case .error = self { return true }
        return false
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }
        return nil
    }
}
