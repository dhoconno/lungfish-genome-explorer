import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO

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

    private func makeResult(
        bundleURL: URL = URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
        samples: [ONTGenotypeSampleResult],
        calls: [ONTGenotypeCall],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil
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
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis
        )
    }
}
