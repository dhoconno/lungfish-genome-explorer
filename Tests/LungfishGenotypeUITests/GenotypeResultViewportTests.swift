import XCTest
import AppKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

@MainActor
final class GenotypeResultViewportTests: XCTestCase {
    func testGenotypeOnlyResultForcesSummaryMatrixListOverDetailViewport() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            summaryViewMode: .outline,
            layout: .listTrailing,
            showsAncillaryLoci: true
        ))

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingPanelLayout, .listTop)
        XCTAssertFalse(controller.testingSplitIsVertical)
        XCTAssertTrue(controller.testingFirstPaneIsMatrix)
        XCTAssertFalse(controller.testingComparisonMatrixIsHidden)
        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertTrue(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 0)
    }

    func testGenotypeOnlyResultDirectLensSelectionCannotEscapeSummary() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))
        controller.testingSetUnappliedDisplayState(GenotypeResultDisplayState(
            viewportLens: .audit,
            summaryViewMode: .outline,
            layout: .listTrailing
        ))

        controller.testingSelectLens(.audit)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingPanelLayout, .listTop)
        XCTAssertFalse(controller.testingSplitIsVertical)
        XCTAssertTrue(controller.testingFirstPaneIsMatrix)

        controller.testingSetUnappliedDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            summaryViewMode: .outline,
            layout: .listLeading
        ))
        controller.testingSelectLens(.review)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingPanelLayout, .listTop)
        XCTAssertFalse(controller.testingSplitIsVertical)
        XCTAssertTrue(controller.testingFirstPaneIsMatrix)
    }

    func testGenotypeOnlySummaryShowsScrollableEmptySelectionDetail() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))

        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertTrue(controller.testingCohortSummaryIsHidden)
        XCTAssertEqual(
            controller.testingDetailText,
            "Select a sample column or allele row to view details."
        )
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("low coverage"))
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("below threshold"))
    }

    func testClearingGenotypeOnlyMatrixSelectionRestoresEmptyDetailPrompt() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))

        controller.testingClickMatrixColumnChiclet(sample: "AnimalA")
        XCTAssertNotEqual(
            controller.testingDetailText,
            "Select a sample column or allele row to view details."
        )

        controller.testingClickMatrixColumnChiclet(sample: "AnimalA", modifiers: .command)

        XCTAssertEqual(
            controller.testingDetailText,
            "Select a sample column or allele row to view details."
        )
        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertTrue(controller.testingCohortSummaryIsHidden)
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("low coverage"))
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("below threshold"))
    }

    func testHaplotypedResultKeepsLensHeaderAndSideBySideLayout() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: []
        )
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42)],
            haplotypeAnalysis: analysis
        ))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            layout: .listTrailing
        ))

        XCTAssertFalse(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 48)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertEqual(controller.testingPanelLayout, .listTrailing)
        XCTAssertTrue(controller.testingSplitIsVertical)
        XCTAssertFalse(controller.testingFirstPaneIsMatrix)
    }

    func testEmptyResultDoesNotUseGenotypeOnlyViewport() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        controller.testingSelectLens(.audit)

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "audit")
        XCTAssertFalse(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 48)
    }

    func testReconfigureFromGenotypeOnlyToHaplotypedRestoresLensHeader() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: []
        )

        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42)],
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectLens(.review)

        XCTAssertFalse(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 48)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
    }

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
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: []
        )
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "LF2874",
                passedAlignments: 19_852,
                passedUniqueReads: 19_769,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls
            )
        ], calls: calls, haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            summaryViewMode: .matrix,
            layout: .listLeading
        ))

        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.testingComparisonMatrixIsHidden)
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

    func testResultViewportOmitsSummaryStatisticsStripForEveryLens() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        for lens in GenotypeResultViewController.Lens.allCases {
            controller.testingSelectLens(lens)
            XCTAssertFalse(controller.testingHasSummaryStatisticsStrip)
        }
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

    func testRedrawOnlyDisplayChangePreservesOutlineSelectionState() throws {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test.definition",
            definitionSetName: "Test definition",
            speciesName: "Test species",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
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
                ),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [], haplotypeAnalysis: analysis
        ))
        var selection: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { selection = $0 }
        controller.testingSelectCellEvidence(animalId: "DW472", locus: "MHC-B")
        let initial = try XCTUnwrap(selection)
        XCTAssertEqual(initial.animalId, "DW472")
        XCTAssertTrue(initial.matrixTargets.isEmpty)

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            layout: .listTrailing
        ))
        controller.notifySelectionStateIfAvailable()

        let retained = try XCTUnwrap(selection)
        XCTAssertEqual(retained.animalId, initial.animalId)
        XCTAssertEqual(retained.title, initial.title)
        XCTAssertEqual(retained.matrixTargets, initial.matrixTargets)
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
        controller.testingSelectCellEvidence(animalId: "DW001", locus: "MHC-B")

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
        controller.testingSelectCellEvidence(animalId: "DW001", locus: "MHC-B")

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
                    passedAlignments: 1_200,
                    passedUniqueReads: 1_200,
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
                    passedAlignments: 1_200,
                    passedUniqueReads: 1_200,
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

    func testReviewLensDoesNotAutoSelectBottomEvidence() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M1_A1_063", reads: 120),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M4A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M1_A1_063"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "LF2823",
                passedAlignments: 120,
                passedUniqueReads: 120,
                sampleTotalReads: 10_000,
                sampleUniqueRetainedPercent: 1.2,
                calls: calls
            )
        ], calls: calls, haplotypeAnalysis: analysis))

        controller.testingSelectLens(.review)

        XCTAssertNil(controller.testingCurrentSelectedSample)
        XCTAssertNil(controller.testingCurrentCallEvidenceSample)
        XCTAssertTrue(controller.testingCallEvidencePaneHidden)
    }

    func testQuickSearchFiltersOutlineBySampleAndHaplotype() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M1_A1_063", reads: 120),
            makeCall(sample: "LF2830", genotype: "05_M2_A1_031", reads: 140),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M4A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M1_A1_063"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2830",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "M5A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M2_A1_031"]
                        )
                    ]
                ),
            ]
        )
        let samples = ["LF2823", "LF2830"].map { sample in
            ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: 120,
                passedUniqueReads: 120,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls.filter { $0.sample == sample }
            )
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: samples, calls: calls, haplotypeAnalysis: analysis))

        controller.testingSetQuickFilterSearchText("2823")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])

        controller.testingSetQuickFilterSearchText("M2")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2830"])

        controller.testingSetQuickFilterSearchText("M1A")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])
    }

    func testReviewLensQuickSearchFiltersOutlineBySampleHaplotypeAndAllele() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M4_A1_031", reads: 120),
            makeCall(sample: "LF2830", genotype: "12_M4_B_075_01", reads: 140),
            makeCall(sample: "LF2838", genotype: "12_M3_B_075_01", reads: 160),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M4A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M4_A1_031"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2830",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M4B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M4_B_075_01"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2838",
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
                ),
            ]
        )
        let samples = ["LF2823", "LF2830", "LF2838"].map { sample in
            ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: 120,
                passedUniqueReads: 120,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls.filter { $0.sample == sample }
            )
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: samples, calls: calls, haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        controller.testingSetQuickFilterSearchText("2823")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])

        controller.testingSetQuickFilterSearchText("M4")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823", "LF2830"])

        controller.testingSetQuickFilterSearchText("M4A")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])

        controller.testingSetQuickFilterSearchText("05_M4_A1_031")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])
    }

    func testCallEvidenceHeaderCarriesSampleReadCounts() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M1_A1_063", reads: 60),
            makeCall(sample: "LF2823", genotype: "05_M4_A1_031", reads: 40),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M4A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["05_M1_A1_063", "05_M4_A1_031"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "LF2823",
                    passedAlignments: 150,
                    passedUniqueReads: 100,
                    sampleTotalReads: 884_000,
                    sampleUniqueRetainedPercent: 0.011,
                    calls: calls
                )
            ],
            calls: calls,
            haplotypeAnalysis: analysis,
            stats: ONTGenotypeRunStats(totalInputReads: 884_000, retainedUniqueReads: 150, assignedUniqueRetainedReads: 100)
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "LF2823", locus: "MHC-A"))
        XCTAssertEqual(evidence.sampleTotalReads, 884_000)
        XCTAssertEqual(evidence.sampleFullLengthReads, 100)
        XCTAssertEqual(evidence.sampleAssignedGenotypeReads, 100)
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

    // MARK: - Sample column windowing

    func testGenBankMatrixDefaultsToAlleleAndOffersEveryReferenceField() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        XCTAssertFalse(matrix.testingPinnedColumnTitles.contains("Genotype"))
        XCTAssertTrue(matrix.testingPinnedColumnTitles.contains("Allele"))
        XCTAssertEqual(matrix.testingReferenceValue(genotype: "NHP01222", fieldKey: "feature.allele"), "Mafa-A1*001:01")
        XCTAssertEqual(
            matrix.testingAvailableReferenceColumnTitles,
            ["Allele", "Organism", "Product", "Definition"]
        )
    }

    func testGenBankMatrixCanToggleAnyReferenceFieldAndFiltersHiddenFields() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73),
                makeCall(sample: "AnimalA", genotype: "NHP99999", reads: 41),
            ],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        matrix.testingSetReferenceColumnVisible(fieldKey: "feature.product", visible: true)
        XCTAssertTrue(matrix.testingPinnedColumnTitles.contains("Product"))

        matrix.testingSetFilter("class I A1 antigen")
        XCTAssertEqual(matrix.testingVisibleGenotypes, ["NHP01222"])
    }

    func testGenBankMatrixSortsMissingReferenceValuesDeterministically() {
        let metadata = makeGenBankReferenceMetadata()
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "NHP-Z", reads: 10),
                makeCall(sample: "AnimalA", genotype: "NHP-A", reads: 10),
            ],
            referenceMetadata: ONTGenotypeReferenceMetadata(
                fields: metadata.fields,
                recordsBySequenceName: ["NHP-Z": [:], "NHP-A": [:]],
                alleleFieldKey: metadata.alleleFieldKey
            )
        ))

        XCTAssertEqual(matrix.testingVisibleGenotypes, ["NHP-A", "NHP-Z"])
    }

    func testFASTAMatrixKeepsGenotypeColumnVisible() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "FASTA_001", reads: 20)]
        ))

        XCTAssertTrue(matrix.testingPinnedColumnTitles.contains("Genotype"))
        XCTAssertTrue(matrix.testingAvailableReferenceColumnTitles.isEmpty)
    }

    func testSelectedGenBankRowShowsAlleleLabelReferenceAndEveryField() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixRows(genotypes: ["NHP01222"], sample: nil)

        let text = controller.testingDetailText
        XCTAssertTrue(text.contains("Selected Allele"))
        XCTAssertTrue(text.contains("Mafa-A1*001:01"))
        XCTAssertTrue(text.contains("Reference Sequence\nNHP01222"))
        XCTAssertTrue(text.contains("GenBank Fields"))
        for value in [
            "Macaca fascicularis",
            "MHC class I A1 antigen",
            "Mafa-A1 complete coding sequence",
        ] {
            XCTAssertTrue(text.contains(value), "Missing GenBank value: \(value)")
        }
        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Reference Sequence", "NHP01222") })
        XCTAssertTrue(rows.contains { $0 == ("Allele", "Mafa-A1*001:01") })
        XCTAssertTrue(rows.contains { $0 == ("Organism", "Macaca fascicularis") })
        XCTAssertTrue(rows.contains { $0 == ("Product", "MHC class I A1 antigen") })
        XCTAssertTrue(rows.contains { $0 == ("Definition", "Mafa-A1 complete coding sequence") })
    }

    func testSelectedFASTARowFallsBackToGenotypeWithoutGenBankSection() {
        let genotype = "01_Mafa_A1_001_01_FULL_FASTA_LABEL"
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 20)]
        ))

        controller.testingSelectMatrixRows(genotypes: [genotype], sample: nil)

        XCTAssertTrue(controller.testingDetailText.contains(genotype))
        XCTAssertFalse(controller.testingDetailText.contains("GenBank Fields"))
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Reference Sequence" })
    }

    func testSelectedColumnShowsSampleMetricsAndOnlyVisibleSupportedAlleles() {
        let retained = ONTGenotypeCall(
            sample: "AnimalA", genotype: "NHP01222", passedAlignments: 45, passedUniqueReads: 30,
            sampleTotalReads: nil, sampleUniqueRetainedReads: 40, sampleUniqueRetainedPercent: nil,
            overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil
        )
        let filtered = ONTGenotypeCall(
            sample: "AnimalA", genotype: "NHP99999", passedAlignments: 12, passedUniqueReads: 10,
            sampleTotalReads: nil, sampleUniqueRetainedReads: 40, sampleUniqueRetainedPercent: nil,
            overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 57, passedUniqueReads: 40,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [retained, filtered]
            )],
            calls: [retained, filtered],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))
        controller.testingSetComparisonFilter("Mafa-A1")

        controller.testingSelectMatrixColumn(sample: "AnimalA")

        let text = controller.testingDetailText
        XCTAssertTrue(text.contains("Selected Sample"))
        XCTAssertTrue(text.contains("AnimalA"))
        XCTAssertTrue(text.contains("Mafa-A1*001:01"))
        XCTAssertFalse(text.contains("Mafa-B*002:01"))
        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Retained Unique Reads", "40") })
        XCTAssertTrue(rows.contains { $0 == ("Alignments", "57") })
        XCTAssertTrue(rows.contains { $0 == ("QC", "Low Support") })
        XCTAssertTrue(rows.contains { $0.0 == "Support" && $0.1 == "100.0%" })
    }

    func testSelectedColumnDetailsRefreshWhenRowFilterChanges() {
        let first = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let second = makeCall(sample: "AnimalA", genotype: "NHP99999", reads: 41)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [first, second], referenceMetadata: makeGenBankReferenceMetadata()
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        XCTAssertTrue(controller.testingDetailText.contains("Mafa-B*002:01"))

        controller.testingSetComparisonFilter("Mafa-A1")

        XCTAssertTrue(controller.testingDetailText.contains("Mafa-A1*001:01"))
        XCTAssertFalse(controller.testingDetailText.contains("Mafa-B*002:01"))
    }

    func testMultiRowSelectionPrunesHiddenNonAnchorAndAnchorRows() {
        let first = "01_Mafa_A1_KEEP_A"
        let second = "02_Mafa_A1_KEEP_B"
        let third = "03_Mafa_A1_DROP"
        let calls = [first, second, third].map { makeCall(sample: "AnimalA", genotype: $0, reads: 10) }

        let nonAnchorController = GenotypeResultViewController()
        _ = nonAnchorController.view
        nonAnchorController.configure(result: makeResult(samples: [], calls: calls))
        nonAnchorController.testingSelectMatrixRows(genotypes: [first, third, second], sample: nil)
        nonAnchorController.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(nonAnchorController.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: first), .row(locus: "MHC-A", genotype: second),
        ]))
        XCTAssertFalse(nonAnchorController.testingDetailText.contains(third))

        let anchorController = GenotypeResultViewController()
        _ = anchorController.view
        anchorController.configure(result: makeResult(samples: [], calls: calls))
        anchorController.testingSelectMatrixRows(genotypes: [first, second, third], sample: nil)
        anchorController.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(anchorController.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: first), .row(locus: "MHC-A", genotype: second),
        ]))
        XCTAssertTrue(anchorController.testingDetailText.contains(first))
        XCTAssertTrue(anchorController.testingDetailText.contains(second))
    }

    func testMultiCellSelectionPrunesRowsAndSamplesWhileKeepingVisibleEmptyCells() {
        let first = "01_Mafa_A1_KEEP"
        let second = "02_Mafa_A1_DROP"
        let callA = makeCall(sample: "AnimalA", genotype: first, reads: 10)
        let callB = makeCall(sample: "AnimalB", genotype: second, reads: 20)
        let samples = [
            ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 10, passedUniqueReads: 10, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [callA]),
            ONTGenotypeSampleResult(sample: "AnimalB", passedAlignments: 20, passedUniqueReads: 20, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [callB]),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: samples, calls: [callA, callB]))
        controller.testingClickMatrixCell(genotype: first, sample: "AnimalA")
        controller.testingClickMatrixCell(genotype: second, sample: "AnimalB", modifiers: .command)
        controller.testingClickMatrixCell(genotype: first, sample: "AnimalB", modifiers: .command)

        controller.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalB"),
        ]))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Evidence", "No supporting reads") })

        controller.testingSetComparisonFilter("")
        controller.testingClickMatrixCell(genotype: first, sample: "AnimalA")
        controller.testingClickMatrixCell(genotype: second, sample: "AnimalB", modifiers: .command)
        controller.testingApplyDisplayState(GenotypeResultDisplayState(matrixSampleFilterText: "AnimalB"))
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalB"),
        ])
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Unique Reads", "20") })
    }

    func testMixedSelectionPrunesEveryTargetKindAcrossSequentialFilters() {
        let keep = "01_Mafa_A1_KEEP"
        let drop = "02_Mafa_A1_DROP"
        let calls = [
            makeCall(sample: "AnimalA", genotype: keep, reads: 10),
            makeCall(sample: "AnimalB", genotype: keep, reads: 20),
            makeCall(sample: "AnimalA", genotype: drop, reads: 30),
            makeCall(sample: "AnimalB", genotype: drop, reads: 40),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingClickMatrixSelectAllChiclet()
        controller.testingClickMatrixCell(genotype: keep, sample: "AnimalA", modifiers: .command)
        controller.testingClickMatrixCell(genotype: keep, sample: "AnimalB", modifiers: .command)

        controller.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: keep),
            .cell(locus: "MHC-A", genotype: keep, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: keep, sample: "AnimalB"),
            .column(sample: "AnimalA"),
            .column(sample: "AnimalB"),
        ]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(matrixSampleFilterText: "AnimalB"))
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: keep),
            .cell(locus: "MHC-A", genotype: keep, sample: "AnimalB"),
            .column(sample: "AnimalB"),
        ]))
    }

    func testSelectedColumnSupportRefreshesWhenDenominatorChanges() {
        let selected = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_SELECTED", reads: 25)
        let other = makeCall(sample: "AnimalA", genotype: "02_Mafa_A1_OTHER", reads: 75)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 200, passedUniqueReads: 200,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [selected, other]
            )],
            calls: [selected, other]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Support", "25.0%") })
        var selectionPublicationCount = 0
        controller.onSelectionStateChanged = { _ in selectionPublicationCount += 1 }

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            supportDenominator: .sampleRetained
        ))

        XCTAssertEqual(selectionPublicationCount, 1)
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Support", "12.5%") })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Support", "25.0%") })
    }

    func testSelectedLargeColumnPublishesEveryAlleleWithBoundedDetailSubviews() {
        let alleleCount = 1_001
        let calls = (0..<alleleCount).map { index in
            makeCall(
                sample: "AnimalA",
                genotype: String(format: "%04d_Mafa_A1_%04d", index, index),
                reads: 1
            )
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))

        controller.testingSelectMatrixColumn(sample: "AnimalA")

        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.filter { $0.0.hasPrefix("Allele ") }.count,
            alleleCount
        )
        XCTAssertLessThanOrEqual(controller.testingDetailArrangedSubviewCount, 12)
        XCTAssertTrue(controller.testingDetailText.contains(calls.first!.genotype))
        XCTAssertTrue(controller.testingDetailText.contains(calls.last!.genotype))
    }

    func testSelectedLargeMultiRowAndCellDetailsStayBounded() {
        let count = 1_001
        let calls = (0..<count).map { index in
            makeCall(sample: "AnimalA", genotype: String(format: "%04d_Mafa_A1_%04d", index, index), reads: index + 1)
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))
        let rowTargets = calls.reversed().map {
            GenotypeAnnotationSidecar.MatrixTarget.row(locus: "MHC-A", genotype: $0.genotype)
        }
        controller.testingShowMatrixTargetSelection(rowTargets)
        XCTAssertEqual(controller.testingCurrentSelectionDetailRows.filter { $0.0.hasPrefix("Allele ") }.count, count)
        XCTAssertLessThanOrEqual(controller.testingDetailArrangedSubviewCount, 6)
        XCTAssertTrue(controller.testingDetailText.contains(calls.first!.genotype))
        XCTAssertTrue(controller.testingDetailText.contains(calls.last!.genotype))

        let cellTargets = calls.reversed().map {
            GenotypeAnnotationSidecar.MatrixTarget.cell(locus: "MHC-A", genotype: $0.genotype, sample: "AnimalA")
        }
        controller.testingShowMatrixTargetSelection(cellTargets)
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets.count, count)
        XCTAssertEqual(controller.testingCurrentSelectionDetailRows.filter { $0.0.hasPrefix("Cell ") }.count, count)
        XCTAssertEqual(controller.testingCurrentSelectionDetailRows.filter { $0.0 == "Unique Reads" }.count, count)
        XCTAssertLessThanOrEqual(controller.testingDetailArrangedSubviewCount, 6)
        XCTAssertTrue(controller.testingDetailText.contains(calls.first!.genotype))
        XCTAssertTrue(controller.testingDetailText.contains(calls.last!.genotype))
    }

    func testSelectedColumnOmitsUnavailableSummaryMetricsWhenSampleSummaryMissing() {
        let call = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_ONLY", reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Sample", "AnimalA") })
        XCTAssertTrue(rows.contains { $0 == ("Unique Reads", "42") })
        XCTAssertFalse(rows.contains { ["Retained Unique Reads", "QC"].contains($0.0) })
        XCTAssertFalse(rows.contains { $0.0 == "Alignments" && $0.1 == "Unavailable" })
    }

    func testSelectedAlleleTieUsesRawSequenceOrdinalOrder() {
        let first = "01_Mafa_A1_Z"
        let second = "02_Mafa_A1_A"
        let fields = [
            GenBankRecordDatabase.FieldDefinition(
                key: "feature.allele", displayTitle: "Allele", valueType: "text",
                sourceCategory: "feature", preferredOrder: 0
            ),
        ]
        let metadata = ONTGenotypeReferenceMetadata(
            fields: fields,
            recordsBySequenceName: [
                first: ["feature.allele": "Mafa-A1*same"],
                second: ["feature.allele": "Mafa-A1*same"],
            ],
            alleleFieldKey: "feature.allele"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: first, reads: 10), makeCall(sample: "AnimalA", genotype: second, reads: 10)],
            referenceMetadata: metadata
        ))

        controller.testingShowMatrixTargetSelection([
            .row(locus: "MHC-A", genotype: second),
            .row(locus: "MHC-A", genotype: first),
        ])

        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.filter { $0.0 == "Reference Sequence" }.map(\.1),
            [first, second]
        )
    }

    func testSelectedMultipleRowsShowEveryAlleleAggregateAndGenBankValue() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73),
            makeCall(sample: "AnimalA", genotype: "NHP99999", reads: 41),
        ]
        controller.configure(result: makeResult(
            samples: [], calls: calls, referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixRows(genotypes: ["NHP01222", "NHP99999"], sample: nil)

        let text = controller.testingDetailText
        XCTAssertTrue(text.contains("Selected Alleles: 2"))
        XCTAssertTrue(text.contains("Mafa-A1*001:01"))
        XCTAssertTrue(text.contains("Mafa-B*002:01"))
        XCTAssertTrue(text.contains("73"))
        XCTAssertTrue(text.contains("41"))
        XCTAssertTrue(text.contains("MHC class I A1 antigen"))
        XCTAssertTrue(text.contains("MHC class I B antigen"))
    }

    func testSelectedSupportedCellShowsEvidenceAndReferenceFields() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA", genotype: "NHP01222", passedAlignments: 91, passedUniqueReads: 73,
            sampleTotalReads: nil, sampleUniqueRetainedReads: 100, sampleUniqueRetainedPercent: nil,
            overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 91, passedUniqueReads: 73,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call]
            )],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalA")

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Sample", "AnimalA") })
        XCTAssertTrue(rows.contains { $0 == ("Allele", "Mafa-A1*001:01") })
        XCTAssertTrue(rows.contains { $0 == ("Reference Sequence", "NHP01222") })
        XCTAssertTrue(rows.contains { $0 == ("Unique Reads", "73") })
        XCTAssertTrue(rows.contains { $0 == ("Alignments", "91") })
        XCTAssertTrue(rows.contains { $0 == ("Support", "100.0%") })
        XCTAssertTrue(rows.contains { $0 == ("Product", "MHC class I A1 antigen") })
    }

    func testSelectedEmptyCellShowsNoSupportingReadsWithoutZeroCounts() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 73, passedUniqueReads: 73, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call]),
                ONTGenotypeSampleResult(sample: "AnimalB", passedAlignments: 0, passedUniqueReads: 0, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: []),
            ],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalB")

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Evidence", "No supporting reads") })
        XCTAssertFalse(rows.contains { ["Unique Reads", "Alignments", "Support", "Selected Unique", "Selected Support"].contains($0.0) })
    }

    func testSelectedMultipleCellsShowEveryAlleleSamplePairAndExactEvidence() {
        let first = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let second = makeCall(sample: "AnimalB", genotype: "NHP99999", reads: 41)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [first, second], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        let targets: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .cell(locus: "NHP01222", genotype: "NHP01222", sample: "AnimalA"),
            .cell(locus: "NHP99999", genotype: "NHP99999", sample: "AnimalA"),
            .cell(locus: "NHP99999", genotype: "NHP99999", sample: "AnimalB"),
        ]
        controller.testingShowMatrixTargetSelection(targets)

        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set(targets))
        let rows = controller.testingCurrentSelectionDetailRows
        let entries = rows.split { $0.0.hasPrefix("Cell ") }
        XCTAssertTrue(entries.contains { entry in
            entry.contains { $0 == ("Allele", "Mafa-A1*001:01") }
                && entry.contains { $0 == ("Sample", "AnimalA") }
                && entry.contains { $0 == ("Unique Reads", "73") }
        })
        XCTAssertTrue(entries.contains { entry in
            entry.contains { $0 == ("Allele", "Mafa-B*002:01") }
                && entry.contains { $0 == ("Sample", "AnimalA") }
                && entry.contains { $0 == ("Evidence", "No supporting reads") }
        })
        XCTAssertTrue(entries.contains { entry in
            entry.contains { $0 == ("Allele", "Mafa-B*002:01") }
                && entry.contains { $0 == ("Sample", "AnimalB") }
                && entry.contains { $0 == ("Unique Reads", "41") }
        })
    }

    func testSelectedGenBankRowPublishesFullAlleleTitle() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        var selection: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { selection = $0 }
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixRows(genotypes: ["NHP01222"], sample: nil)

        XCTAssertEqual(try XCTUnwrap(selection).title, "Mafa-A1*001:01")
        XCTAssertEqual(try XCTUnwrap(selection).highlightTarget?.genotype, "NHP01222")
    }

    func testSelectedMultipleColumnsShowCompactSummaryForEachSample() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMultiSampleSelection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let call = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 73, passedUniqueReads: 73, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call]),
                ONTGenotypeSampleResult(sample: "AnimalB", passedAlignments: 0, passedUniqueReads: 0, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: []),
            ],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixColumns(samples: ["AnimalA", "AnimalB"])
        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Selected cohort note"
        ))

        let text = controller.testingDetailText
        XCTAssertTrue(text.contains("Selected Samples"))
        XCTAssertTrue(text.contains("AnimalA"))
        XCTAssertTrue(text.contains("AnimalB"))
        XCTAssertFalse(text.contains("Supported Alleles"))
        XCTAssertFalse(text.contains("Mafa-A1*001:01"))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Sample 1", "AnimalA") })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Sample 2", "AnimalB") })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0.hasPrefix("Allele ") })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Support" })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Column Comment", "Selected cohort note")
        })
    }

    func testSelectedCellIncludesApplicableRowColumnAndCellComments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSelectionComments-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let call = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 73, passedUniqueReads: 73, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call])],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))
        controller.testingSelectMatrixRows(genotypes: ["NHP01222"], sample: nil)
        controller.addMatrixComment(.init(targets: controller.testingCurrentSelectionMatrixTargets, body: "Row note"))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.addMatrixComment(.init(targets: controller.testingCurrentSelectionMatrixTargets, body: "Column note"))
        controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalA")
        controller.addMatrixComment(.init(targets: controller.testingCurrentSelectionMatrixTargets, body: "Cell note"))

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Row Comment", "Row note") })
        XCTAssertTrue(rows.contains { $0 == ("Column Comment", "Column note") })
        XCTAssertTrue(rows.contains { $0 == ("Cell Comment", "Cell note") })
    }

    func testMixedMatrixTargetsUseGenericMixedSummary() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)]
        ))

        controller.testingShowMatrixTargetSelection([
            .row(locus: "NHP01222", genotype: "NHP01222"),
            .column(sample: "AnimalA"),
        ])

        XCTAssertTrue(controller.testingDetailText.contains("Matrix Annotation Targets"))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Selection Type", "Mixed") })
    }

    private func makeManySampleMatrix(sampleCount: Int) -> GenotypeComparisonMatrixView {
        let matrix = GenotypeComparisonMatrixView()
        let genotype = "12_M3_B_075_01"
        var calls: [ONTGenotypeCall] = []
        var samples: [ONTGenotypeSampleResult] = []
        for i in 0..<sampleCount {
            let name = String(format: "SAMPLE_%03d", i)
            let call = makeCall(sample: name, genotype: genotype, reads: 100 + i)
            calls.append(call)
            samples.append(ONTGenotypeSampleResult(
                sample: name,
                passedAlignments: 100 + i,
                passedUniqueReads: 100 + i,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [call]
            ))
        }
        matrix.configure(result: makeResult(samples: samples, calls: calls))
        return matrix
    }

    private func makeManyRowComparisonMatrix(sampleCount: Int = 2) -> GenotypeComparisonMatrixView {
        let matrix = GenotypeComparisonMatrixView()
        var calls: [ONTGenotypeCall] = []
        let sampleNames = (0..<sampleCount).map { "Sample\($0)" }
        var callsBySample = Array(repeating: [ONTGenotypeCall](), count: sampleCount)

        for index in 0..<32 {
            let genotype = String(format: "Mafa-AG*%02d:01", index)
            for (sampleIndex, sample) in sampleNames.enumerated() {
                let call = makeCall(sample: sample, genotype: genotype, reads: 100 + sampleIndex + index)
                calls.append(call)
                callsBySample[sampleIndex].append(call)
            }
        }

        let samples = sampleNames.enumerated().map { sampleIndex, sample in
            ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: 100 + sampleIndex,
                passedUniqueReads: 100 + sampleIndex,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: callsBySample[sampleIndex]
            )
        }
        matrix.configure(result: makeResult(samples: samples, calls: calls))
        return matrix
    }

    func testComparisonMatrixSynchronizesVerticalScrollingFromEitherPanel() throws {
        let matrix = makeManyRowComparisonMatrix()
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        matrix.layoutSubtreeIfNeeded()
        XCTAssertEqual(matrix.testingSampleMatrixBottomChromeHeight, 0)
        let sampleScrollView = try XCTUnwrap(
            matrix.subviews.compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller }
        )
        sampleScrollView.setFrameSize(NSSize(width: 99, height: sampleScrollView.frame.height))
        sampleScrollView.tile()

        matrix.testingScrollSampleMatrix(to: NSPoint(x: 37, y: 88))

        XCTAssertEqual(matrix.testingPinnedVerticalScrollOffset, 88)
        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.x, 37)

        matrix.testingScrollPinnedPanel(toY: 132)

        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.y, 132)
        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.x, 37)
    }

    func testComparisonMatrixDisablesVerticalScrollElasticity() throws {
        let matrix = GenotypeComparisonMatrixView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = host
        host.addSubview(matrix)
        NSLayoutConstraint.activate([
            matrix.topAnchor.constraint(equalTo: host.topAnchor),
            matrix.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            matrix.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            matrix.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        window.layoutIfNeeded()
        matrix.layoutSubtreeIfNeeded()

        let scrollViews = matrix.subviews.compactMap { $0 as? NSScrollView }
        let pinnedScrollView = try XCTUnwrap(scrollViews.first { !$0.hasVerticalScroller })
        let sampleScrollView = try XCTUnwrap(scrollViews.first { $0.hasVerticalScroller })

        XCTAssertEqual(pinnedScrollView.verticalScrollElasticity, .none)
        XCTAssertEqual(sampleScrollView.verticalScrollElasticity, .none)
    }

    func testComparisonMatrixClampsRawVerticalClipOrigins() throws {
        let matrix = makeManyRowComparisonMatrix()
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        matrix.layoutSubtreeIfNeeded()

        let scrollViews = matrix.subviews.compactMap { $0 as? NSScrollView }
        let pinnedScrollView = try XCTUnwrap(scrollViews.first { !$0.hasVerticalScroller })
        let sampleScrollView = try XCTUnwrap(scrollViews.first { $0.hasVerticalScroller })

        sampleScrollView.contentView.scroll(to: NSPoint(x: 37, y: -1_000))
        let sampleBounds = sampleScrollView.contentView.bounds
        XCTAssertEqual(
            sampleBounds.origin.y,
            sampleScrollView.contentView.constrainBoundsRect(sampleBounds).origin.y,
            accuracy: 0.001
        )
        XCTAssertEqual(sampleBounds.origin.x, 37, accuracy: 0.001)

        pinnedScrollView.contentView.scroll(to: NSPoint(x: 19, y: 9_999))
        let pinnedBounds = pinnedScrollView.contentView.bounds
        XCTAssertEqual(
            pinnedBounds.origin.y,
            pinnedScrollView.contentView.constrainBoundsRect(pinnedBounds).origin.y,
            accuracy: 0.001
        )
        XCTAssertEqual(pinnedBounds.origin.x, 19, accuracy: 0.001)
    }

    func testComparisonMatrixAlignsBottomRowsWhenSampleScrollerOccupiesBottomChrome() {
        let matrix = makeManyRowComparisonMatrix(sampleCount: 6)
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        matrix.layoutSubtreeIfNeeded()
        matrix.testingConfigureSampleMatrixLegacyHorizontalScroller()

        XCTAssertGreaterThan(matrix.testingSampleMatrixBottomChromeHeight, 0)

        matrix.testingScrollSampleMatrixToBottom(x: 37)

        let finalRow = matrix.testingVisibleRows.count - 1
        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.x, 37)
        XCTAssertEqual(
            matrix.testingPinnedRowYInMatrix(row: finalRow),
            matrix.testingSampleMatrixRowYInMatrix(row: finalRow),
            accuracy: 0.001
        )
    }

    func testComparisonMatrixShowsEverySampleColumnByDefault() {
        let matrix = makeManySampleMatrix(sampleCount: 150)
        XCTAssertEqual(matrix.testingSampleColumnCount, 150)
        XCTAssertFalse(matrix.testingIsColumnWindowActive)
    }

    func testComparisonMatrixDoesNotShowSampleLimitBanner() {
        let matrix = makeManySampleMatrix(sampleCount: 150)
        XCTAssertEqual(matrix.testingSampleColumnCount, 150)
        XCTAssertFalse(matrix.testingIsColumnWindowActive)
        XCTAssertFalse(matrix.testingColumnWindowBannerVisible)
    }

    func testComparisonMatrixSmallCohortInstantiatesAllColumns() {
        let matrix = makeManySampleMatrix(sampleCount: 40)
        XCTAssertEqual(matrix.testingSampleColumnCount, 40)
        XCTAssertFalse(matrix.testingIsColumnWindowActive)
    }

    func testComparisonMatrixPinnedPaneCanResizeAndRemembersWidth() {
        let matrix = makeManySampleMatrix(sampleCount: 4)
        matrix.frame = NSRect(x: 0, y: 0, width: 1_000, height: 400)
        matrix.testingSetPinnedPaneWidth(430)
        XCTAssertEqual(matrix.testingPinnedPaneWidth, 430, accuracy: 1)

        let restored = makeManySampleMatrix(sampleCount: 4)
        restored.frame = NSRect(x: 0, y: 0, width: 1_000, height: 400)
        restored.layoutSubtreeIfNeeded()
        XCTAssertEqual(restored.testingPinnedPaneWidth, 430, accuracy: 1)
    }

    func testComparisonMatrixExportSeesEveryVisibleSample() {
        let matrix = makeManySampleMatrix(sampleCount: 150)

        XCTAssertEqual(matrix.testingSampleColumnCount, 150)
        // The full logical set is intact.
        XCTAssertEqual(matrix.testingActiveSampleNames.count, 150)
        XCTAssertEqual(matrix.testingVisibleSampleNames.count, 150)

        // Export must include every sample, not just the windowed 60.
        let snapshot = matrix.exportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            analysisName: "Example",
            lens: "summary.matrix"
        )
        XCTAssertEqual(snapshot.sampleNames.count, 150)
        XCTAssertTrue(snapshot.sampleNames.contains("SAMPLE_120"))
        // The single shared row records reads for all 150 samples.
        XCTAssertEqual(snapshot.rows.first?.sampleReads.count, 150)
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

    func testQuickSearchTreatsGenotypeTextAsMatrixRowFilterWithoutSampleColumnNarrowing() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
            makeCall(sample: "AnimalB", genotype: "04_Mafa_B_001_01", reads: 42),
        ]
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[0]]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[1]]
            ),
        ], calls: calls))

        XCTAssertEqual(Set(controller.testingVisibleGenotypes), Set(["01_Mafa_A1_001_01", "04_Mafa_B_001_01"]))
        controller.testingSetUnifiedSampleFilter("MHC-B")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])

        controller.testingSetUnifiedSampleFilter("AnimalB")
        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalB"])
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

    func testWeakHaplotypeSlotIsTintedBelowFivePercent() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M1_B_001_01", reads: 100),
            makeCall(sample: "DW472", genotype: "12_M2_B_001_01", reads: 3),
        ]
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: makeWeakSupportAnalysis(
                h1: "M1B",
                h2: "M2B",
                h1Allele: "12_M1_B_001_01",
                h2Allele: "12_M2_B_001_01"
            )
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })

        XCTAssertFalse(slot.h1.testingIsWeakSupport)
        XCTAssertTrue(slot.h2.testingIsWeakSupport)
    }

    func testWeakHaplotypeTintUsesSameColorAtHalfOpacity() throws {
        let view = GenotypeHaplotypeTapeView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        view.appearance = NSAppearance(named: .aqua)
        let tokenIndex = HaplotypeColorToken.assigned(forName: "M2B").canonicalIndex
        let referenceColor = try XCTUnwrap(
            view.testingFillColor(for: .reference(tokenIndex: tokenIndex, label: "M2B"))?.testingSRGBComponents
        )
        let weakColor = try XCTUnwrap(
            view.testingFillColor(for: .weakReference(tokenIndex: tokenIndex, label: "M2B"))?.testingSRGBComponents
        )

        XCTAssertEqual(weakColor.red, referenceColor.red, accuracy: 0.001)
        XCTAssertEqual(weakColor.green, referenceColor.green, accuracy: 0.001)
        XCTAssertEqual(weakColor.blue, referenceColor.blue, accuracy: 0.001)
        XCTAssertEqual(weakColor.alpha, 0.5, accuracy: 0.001)
    }

    func testWeakHaplotypeSlotIsTintedBelowFiveReads() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M1_B_001_01", reads: 20),
            makeCall(sample: "DW472", genotype: "12_M2_B_001_01", reads: 4),
        ]
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: makeWeakSupportAnalysis(
                h1: "M1B",
                h2: "M2B",
                h1Allele: "12_M1_B_001_01",
                h2Allele: "12_M2_B_001_01"
            )
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })

        XCTAssertFalse(slot.h1.testingIsWeakSupport)
        XCTAssertTrue(slot.h2.testingIsWeakSupport)
    }

    func testManualHaplotypeSlotRestoresFullOpacity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultWeakSupport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-23T00:00:00Z")
        sidecar.callOverrides = [
            GenotypeAnnotationSidecar.CallOverride(
                sample: "DW472",
                locus: "MHC-B",
                slot: .h2,
                originalCall: "M2B",
                overrideCall: "M2B",
                reasonTag: .analystJudgment,
                rationale: "Manual review accepted the low-read call.",
                author: "test",
                timestamp: "2026-06-23T00:00:01Z"
            )
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M1_B_001_01", reads: 100),
            makeCall(sample: "DW472", genotype: "12_M2_B_001_01", reads: 3),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: makeWeakSupportAnalysis(
                h1: "M1B",
                h2: "M2B",
                h1Allele: "12_M1_B_001_01",
                h2Allele: "12_M2_B_001_01"
            )
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })

        XCTAssertFalse(slot.h1.testingIsWeakSupport)
        XCTAssertFalse(slot.h2.testingIsWeakSupport)
    }

    func testObservedOnlyLociDoesNotActivateMatrixView() throws {
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
        XCTAssertTrue(sharedMatrix.isHidden)
        XCTAssertTrue(controller.testingVisibleOutlineSamples.contains("DW472"))
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

    func testHaplotypeMatrixSearchFiltersDefinitionRowsRatherThanWholeSamples() throws {
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
        let matrixView = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self))
        XCTAssertTrue(matrixView.isHidden)
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
        let matrixView = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self))
        XCTAssertTrue(matrixView.isHidden)
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

    func testGenotypeOnlyResultUsesRawMatrixEvenWithResolvedDefinition() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeOnlyRawMatrixDefinition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.raw-matrix-definition"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "NewB",
            diagnosticAllele: "12_M9_B_001_01"
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

        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertFalse(controller.testingComparisonMatrixIsHidden)
        let definitionMatrix = try XCTUnwrap(
            controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self)
        )
        XCTAssertTrue(definitionMatrix.isHidden)
    }

    func testAIHaplotypingCompletionResetsGenotypeOnlyMatrixDefaultToOutline() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        controller.configure(result: makeResult(samples: [], calls: calls))
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)

        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "ai-provisional:test",
            definitionSetName: "AI provisional",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
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

        controller.applyAIHaplotypingCompleted(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis
        ))

        XCTAssertEqual(controller.testingSummaryViewMode, .outline)
        XCTAssertFalse(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 48)

        controller.testingSelectLens(.review)

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
    }

    func testHaplotypedBundleRemembersGenotypeMatrixSummaryPreference() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSummaryPreference-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "mcm-test",
            definitionSetName: "MCM test",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
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
        let result = makeResult(bundleURL: bundleURL, samples: [], calls: calls, haplotypeAnalysis: analysis)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        XCTAssertEqual(controller.testingSummaryViewMode, .outline)

        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix))
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
        XCTAssertEqual(sidecar.settings.preferredSummaryViewMode, GenotypeSummaryViewMode.matrix.rawValue)

        let restored = GenotypeResultViewController()
        _ = restored.view
        restored.configure(result: result)

        XCTAssertEqual(restored.testingSummaryViewMode, .matrix)
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

    func testReviewEvidenceUsesObservedGenotypeHeaderForAnimalGenotypeDisplay() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let enrichedHeader = "MCM_MHC_MiSeq_0073|source_loci=MHC-B|haplotypes=M1B|alleles=Mafa-B_073:01:01:01|evidence_classes=primary_expressed"
        let calls = [
            makeCall(sample: "LF2830", genotype: enrichedHeader, reads: 66),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2830",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M1B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1B",
                                    diagnosticAlleles: ["MCM_MHC_MiSeq_0073"],
                                    observedDiagnosticAlleles: ["MCM_MHC_MiSeq_0073"]
                                )
                            ],
                            observedGenotypeCount: 1,
                            observedGenotypes: [enrichedHeader]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "LF2830", locus: "MHC-B"))
        XCTAssertEqual(evidence.animalGenotypes.first?.genotype, enrichedHeader)
        XCTAssertEqual(
            GenotypeCallEvidenceView.AlleleLabel(evidence.animalGenotypes.first?.genotype ?? "").primary,
            "Mafa-B*073:01:01:01"
        )
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

    func testIncludedLociFilterOutlineAndCurrentWorkbookCalls() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "mcm-mhc-miseq",
            definitionSetID: "mcm-mhc-miseq-primary",
            definitionSetName: "MCM MHC MiSeq",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2832",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "MHC-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M1A-read"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-E",
                            sourceLocus: "MHC-E",
                            haplotype1: "M2E",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M2E-read"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "MHC-DRB",
                            haplotype1: "M3DR",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M3DR-read"]
                        ),
                    ]
                ),
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))

        XCTAssertEqual(controller.testingOutlineSlots(sample: "LF2832").map(\.locus), ["MHC-A", "MHC-DRB"])
        XCTAssertEqual(controller.testingCurrentWorkbookHaplotypeCalls().map(\.locus), ["MHC-A"])

        controller.testingApplyDisplayState(GenotypeResultDisplayState(includedLoci: ["MHC-A", "MHC-E", "MHC-DRB"]))

        XCTAssertEqual(controller.testingOutlineSlots(sample: "LF2832").map(\.locus), ["MHC-A", "MHC-E", "MHC-DRB"])
        XCTAssertEqual(controller.testingCurrentWorkbookHaplotypeCalls().map(\.locus), ["MHC-A"])
    }

    func testCurrentWorkbookSnapshotIncludesManualHaplotypeAssignments() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-22T00:00:00Z")
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "LF2832",
                locus: "MHC-A",
                slot: .h1,
                label: "Manual-M2B",
                colorTokenIndex: 2,
                diagnosticAlleles: ["M2B-read"],
                notes: "curated in GUI"
            )
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "mcm-mhc-miseq",
            definitionSetID: "mcm-mhc-miseq-primary",
            definitionSetName: "MCM MHC MiSeq",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2832",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "MHC-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M1A-read"]
                        ),
                    ]
                ),
            ]
        )
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [], haplotypeAnalysis: analysis))

        XCTAssertEqual(controller.testingCurrentWorkbookHaplotypeCalls(), [
            GenotypeWorkbookHaplotypeCall(
                sample: "LF2832",
                locus: "MHC-A",
                haplotype1: "Manual-M2B",
                haplotype2: "-",
                status: GenotypeHaplotypeCallStatus.called.rawValue,
                notes: "curated in GUI"
            )
        ])
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

    func testConfigureKeepsPersistedDeterministicHaplotypesWhenDefinitionIsAvailable() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.persisted-deterministic"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "M9B",
            diagnosticAllele: "12_M9_B_001"
        ))

        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_001", reads: 100),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
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
                            haplotype1: "PERSISTED-B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: calls.map(\.genotype)
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
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: definitionID
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "PERSISTED-B")
        XCTAssertEqual(evidence.h2Name, "-")
    }

    func testConfigureRecomputesWhenSavedSidecarSelectsDifferentDefinition() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let activeDefinitionID = "custom.test.active-sidecar-definition"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: activeDefinitionID,
            haplotypeName: "M9B",
            diagnosticAllele: "12_M9_B_001"
        ))
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
        sidecar.settings.activeHaplotypeDefinitionSetID = activeDefinitionID
        sidecar.settings.activeHaplotypeAssayID = "custom-assay"
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_001", reads: 100),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "custom-assay",
            definitionSetID: "custom.test.persisted-old-definition",
            definitionSetName: "Old Test Definition",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "PERSISTED-B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: calls.map(\.genotype)
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
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: "custom.test.persisted-old-definition"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "M9B")
        XCTAssertEqual(evidence.h2Name, "-")
    }

    func testCallEvidenceCarriesUnsupportedDefinitionHaplotypesForOverrideMenus() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.unsupported-menu-haplotypes"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(GenotypeHaplotypeDefinitionSet(
            id: definitionID,
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
                        GenotypeHaplotypeDefinition(name: "M9B", diagnosticAlleles: ["12_M9_B_001"]),
                        GenotypeHaplotypeDefinition(name: "M10B", diagnosticAlleles: ["12_M10_B_001"]),
                    ]
                )
            ]
        ))
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_001", reads: 100),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
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
                            haplotype1: "M9B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: calls.map(\.genotype)
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
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: definitionID
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.candidateHaplotypes.map(\.name), ["M9B"])
        XCTAssertEqual(evidence.availableHaplotypeNames, ["M9B", "M10B"])

        let menuSections = GenotypeCallEvidenceView.overrideActionSections(for: .h2, evidence: evidence)
        XCTAssertEqual(menuSections.recommended.map(\.haplotypeName), ["M9B"])
        XCTAssertEqual(menuSections.unsupported.map(\.haplotypeName), ["M10B"])
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
        XCTAssertTrue(matrixView.isHidden)
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

    func testRawMatrixCanSelectEmptyCellTarget() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_001_01"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [call]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 0,
                passedUniqueReads: 0,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: []
            ),
        ], calls: [call]))

        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalB")

        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalB"),
        ])
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Selected Sample" && $0.1 == "AnimalB"
        })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Selected Unique" })
    }

    func testMatrixStylePrecedenceCombinesRowAndColumnAndLetsCellOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixStyles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_001_01"
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: "MHC-A", genotype: genotype),
                style: .init(fillColor: "#FFF2CC", textColor: nil, borderColor: nil, isBold: true, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:00:00Z"
            ),
            .init(
                target: .column(sample: "AnimalA"),
                style: .init(fillColor: nil, textColor: "#C00000", borderColor: nil, isBold: false, isItalic: true),
                author: "test",
                timestamp: "2026-06-30T12:01:00Z"
            ),
            .init(
                target: .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
                style: .init(fillColor: "#D9EAD3", textColor: nil, borderColor: "#666666", isBold: false, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:02:00Z"
            ),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))

        let style = try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(style.fillColor?.hexString, "#D9EAD3")
        XCTAssertEqual(style.textColor?.hexString, "#C00000")
        XCTAssertEqual(style.borderColor?.hexString, "#666666")
        XCTAssertTrue(style.isBold)
        XCTAssertTrue(style.isItalic)
    }

    func testMatrixCellStyleCanClearInheritedBold() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixStyleOverride-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_001_01"
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: "MHC-A", genotype: genotype),
                style: .init(fillColor: nil, textColor: nil, borderColor: nil, isBold: true, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:00:00Z"
            ),
            .init(
                target: .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
                style: .init(
                    fillColor: "#D9EAD3",
                    textColor: nil,
                    borderColor: nil,
                    isBold: false,
                    isItalic: false,
                    boldOverride: false
                ),
                author: "test",
                timestamp: "2026-06-30T12:01:00Z"
            ),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))

        let style = try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(style.fillColor?.hexString, "#D9EAD3")
        XCTAssertFalse(style.isBold)
    }

    func testPerCellReadThresholdHidesCellsAndKeepsRowsWithVisibleCells() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 10)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        controller.configure(result: makeResult(samples: [], calls: [strong, weak]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, matrixMinimumReads: 5))

        XCTAssertEqual(controller.testingVisibleGenotypes, [genotype])
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalA"), "10")
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalB"), "")
    }

    func testPercentThresholdCanUseSampleOrLocusDenominator() {
        let genotype = "01_Mafa_A1_LOW"
        let low = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: genotype,
            passedAlignments: 4,
            passedUniqueReads: 4,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let high = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_HIGH",
            passedAlignments: 20,
            passedUniqueReads: 20,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 24,
                passedUniqueReads: 100,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [low, high]
            ),
        ], calls: [low, high]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            summaryViewMode: .matrix,
            matrixMinimumPercent: 10,
            matrixPercentDenominator: .sampleRetained
        ))
        XCTAssertFalse(controller.testingVisibleGenotypes.contains(genotype))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            summaryViewMode: .matrix,
            matrixMinimumPercent: 10,
            matrixPercentDenominator: .viewedLocus
        ))
        XCTAssertTrue(controller.testingVisibleGenotypes.contains(genotype))
    }

    func testSupportedCellSelectionHelperSkipsEmptyCells() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 2,
                passedUniqueReads: 2,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalC",
                passedAlignments: 0,
                passedUniqueReads: 0,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: []
            ),
        ], calls: [strong, weak]))
        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalC")

        let targets = controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 5)

        XCTAssertEqual(targets, [
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
        ])
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1.0))
        ))
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, targets)
        controller.addMatrixComment(GenotypeMatrixCommentRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Supported cell remains selected."
        ))
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, targets)
    }

    func testSupportedCellSelectionHelperStaysScopedToSelectedRow() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_A1_SECOND"
        let firstStrong = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let firstWeak = makeCall(sample: "AnimalB", genotype: first, reads: 2)
        let secondStrong = makeCall(sample: "AnimalB", genotype: second, reads: 7)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstStrong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstWeak, secondStrong]
            ),
        ], calls: [firstStrong, firstWeak, secondStrong]))

        controller.testingSelectMatrixRows(genotypes: [first], sample: nil)
        let targets = controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 5)

        XCTAssertEqual(targets, [
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
        ])
        XCTAssertFalse(controller.testingIsSelectedMatrixCell(genotype: first, sample: "AnimalB"))
        XCTAssertFalse(controller.testingIsSelectedMatrixCell(genotype: second, sample: "AnimalB"))
    }

    func testSupportedCellSelectionHelperWorksAfterRowChicletSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixSupportedChiclet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 12)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        let unrelated = makeCall(sample: "AnimalB", genotype: "02_Mafa_A1_SECOND", reads: 9)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 11,
                passedUniqueReads: 11,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak, unrelated]
            ),
        ], calls: [strong, weak, unrelated]))

        controller.testingClickMatrixRowChiclet(genotype: genotype)
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .row(locus: "MHC-A", genotype: genotype),
        ])

        let targets = controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 5)
        XCTAssertEqual(targets, [
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
        ])
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, targets)

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1.0))
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).fillColor?.hexString, "#33994C")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalB")).fillColor)
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: "02_Mafa_A1_SECOND", sample: "AnimalB")).fillColor)
    }

    func testSupportedCellSelectionHelperClearsRowSelectionWhenNoCellsPassThreshold() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixSupportedNone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let weak = makeCall(sample: "AnimalA", genotype: genotype, reads: 1)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 1,
                passedUniqueReads: 1,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
        ], calls: [weak]))

        controller.testingClickMatrixRowChiclet(genotype: genotype)
        let targets = controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 5)

        XCTAssertEqual(targets, [])
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [])
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1.0))
        ))
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).fillColor)
    }

    func testMatrixReadThresholdPersistsAcrossLensSwitchAndReconfigure() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 10)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        let result = makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 10,
                passedUniqueReads: 10,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 2,
                passedUniqueReads: 2,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
        ], calls: [strong, weak])
        controller.configure(result: result)
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, matrixMinimumReads: 5))

        controller.testingSelectLens(.audit)
        controller.testingSelectLens(.summary)
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalA"), "10")
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalB"), "")

        controller.configure(result: result)
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalA"), "10")
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalB"), "")
    }

    func testMatrixSelectionDetailsDifferentiateRowsColumnsAndCells() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixRows(genotypes: [genotype], sample: nil)
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Selection Type" && $0.1 == "Row"
        })

        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Selection Type" && $0.1 == "Cell"
        })

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Selection Type" && $0.1 == "Column"
        })
    }

    func testMatrixExplicitSelectionChicletsAndCellClickPublishDistinctTargets() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingClickMatrixCell(genotype: genotype, sample: "AnimalA")
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
        ])
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertFalse(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))

        controller.testingClickMatrixCell(genotype: genotype, sample: "AnimalB", modifiers: .command)
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalB"),
        ]))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))

        controller.testingClickMatrixColumnChiclet(sample: "AnimalB")
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .column(sample: "AnimalB"),
        ])
        XCTAssertFalse(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))

        controller.testingClickMatrixColumnChiclet(sample: "AnimalA", modifiers: .command)
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .column(sample: "AnimalA"),
            .column(sample: "AnimalB"),
        ]))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))

        controller.testingClickMatrixRowChiclet(genotype: genotype)
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .row(locus: "MHC-A", genotype: genotype),
        ])
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))
    }

    func testMatrixDirectSelectionSupportsShiftRanges() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_001_01"
        let second = "02_Mafa_A1_002_01"
        let third = "03_Mafa_A1_003_01"
        let calls = [
            makeCall(sample: "AnimalA", genotype: first, reads: 6),
            makeCall(sample: "AnimalA", genotype: second, reads: 7),
            makeCall(sample: "AnimalA", genotype: third, reads: 8),
            makeCall(sample: "AnimalB", genotype: first, reads: 9),
            makeCall(sample: "AnimalB", genotype: second, reads: 10),
            makeCall(sample: "AnimalB", genotype: third, reads: 11),
        ]
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 21,
                passedUniqueReads: 21,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: Array(calls[0...2])
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 30,
                passedUniqueReads: 30,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: Array(calls[3...5])
            ),
        ], calls: calls))

        controller.testingClickMatrixRowChiclet(genotype: first)
        controller.testingClickMatrixRowChiclet(genotype: third, modifiers: .shift)
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: first),
            .row(locus: "MHC-A", genotype: second),
            .row(locus: "MHC-A", genotype: third),
        ]))

        controller.testingClickMatrixCell(genotype: first, sample: "AnimalA")
        controller.testingClickMatrixCell(genotype: third, sample: "AnimalB", modifiers: .shift)
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalB"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalB"),
            .cell(locus: "MHC-A", genotype: third, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: third, sample: "AnimalB"),
        ]))
    }

    func testMatrixFreeTextSearchFiltersAllelesAndSamples() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_B1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: first, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: second, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSetComparisonFilter("B1")
        XCTAssertEqual(controller.testingVisibleGenotypes, [second])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])

        controller.testingSetComparisonFilter("AnimalA")
        XCTAssertEqual(controller.testingVisibleGenotypes, [first])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AnimalA"])

        controller.testingSetComparisonFilter("")
        XCTAssertEqual(Set(controller.testingVisibleGenotypes), Set([first, second]))
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])
    }

    func testMatrixFreeTextSearchFiltersSampleColumnsWhenSampleNameAlsoAppearsInGenotype() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mamu_A1_AR3628_marker"
        let callA = makeCall(sample: "AR3628", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AR3629", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AR3628",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AR3629",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSetComparisonFilter("AR3628")

        XCTAssertEqual(controller.testingVisibleGenotypes, [genotype])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AR3628"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AR3628"])
    }

    func testUnifiedQuickFilterPrioritizesSampleColumnMatchOverGenotypeTextMatch() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mamu_A1_AR3628_marker"
        let callA = makeCall(sample: "AR3628", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AR3629", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AR3628",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AR3629",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSetQuickFilterSearchText("AR3628")

        XCTAssertEqual(controller.testingVisibleGenotypes, [genotype])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AR3628"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AR3628"])
    }

    func testMatrixFreeTextSearchDoesNotTreatLocusMatchAsImplicitSampleFilter() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixAmbiguousSearch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try """
        Sample\tCohort
        AnimalA\tMHC-B review
        AnimalB\tcontrol
        """.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"), atomically: true, encoding: .utf8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let callA = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_SHARED", reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: "04_Mafa_B_001_01", reads: 8)
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSetComparisonFilter("MHC-B")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])
    }

    func testMatrixSelectionFiltersRowsUntilCleared() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_B_SHARED"
        let firstCall = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondCall = makeCall(sample: "AnimalB", genotype: second, reads: 9)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstCall]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [secondCall]
            ),
        ], calls: [firstCall, secondCall]))

        controller.testingClickMatrixRowChiclet(genotype: second)
        controller.testingShowOnlySelectedMatrixRows()

        XCTAssertEqual(controller.testingVisibleGenotypes, [second])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])

        controller.testingClearMatrixSelectionFilter()

        XCTAssertEqual(Set(controller.testingVisibleGenotypes), Set([first, second]))
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])
    }

    func testMatrixSelectionFiltersColumnsUntilCleared() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 12)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 9)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        controller.testingShowOnlySelectedMatrixColumns()

        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalB"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AnimalB"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleReadTitles, ["9"])

        controller.testingClearMatrixSelectionFilter()

        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleReadTitles, ["12", "9"])
    }

    func testMatrixKeepsIdentityColumnsSeparateFromScrollableSamples() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 12)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 9)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        XCTAssertEqual(controller.testingPinnedMatrixColumnTitles, ["", "Genotype", "Locus", "Samples", "Unique"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AnimalA", "AnimalB"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleReadTitles, ["12", "9"])
    }

    func testMatrixUpperLeftChicletSelectsAllVisibleRowsAndColumns() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_B_SHARED"
        let firstCall = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondCall = makeCall(sample: "AnimalB", genotype: second, reads: 9)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstCall]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [secondCall]
            ),
        ], calls: [firstCall, secondCall]))

        controller.testingClickMatrixSelectAllChiclet()

        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: first),
            .row(locus: "MHC-B", genotype: second),
            .column(sample: "AnimalA"),
            .column(sample: "AnimalB"),
        ]))
    }

    func testClearMatrixStyleWithAllRowsAndColumnsClearsIntersectingCellStyles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixClearAllStyles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_B_SHARED"
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: "MHC-A", genotype: first),
                style: .init(fillColor: "#FFF2CC", textColor: nil, borderColor: nil, isBold: true, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:00:00Z"
            ),
            .init(
                target: .column(sample: "AnimalB"),
                style: .init(fillColor: "#D9EAD3", textColor: nil, borderColor: nil, isBold: false, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:01:00Z"
            ),
            .init(
                target: .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
                style: .init(fillColor: "#FF0000", textColor: nil, borderColor: nil, isBold: false, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:02:00Z"
            ),
            .init(
                target: .cell(locus: "MHC-B", genotype: second, sample: "AnimalB"),
                style: .init(fillColor: "#B9AF1E", textColor: nil, borderColor: nil, isBold: false, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:03:00Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
                body: "Keep this comment.",
                author: "test",
                timestamp: "2026-06-30T12:04:00Z"
            ),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let firstCall = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondCall = makeCall(sample: "AnimalB", genotype: second, reads: 9)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstCall]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [secondCall]
            ),
        ], calls: [firstCall, secondCall]))

        controller.testingClickMatrixSelectAllChiclet()
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .clear
        ))

        let savedSidecar = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        )
        XCTAssertEqual(savedSidecar.matrixStyles, [])
        XCTAssertEqual(savedSidecar.matrixComments.count, 1)
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalA")).fillColor)
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: second, sample: "AnimalB")).fillColor)
    }

    func testMatrixRowSelectionFillAppliesOnlyCellsAtOrAboveReadThreshold() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixRowThresholdStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let exact = makeCall(sample: "AnimalA", genotype: genotype, reads: 5)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 4)
        let strong = makeCall(sample: "AnimalC", genotype: genotype, reads: 8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 5,
                passedUniqueReads: 5,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [exact]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 4,
                passedUniqueReads: 4,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalC",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
        ], calls: [exact, weak, strong]))

        controller.testingClickMatrixRowChiclet(genotype: genotype)
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(hex: "#FF0000")),
            minimumReads: 5
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).fillColor?.hexString, "#FF0000")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalB")).fillColor)
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalC")).fillColor?.hexString, "#FF0000")
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalC"),
        ]))
    }

    func testMatrixColumnSelectionFillAppliesOnlyCellsAtOrAboveReadThreshold() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixColumnThresholdStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_A1_SECOND"
        let firstA = makeCall(sample: "AnimalA", genotype: first, reads: 6)
        let firstB = makeCall(sample: "AnimalB", genotype: first, reads: 1)
        let secondA = makeCall(sample: "AnimalA", genotype: second, reads: 2)
        let secondB = makeCall(sample: "AnimalB", genotype: second, reads: 10)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstA, secondA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 11,
                passedUniqueReads: 11,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstB, secondB]
            ),
        ], calls: [firstA, firstB, secondA, secondB]))

        controller.testingSelectMatrixColumns(samples: ["AnimalA", "AnimalB"])
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(hex: "#00AAFF")),
            minimumReads: 5
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalA")).fillColor?.hexString, "#00AAFF")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalB")).fillColor)
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: second, sample: "AnimalA")).fillColor)
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: second, sample: "AnimalB")).fillColor?.hexString, "#00AAFF")
    }

    func testMatrixThresholdedRowFillRemovesExistingBroadRowFill() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixRowBroadThresholdStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 2,
                passedUniqueReads: 2,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
        ], calls: [strong, weak]))

        let rowTarget = GenotypeAnnotationSidecar.MatrixTarget.row(locus: "MHC-A", genotype: genotype)
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: [rowTarget],
            field: .fillColor(AnnotationColor(hex: "#FF0000"))
        ))
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: [rowTarget],
            field: .fillColor(AnnotationColor(hex: "#00AAFF")),
            minimumReads: 5
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).fillColor?.hexString, "#00AAFF")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalB")).fillColor)
    }

    func testMatrixThresholdedColumnFillRemovesExistingBroadColumnFillIncludingEmptyCells() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixColumnBroadThresholdStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_A1_SECOND"
        let strong = makeCall(sample: "AnimalA", genotype: first, reads: 6)
        let weak = makeCall(sample: "AnimalA", genotype: second, reads: 2)
        let other = makeCall(sample: "AnimalB", genotype: first, reads: 8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong, weak]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [other]
            ),
        ], calls: [strong, weak, other]))

        let columnTarget = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: [columnTarget],
            field: .fillColor(AnnotationColor(hex: "#FF0000"))
        ))
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: [columnTarget],
            field: .fillColor(AnnotationColor(hex: "#00AAFF")),
            minimumReads: 5
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalA")).fillColor?.hexString, "#00AAFF")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: second, sample: "AnimalA")).fillColor)
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalB")).fillColor)
    }

    func testMatrixSupportThresholdPreviewOutlinesEligibleCellsForRowAndColumnSelections() {
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 2,
                passedUniqueReads: 2,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
        ], calls: [strong, weak]))

        controller.testingClickMatrixRowChiclet(genotype: genotype)
        controller.testingSetMatrixSupportSelectionPreviewMinimumReads(5)

        XCTAssertTrue(controller.testingShowsSupportSelectionPreviewBorder(genotype: genotype, sample: "AnimalA"))
        XCTAssertFalse(controller.testingShowsSupportSelectionPreviewBorder(genotype: genotype, sample: "AnimalB"))
        XCTAssertFalse(controller.testingDrawsMatrixCellSelectionFocus(genotype: genotype, sample: "AnimalA"))
        XCTAssertFalse(controller.testingDrawsMatrixCellSelectionFocus(genotype: genotype, sample: "AnimalB"))

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        XCTAssertFalse(controller.testingShowsSupportSelectionPreviewBorder(genotype: genotype, sample: "AnimalB"))
        XCTAssertFalse(controller.testingShowsSupportSelectionPreviewBorder(genotype: genotype, sample: "AnimalA"))
        XCTAssertFalse(controller.testingDrawsMatrixCellSelectionFocus(genotype: genotype, sample: "AnimalB"))

        controller.testingSetMatrixSupportSelectionPreviewMinimumReads(2)
        XCTAssertTrue(controller.testingShowsSupportSelectionPreviewBorder(genotype: genotype, sample: "AnimalB"))
    }

    func testMatrixAnnotationStyleRedrawsOnlyAffectedSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixReloadScope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_A1_SECOND"
        let firstA = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondB = makeCall(sample: "AnimalB", genotype: second, reads: 9)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [secondB]
            ),
        ], calls: [firstA, secondB]))
        controller.testingResetMatrixReloadCounters()
        controller.testingSelectMatrixCell(genotype: first, sample: "AnimalA")
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .textColor(AnnotationColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1.0))
        ))

        XCTAssertEqual(controller.testingMatrixFullReloadCount, 0)
        XCTAssertGreaterThan(controller.testingMatrixPartialReloadCount, 0)
    }

    func testMatrixAnnotationWorkbookRefreshPreservesViewportState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixWorkbookRefreshState-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 12)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 9)
        let result = makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB])
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSetQuickFilterSearchText("AnimalA")
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(hex: "#00AAFF"))
        ))

        controller.applyCurrentWorkbookUpdateCompleted(result: result)
        controller.testingSetMatrixSupportSelectionPreviewMinimumReads(5)

        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AnimalA"])
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")?.fillColor?.hexString, "#00AAFF")
    }

    func testMatrixColumnSelectionPublishesColumnTarget() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixColumn(sample: "AnimalB")

        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .column(sample: "AnimalB"),
        ])
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Sample" && $0.1 == "AnimalB"
        })
    }

    func testMatrixColumnSelectionCanApplyStyleToMultipleColumns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixColumnStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalC",
                passedAlignments: 0,
                passedUniqueReads: 0,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: []
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixColumns(samples: ["AnimalA", "AnimalC"])
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .column(sample: "AnimalA"),
            .column(sample: "AnimalC"),
        ]))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertFalse(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalC"))

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1.0))
        ))

        let sidecarURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(Set(sidecar.matrixStyles.map(\.target)), Set([
            .column(sample: "AnimalA"),
            .column(sample: "AnimalC"),
        ]))
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).fillColor?.hexString, "#F2BF33")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalB")).fillColor)
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalC")).fillColor?.hexString, "#F2BF33")
    }

    func testMatrixColumnSelectionDoesNotSurviveCellOrRowSelection() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
        ])

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        controller.testingSelectMatrixRows(genotypes: [genotype], sample: nil)
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .row(locus: "MHC-A", genotype: genotype),
        ])
    }

    func testMatrixColumnSelectionClearsWhenSampleFilterHidesSelectedColumn() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        controller.testingApplyDisplayState(GenotypeResultDisplayState(matrixSampleFilterText: "AnimalA"))

        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [])
    }

    func testMatrixAnnotationStyleRequestPersistsAndRenders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixApplyStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_001_01"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))
        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1.0))
        ))
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .isBold(true)
        ))

        let sidecarURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(sidecar.matrixStyles.count, 1)
        XCTAssertEqual(sidecar.matrixStyles.first?.style.fillColor, "#33994C")
        XCTAssertEqual(sidecar.matrixStyles.first?.style.isBold, true)
        let style = try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(style.fillColor?.hexString, "#33994C")
        XCTAssertTrue(style.isBold)
    }

    func testMatrixAnnotationDarkFillRendersFullDepthWithWhiteText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixDarkFillStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_001_01"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))
        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(hex: "#0C0000"))
        ))

        let style = try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(style.fillColor?.hexString, "#0C0000")
        XCTAssertEqual(style.textColor?.hexString, "#FFFFFF")
        let background = try XCTUnwrap(controller.testingBackgroundColor(genotype: genotype, sample: "AnimalA"))
        let components = try XCTUnwrap(background.testingSRGBComponents)
        XCTAssertEqual(components.red, 12.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(components.green, 0, accuracy: 0.01)
        XCTAssertEqual(components.blue, 0, accuracy: 0.01)
        XCTAssertEqual(components.alpha, 1, accuracy: 0.01)
    }

    func testMatrixAnnotationStyleRequestAppliesToMultipleSelectedCells() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixApplyMultiStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_001_01"
        let second = "02_Mafa_A1_002_01"
        let calls = [
            makeCall(sample: "AnimalA", genotype: first, reads: 42),
            makeCall(sample: "AnimalA", genotype: second, reads: 21),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: calls))
        controller.testingSelectMatrixRows(genotypes: [first, second], sample: "AnimalA")

        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
        ]))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: first, sample: "AnimalA"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: second, sample: "AnimalA"))

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1.0))
        ))
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
        ]))
        controller.addMatrixComment(GenotypeMatrixCommentRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Review both calls."
        ))
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
        ]))

        let sidecarURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(sidecar.matrixStyles.count, 2)
        XCTAssertEqual(sidecar.matrixComments.count, 2)
        XCTAssertEqual(Set(sidecar.matrixStyles.map(\.target)), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
        ]))
        XCTAssertEqual(Set(sidecar.matrixComments.map(\.target)), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
        ]))
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalA")).fillColor?.hexString, "#F2BF33")
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: second, sample: "AnimalA")).fillColor?.hexString, "#F2BF33")
    }

    func testMatrixRowSelectionCanApplyTextColorAcrossEntireRow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixRowTextStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))
        controller.testingSelectMatrixRows(genotypes: [genotype], sample: nil)

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .textColor(AnnotationColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1.0))
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).textColor?.hexString, "#1933CC")
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalB")).textColor?.hexString, "#1933CC")
    }

    func testMatrixCommentsPersistAndAppearInSelectionDetails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixComment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_001_01"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [call]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 0,
                passedUniqueReads: 0,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: []
            ),
        ], calls: [call]))
        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalB")

        controller.addMatrixComment(GenotypeMatrixCommentRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Expected but missing."
        ))

        let sidecarURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(sidecar.matrixComments.map(\.body), ["Expected but missing."])
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Cell Comment" && $0.1 == "Expected but missing."
        })
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

    func testInspectorOverrideCanApplyBothHaplotypeSlotsInOneBatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultBatchOverride-\(UUID().uuidString)", isDirectory: true)
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

        controller.testingApplyOverridesFromInspector([
            .init(slot: .h1, haplotypeName: "M3DP"),
            .init(slot: .h2, haplotypeName: "M5DP"),
        ])

        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
        let h1Override = try XCTUnwrap(sidecar.callOverrides.first { $0.sample == "DW472" && $0.locus == "MHC-DP" && $0.slot == .h1 })
        let h2Override = try XCTUnwrap(sidecar.callOverrides.first { $0.sample == "DW472" && $0.locus == "MHC-DP" && $0.slot == .h2 })
        XCTAssertEqual(h1Override.originalCall, "M4DP")
        XCTAssertEqual(h1Override.overrideCall, "M3DP")
        XCTAssertEqual(h2Override.originalCall, "M7DP")
        XCTAssertEqual(h2Override.overrideCall, "M5DP")

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-DP"))
        XCTAssertEqual(evidence.h1Name, "M3DP")
        XCTAssertEqual(evidence.h2Name, "M5DP")
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
        stats: ONTGenotypeRunStats = ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60),
        referenceMetadata: ONTGenotypeReferenceMetadata? = nil
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
            haplotypeAnalysis: haplotypeAnalysis,
            referenceMetadata: referenceMetadata
        )
    }

    private func makeGenBankReferenceMetadata() -> ONTGenotypeReferenceMetadata {
        let fields = [
            GenBankRecordDatabase.FieldDefinition(key: "feature.allele", displayTitle: "Allele", valueType: "text", sourceCategory: "feature", preferredOrder: 0),
            GenBankRecordDatabase.FieldDefinition(key: "source.organism", displayTitle: "Organism", valueType: "text", sourceCategory: "source", preferredOrder: 1),
            GenBankRecordDatabase.FieldDefinition(key: "feature.product", displayTitle: "Product", valueType: "text", sourceCategory: "feature", preferredOrder: 2),
            GenBankRecordDatabase.FieldDefinition(key: "record.definition", displayTitle: "Definition", valueType: "text", sourceCategory: "record", preferredOrder: 3),
        ]
        return ONTGenotypeReferenceMetadata(
            fields: fields,
            recordsBySequenceName: [
                "NHP01222": [
                    "feature.allele": "Mafa-A1*001:01",
                    "source.organism": "Macaca fascicularis",
                    "feature.product": "MHC class I A1 antigen",
                    "record.definition": "Mafa-A1 complete coding sequence",
                ],
                "NHP99999": [
                    "feature.allele": "Mafa-B*002:01",
                    "source.organism": "Macaca fascicularis",
                    "feature.product": "MHC class I B antigen",
                    "record.definition": "Mafa-B complete coding sequence",
                ],
            ],
            alleleFieldKey: "feature.allele"
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

    private func makeWeakSupportAnalysis(
        h1: String,
        h2: String,
        h1Allele: String,
        h2Allele: String
    ) -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
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
                            haplotype1: h1,
                            haplotype2: h2,
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: h1,
                                    diagnosticAlleles: [h1Allele],
                                    observedDiagnosticAlleles: [h1Allele]
                                ),
                                GenotypeHaplotypeMatchedDefinition(
                                    name: h2,
                                    diagnosticAlleles: [h2Allele],
                                    observedDiagnosticAlleles: [h2Allele]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: [h1Allele, h2Allele]
                        )
                    ]
                )
            ]
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
             .weakReference(_, let label),
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

    var testingIsWeakSupport: Bool {
        if case .weakReference = self { return true }
        return false
    }
}

private extension NSColor {
    var testingSRGBComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
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
