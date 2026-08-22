import XCTest
import AppKit
import SwiftUI
import CryptoKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport

// Haplotype definition matrix, search index, and quick search
@MainActor
final class GenotypeResultViewportHaplotypeDefinitionSearchTests: GenotypeResultViewportTestCase {
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
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
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
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
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
        let root = try TestTempDirectory.make(prefix: "GenotypeMatrixStyles")
        defer { TestTempDirectory.cleanup(root) }
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
        let root = try TestTempDirectory.make(prefix: "GenotypeMatrixStyleOverride")
        defer { TestTempDirectory.cleanup(root) }
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
        controller.addMatrixComment(GenotypeMatrixCommentEditRequest(
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
        let root = try TestTempDirectory.make(prefix: "GenotypeMatrixSupportedChiclet")
        defer { TestTempDirectory.cleanup(root) }
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
        let root = try TestTempDirectory.make(prefix: "GenotypeMatrixSupportedNone")
        defer { TestTempDirectory.cleanup(root) }
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


    func testSharedQuickSearchRoutesSampleSubstringAndDisplayedAlleleByStableIDs() {
        let allele007 = "01_Mafa_A1_INTERNAL_007"
        let allele007b = "01_Mafa_A1_INTERNAL_007B"
        let coincidental1178 = "04_Mafa_B_1178_MARKER"
        let calls = [
            makeCall(sample: "CR1178", genotype: allele007, reads: 20),
            makeCall(sample: "CR1178b", genotype: allele007b, reads: 18),
            makeCall(sample: "OTHER", genotype: coincidental1178, reads: 16),
        ]
        let samples = ["CR1178", "CR1178b", "OTHER"].map { sample in
            let sampleCalls = calls.filter { $0.sample == sample }
            return ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: sampleCalls.reduce(0) { $0 + $1.passedAlignments },
                passedUniqueReads: sampleCalls.reduce(0) { $0 + $1.passedUniqueReads },
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: sampleCalls
            )
        }
        let alleleField = GenBankRecordDatabase.FieldDefinition(
            key: "feature.allele",
            displayTitle: "Allele",
            valueType: "text",
            sourceCategory: "feature",
            preferredOrder: 0
        )
        let metadata = ONTGenotypeReferenceMetadata(
            fields: [alleleField],
            recordsBySequenceName: [
                allele007: ["feature.allele": "Mafa-A1*007:01"],
                allele007b: ["feature.allele": "Mafa-A1*007:08"],
                coincidental1178: ["feature.allele": "Mafa-B*001:01"],
            ],
            alleleFieldKey: "feature.allele"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: samples,
            calls: calls,
            referenceMetadata: metadata
        ))

        controller.testingSetQuickFilterSearchText("1178")
        XCTAssertEqual(
            controller.testingVisibleMatrixSamples,
            ["CR1178", "CR1178b"]
        )
        XCTAssertEqual(
            Set(controller.testingVisibleGenotypes),
            [allele007, allele007b]
        )

        controller.testingSetQuickFilterSearchText("CR1178")
        XCTAssertEqual(
            controller.testingVisibleMatrixSamples,
            ["CR1178", "CR1178b"]
        )
        XCTAssertEqual(
            Set(controller.testingVisibleGenotypes),
            [allele007, allele007b]
        )

        controller.testingSetQuickFilterSearchText("A1*007")
        XCTAssertEqual(
            controller.testingVisibleMatrixSamples,
            ["CR1178", "CR1178b", "OTHER"]
        )
        XCTAssertEqual(
            Set(controller.testingVisibleGenotypes),
            [allele007, allele007b]
        )
    }


    func testSharedQuickSearchPreservesStableSampleColumnOrderWidthAndAvoidsEquivalentRebuild() {
        let calls = [
            makeCall(sample: "CR1178", genotype: "allele-a", reads: 20),
            makeCall(sample: "CR1178b", genotype: "allele-b", reads: 18),
            makeCall(sample: "OTHER", genotype: "allele-c", reads: 16),
        ]
        let samples = ["CR1178", "CR1178b", "OTHER"].map { sample in
            let sampleCalls = calls.filter { $0.sample == sample }
            return ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: sampleCalls.reduce(0) { $0 + $1.passedAlignments },
                passedUniqueReads: sampleCalls.reduce(0) { $0 + $1.passedUniqueReads },
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: sampleCalls
            )
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: samples, calls: calls))
        let matrix = controller.testingComparisonMatrix
        matrix.testingMoveSampleColumn(sample: "OTHER", to: 0)
        matrix.testingSetSampleColumnWidth(sample: "CR1178", width: 123)
        let sampleSortKey = try! XCTUnwrap(
            matrix.testingSortKey(forSample: "CR1178")
        )
        matrix.testingSetSortDescriptor(key: sampleSortKey, ascending: false)

        controller.testingSetQuickFilterSearchText("CR1178")
        XCTAssertEqual(
            controller.testingVisibleMatrixSampleColumnTitles,
            ["CR1178", "CR1178b"]
        )
        XCTAssertEqual(
            matrix.testingSampleColumnWidth(sample: "CR1178"),
            123,
            accuracy: 0.01
        )
        XCTAssertEqual(matrix.testingActiveSortDescriptorKey, sampleSortKey)

        controller.testingResetProjectionPerformanceCounters()
        controller.testingSetQuickFilterSearchText("1178")
        XCTAssertEqual(
            controller.testingVisibleMatrixSampleColumnTitles,
            ["CR1178", "CR1178b"]
        )
        XCTAssertEqual(
            controller.testingProjectionPerformanceSnapshot.matrix.columnRebuildCount,
            0
        )
        XCTAssertEqual(matrix.testingActiveSortDescriptorKey, sampleSortKey)

        controller.testingSetQuickFilterSearchText("")
        XCTAssertEqual(
            controller.testingVisibleMatrixSampleColumnTitles,
            ["OTHER", "CR1178", "CR1178b"]
        )
        XCTAssertEqual(
            matrix.testingSampleColumnWidth(sample: "CR1178"),
            123,
            accuracy: 0.01
        )
        XCTAssertEqual(matrix.testingActiveSortDescriptorKey, sampleSortKey)
    }


    func testVisibleReferenceColumnChangeRebuildsAndReappliesActiveSearchIndex() {
        GenotypeComparisonMatrixView.testingResetPersistedReferenceVisibility()
        defer {
            GenotypeComparisonMatrixView.testingResetPersistedReferenceVisibility()
        }
        let rawGenotype = "internal-a1"
        let call = makeCall(sample: "AnimalA", genotype: rawGenotype, reads: 9)
        let sample = ONTGenotypeSampleResult(
            sample: "AnimalA",
            passedAlignments: 9,
            passedUniqueReads: 9,
            sampleTotalReads: nil,
            sampleUniqueRetainedPercent: nil,
            calls: [call]
        )
        let alleleKey = "feature.allele.search-regression"
        let productKey = "feature.product.search-regression"
        let metadata = ONTGenotypeReferenceMetadata(
            fields: [
                .init(
                    key: alleleKey,
                    displayTitle: "Allele",
                    valueType: "text",
                    sourceCategory: "feature",
                    preferredOrder: 0
                ),
                .init(
                    key: productKey,
                    displayTitle: "Product",
                    valueType: "text",
                    sourceCategory: "feature",
                    preferredOrder: 1
                ),
            ],
            recordsBySequenceName: [
                rawGenotype: [
                    alleleKey: "Mafa-A1*001:01",
                    productKey: "hidden-search-product",
                ],
            ],
            alleleFieldKey: alleleKey
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [sample],
            calls: [call],
            referenceMetadata: metadata
        ))
        let matrix = controller.testingComparisonMatrix
        matrix.testingSetReferenceColumnVisibleWithoutPersist(
            fieldKey: productKey,
            visible: false
        )
        controller.testingResetSearchPerformanceCounters()

        controller.testingSetQuickFilterSearchText("hidden-search-product")
        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 1)

        matrix.testingSetReferenceColumnVisible(fieldKey: productKey, visible: true)

        XCTAssertEqual(controller.testingVisibleGenotypes, [rawGenotype])
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 2)
        XCTAssertEqual(controller.testingSearchQueryCount, 2)
    }


    func testSavingSharedSearchMaterializesDisplayedAliasAndSamplePriorityStableIDs() throws {
        let allele007 = "01_Mafa_A1_INTERNAL_007"
        let allele007b = "01_Mafa_A1_INTERNAL_007B"
        let coincidental1178 = "04_Mafa_B_1178_MARKER"
        let calls = [
            makeCall(sample: "CR1178", genotype: allele007, reads: 20),
            makeCall(sample: "CR1178b", genotype: allele007b, reads: 18),
            makeCall(sample: "OTHER", genotype: coincidental1178, reads: 16),
        ]
        let samples = ["CR1178", "CR1178b", "OTHER"].map { sample in
            let sampleCalls = calls.filter { $0.sample == sample }
            return ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: sampleCalls.reduce(0) { $0 + $1.passedAlignments },
                passedUniqueReads: sampleCalls.reduce(0) { $0 + $1.passedUniqueReads },
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: sampleCalls
            )
        }
        let alleleField = GenBankRecordDatabase.FieldDefinition(
            key: "feature.allele.saved-search",
            displayTitle: "Allele",
            valueType: "text",
            sourceCategory: "feature",
            preferredOrder: 0
        )
        let metadata = ONTGenotypeReferenceMetadata(
            fields: [alleleField],
            recordsBySequenceName: [
                allele007: [alleleField.key: "Mafa-A1*007:01"],
                allele007b: [alleleField.key: "Mafa-A1*007:08"],
                coincidental1178: [alleleField.key: "Mafa-B*001:01"],
            ],
            alleleFieldKey: alleleField.key
        )

        func savedIDs(for query: String) throws -> [String] {
            let root = try TestTempDirectory.make(prefix: "GenotypeSavedSharedSearch")
            defer { TestTempDirectory.cleanup(root) }
            let bundleURL = root.appendingPathComponent(
                "test.lungfishgenotype",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: bundleURL,
                withIntermediateDirectories: true
            )
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: makeResult(
                bundleURL: bundleURL,
                samples: samples,
                calls: calls,
                haplotypeAnalysis: makeEmptyHaplotypeAnalysis(),
                referenceMetadata: metadata
            ))
            controller.testingSetQuickFilterSearchText(query)
            try controller.testingSaveCurrentFilterAsSmartCohort()
            let sidecar = try GenotypeAnnotationStore(
                bundleURL: bundleURL,
                author: "test"
            ).sidecar
            let saved = try XCTUnwrap(sidecar.smartCohorts.last)
            guard case let .animalIdIn(ids) = saved.predicate else {
                XCTFail("Expected stable animalIdIn predicate, got \(saved.predicate)")
                return []
            }
            XCTAssertEqual(saved.searchProjectionText, query)
            return ids
        }

        XCTAssertEqual(
            try savedIDs(for: "A1*007"),
            ["CR1178", "CR1178b"]
        )
        XCTAssertEqual(
            try savedIDs(for: "1178"),
            ["CR1178", "CR1178b"]
        )
    }


    func testSavingFilterPreservesActiveProjectionAndNewSearchOverridesIt() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeSavedProjection")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent(
            "test.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001", reads: 9),
            makeCall(sample: "AnimalB", genotype: "04_Mafa_B_001", reads: 8),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))
        controller.testingApplySmartCohort(GenotypeCohortSmartFilter(
            name: "Base",
            predicate: .animalIdIn(["AnimalA", "AnimalB"]),
            searchProjectionText: "A1*001"
        ))

        try controller.testingSaveCurrentFilterAsSmartCohort()
        var sidecar = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "test"
        ).sidecar
        XCTAssertEqual(sidecar.smartCohorts.last?.searchProjectionText, "A1*001")

        controller.testingSetQuickFilterSearchText("AnimalA")
        try controller.testingSaveCurrentFilterAsSmartCohort()
        sidecar = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "test"
        ).sidecar
        XCTAssertEqual(sidecar.smartCohorts.last?.searchProjectionText, "AnimalA")
        guard case let .all(predicates) = sidecar.smartCohorts.last?.predicate else {
            return XCTFail("Expected active cohort and new search intersection")
        }
        XCTAssertTrue(predicates.contains(.animalIdIn(["AnimalA", "AnimalB"])))
        XCTAssertTrue(predicates.contains(.animalIdIn(["AnimalA"])))
    }


    func testQuickSearchCapabilityCopyAccessibilityAndGenotypeOnlyHaplotypeGate() throws {
        let genotypeController = GenotypeResultViewController()
        _ = genotypeController.view
        let call = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001", reads: 9)
        genotypeController.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 9,
                    passedUniqueReads: 9,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [call]
                ),
            ],
            calls: [call]
        ))

        XCTAssertEqual(
            genotypeController.testingQuickSearchPlaceholder,
            "Search samples or alleles…"
        )
        XCTAssertEqual(
            genotypeController.testingQuickSearchAccessibilityLabel,
            "Search samples or alleles"
        )
        XCTAssertEqual(
            genotypeController.testingQuickSearchAccessibilityIdentifier,
            "genotype-quick-search"
        )
        genotypeController.testingResetSearchPerformanceCounters()
        genotypeController.testingSetQuickFilterSearchText("HAP-A")
        XCTAssertEqual(genotypeController.testingSearchIndexBuildCount, 1)
        XCTAssertEqual(genotypeController.testingSearchHaplotypeRecordBuildCount, 0)

        let haplotypedController = GenotypeResultViewController()
        _ = haplotypedController.view
        haplotypedController.configure(result: makeResult(
            samples: [],
            calls: [],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))
        XCTAssertEqual(
            haplotypedController.testingQuickSearchPlaceholder,
            "Search samples, alleles, or haplotypes…"
        )
        XCTAssertEqual(
            haplotypedController.testingQuickSearchAccessibilityLabel,
            "Search samples, alleles, or haplotypes"
        )
    }


    func testQuickSearchEmptyStateAnnouncesOnceRecoversAndDoesNotStealFocus() {
        let announcements = RecordingGenotypeSearchAnnouncements()
        let controller = GenotypeResultViewController()
        controller.testingSetSearchAnnouncementPoster(announcements)
        _ = controller.view
        let call = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001", reads: 9)
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 9,
                    passedUniqueReads: 9,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [call]
                ),
            ],
            calls: [call]
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        let sentinel = NSTextField(string: "Keep focus here")
        host.addSubview(controller.view)
        host.addSubview(sentinel)
        window.contentView = host
        XCTAssertTrue(window.makeFirstResponder(sentinel))
        let responderBeforeSearch = window.firstResponder

        controller.testingSetQuickFilterSearchText("not-present")

        XCTAssertTrue(window.firstResponder === responderBeforeSearch)
        XCTAssertEqual(
            controller.testingQuickSearchEmptyMessage,
            "No samples or alleles match “not-present”. Press Escape to clear the search."
        )
        XCTAssertEqual(announcements.messages.count, 1)

        controller.testingSetQuickFilterSearchText("not-present")
        XCTAssertEqual(announcements.messages.count, 1)

        controller.testingSetQuickFilterSearchText("AnimalA")
        XCTAssertEqual(controller.testingQuickSearchEmptyMessage, "")

        controller.testingSetQuickFilterSearchText("still-not-present")
        XCTAssertEqual(announcements.messages.count, 2)

        XCTAssertTrue(controller.testingFocusQuickSearch())
        let fieldEditor = window.firstResponder
        XCTAssertNotNil(fieldEditor)
        controller.testingTypeQuickSearchDebounced("debounced-not-present")
        let expectedDebouncedMessage = "No samples or alleles match “debounced-not-present”. Press Escape to clear the search."
        waitUntilQuickSearchSettles(controller, timeout: 10.0) {
            controller.testingQuickSearchEmptyMessage == expectedDebouncedMessage
        }
        XCTAssertTrue(window.firstResponder === fieldEditor)
        XCTAssertTrue(controller.testingQuickSearchIsFocused)
        XCTAssertEqual(controller.testingQuickSearchText, "debounced-not-present")
        XCTAssertEqual(controller.testingQuickSearchEmptyMessage, expectedDebouncedMessage)
    }


    func testQuickSearchIndexIsReusedAndMetadataReplacementInvalidatesIt() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001", reads: 9)
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 9,
                    passedUniqueReads: 9,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [call]
                ),
            ],
            calls: [call]
        ))
        controller.testingResetSearchPerformanceCounters()

        controller.testingSetQuickFilterSearchText("Animal")
        controller.testingSetQuickFilterSearchText("A1")
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 1)
        XCTAssertEqual(controller.testingSearchQueryCount, 2)

        let metadata = try SampleMetadataStore(
            csvData: Data("Sample\tCohort\nAnimalA\tTreatment Alpha\n".utf8),
            knownSampleIds: ["AnimalA"]
        )
        controller.applySampleMetadataStore(metadata)
        controller.testingSetQuickFilterSearchText("Treatment Alpha")

        XCTAssertEqual(controller.testingSearchIndexBuildCount, 2)
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA"])
    }


    func testCommandFFocusesQuickSearchAndEscapeClearsIt() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001", reads: 9)
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 9,
                    passedUniqueReads: 9,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [call]
                ),
            ],
            calls: [call]
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        let commandF = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        ))

        XCTAssertTrue(controller.performKeyEquivalent(with: commandF))
        XCTAssertTrue(controller.testingQuickSearchIsFocused)

        controller.testingSetQuickFilterSearchText("AnimalA")
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))

        XCTAssertTrue(controller.performKeyEquivalent(with: escape))
        XCTAssertEqual(controller.testingQuickSearchText, "")
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA"])
    }


    func testQuickSearchResultAndReferenceReplacementInvalidatesIndex() {
        let rawGenotype = "01_Mafa_A1_INTERNAL"
        let call = makeCall(sample: "AnimalA", genotype: rawGenotype, reads: 9)
        let sample = ONTGenotypeSampleResult(
            sample: "AnimalA",
            passedAlignments: 9,
            passedUniqueReads: 9,
            sampleTotalReads: nil,
            sampleUniqueRetainedPercent: nil,
            calls: [call]
        )
        let alleleField = GenBankRecordDatabase.FieldDefinition(
            key: "feature.allele",
            displayTitle: "Allele",
            valueType: "text",
            sourceCategory: "feature",
            preferredOrder: 0
        )
        func metadata(_ allele: String) -> ONTGenotypeReferenceMetadata {
            ONTGenotypeReferenceMetadata(
                fields: [alleleField],
                recordsBySequenceName: [
                    rawGenotype: ["feature.allele": allele],
                ],
                alleleFieldKey: "feature.allele"
            )
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [sample],
            calls: [call],
            referenceMetadata: metadata("Mafa-A1*007:01")
        ))
        controller.testingResetSearchPerformanceCounters()
        controller.testingSetQuickFilterSearchText("A1*007")
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 1)
        XCTAssertEqual(controller.testingVisibleGenotypes, [rawGenotype])

        controller.testingSetQuickFilterSearchText("")
        controller.configure(result: makeResult(
            samples: [sample],
            calls: [call],
            referenceMetadata: metadata("Mafa-A1*099:01")
        ))
        controller.testingSetQuickFilterSearchText("A1*099")

        XCTAssertEqual(controller.testingSearchIndexBuildCount, 2)
        XCTAssertEqual(controller.testingVisibleGenotypes, [rawGenotype])
    }


    func testCurrentWorkbookResultReplacementRefreshesConfiguredMatrixSearchSource() {
        let oldCall = makeCall(
            sample: "AnimalA",
            genotype: "old-internal-genotype",
            reads: 9
        )
        let newCall = makeCall(
            sample: "AnimalA",
            genotype: "new-internal-genotype",
            reads: 11
        )
        let sample: (ONTGenotypeCall) -> ONTGenotypeSampleResult = { call in
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: call.passedAlignments,
                passedUniqueReads: call.passedUniqueReads,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [call]
            )
        }
        let alleleField = GenBankRecordDatabase.FieldDefinition(
            key: "feature.allele.workbook-search",
            displayTitle: "Allele",
            valueType: "text",
            sourceCategory: "feature",
            preferredOrder: 0
        )
        let oldMetadata = ONTGenotypeReferenceMetadata(
            fields: [alleleField],
            recordsBySequenceName: [
                oldCall.genotype: [alleleField.key: "Mafa-A1*001:01"],
            ],
            alleleFieldKey: alleleField.key
        )
        let newMetadata = ONTGenotypeReferenceMetadata(
            fields: [alleleField],
            recordsBySequenceName: [
                newCall.genotype: [alleleField.key: "Mafa-A1*099:01"],
            ],
            alleleFieldKey: alleleField.key
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [sample(oldCall)],
            calls: [oldCall],
            referenceMetadata: oldMetadata
        ))
        _ = controller.testingComparisonMatrix
        controller.testingSetQuickFilterSearchText("A1*099")
        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)

        controller.applyCurrentWorkbookUpdateCompleted(result: makeResult(
            samples: [sample(newCall)],
            calls: [newCall],
            referenceMetadata: newMetadata
        ))

        XCTAssertEqual(
            controller.testingVisibleGenotypes,
            [newCall.genotype]
        )
    }


    func testQuickSearchMatrixCommentMutationInvalidatesIndex() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeSearchComment")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let genotype = "01_Mafa_A1_INTERNAL"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 9)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 9,
                    passedUniqueReads: 9,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [call]
                ),
            ],
            calls: [call]
        ))
        controller.testingResetSearchPerformanceCounters()
        controller.testingSetQuickFilterSearchText("analyst-note")
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 1)
        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)

        controller.addMatrixComment(GenotypeMatrixCommentEditRequest(
            targets: [
                .row(locus: call.locusGroup, genotype: genotype),
            ],
            body: "analyst-note"
        ))

        XCTAssertEqual(controller.testingSearchIndexBuildCount, 2)
        XCTAssertEqual(controller.testingVisibleGenotypes, [genotype])

        controller.applyMatrixReview(GenotypeMatrixReviewRequest(
            targets: [
                .cell(
                    locus: call.locusGroup,
                    genotype: genotype,
                    sample: "AnimalA"
                ),
            ],
            intent: .set(.falsePositive)
        ))
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 2)
        XCTAssertEqual(controller.testingVisibleGenotypes, [genotype])

        controller.editMatrixComment(GenotypeMatrixCommentEditRequest(
            targets: [
                .row(locus: call.locusGroup, genotype: genotype),
            ],
            intent: .remove
        ))
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 3)
        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)
    }


    func testQuickSearchCandidateInvalidationDependsOnVisibilityNotTintOrNoOp() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeCandidateSearchDeps")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent(
            "test.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let provisionalName = "Mafa-A1*900:01_search_nov"
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeCandidateResult(
            bundleURL: bundleURL,
            calls: [
                makeCall(
                    sample: "AnimalA",
                    genotype: "known-control",
                    reads: 9
                ),
            ],
            candidates: [
                makeCandidate(
                    id: "search-candidate",
                    name: provisionalName,
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: "search-candidate",
                    sample: "AnimalA",
                    reads: 7
                ),
            ]
        ))
        _ = controller.testingComparisonMatrix
        controller.testingResetSearchPerformanceCounters()
        controller.testingSetQuickFilterSearchText("900:01")
        XCTAssertEqual(controller.testingVisibleGenotypes, [provisionalName])
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 1)

        var tintState = controller.testingDisplayState
        var tintSettings = tintState.mhcCandidateDisplaySettings ?? .default
        tintSettings.tints[.singletonNovel] = AnnotationColor(hex: "#123456")!
        tintState.mhcCandidateDisplaySettings = tintSettings
        controller.testingApplyDisplayStateImmediately(tintState)
        controller.testingApplyDisplayStateImmediately(tintState)
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 1)
        XCTAssertEqual(controller.testingVisibleGenotypes, [provisionalName])

        var hiddenState = tintState
        var hiddenSettings = tintSettings
        hiddenSettings.showSingletonCandidates = false
        hiddenState.mhcCandidateDisplaySettings = hiddenSettings
        controller.testingApplyDisplayStateImmediately(hiddenState)
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 2)
        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)

        controller.testingApplyDisplayStateImmediately(hiddenState)
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 2)
    }


    func testMatrixFreeTextSearchDoesNotTreatLocusMatchAsImplicitSampleFilter() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeMatrixAmbiguousSearch")
        defer { TestTempDirectory.cleanup(root) }
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


    func testMatrixRowSelectorReflectsOnlyWholeRowSelection() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_B_SHARED"
        let firstCall = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondCall = makeCall(sample: "AnimalA", genotype: second, reads: 9)
        controller.configure(result: makeResult(samples: [], calls: [firstCall, secondCall]))

        controller.testingClickMatrixCell(genotype: first, sample: "AnimalA")
        XCTAssertFalse(controller.testingMatrixRowSelectorIsSelected(genotype: first))
        XCTAssertFalse(controller.testingMatrixColumnSelectorIsSelected(sample: "AnimalA"))

        controller.testingClickMatrixRowChiclet(genotype: first)
        XCTAssertTrue(controller.testingMatrixRowSelectorIsSelected(genotype: first))
        XCTAssertFalse(controller.testingMatrixRowSelectorIsSelected(genotype: second))

        let selector = try XCTUnwrap(
            controller.testingMatrixRowSelectorAccessibility(genotype: first)
        )
        XCTAssertEqual(selector.role, .checkBox)
        XCTAssertEqual(selector.label, "Select allele row \(first)")
        XCTAssertEqual(selector.value, true)
        XCTAssertTrue(selector.identifier.hasPrefix("genotype-row-selector.known:"))
        XCTAssertTrue(selector.identifier.hasSuffix(first))
        XCTAssertTrue(selector.supportsPress)
    }


    func testMatrixSelectorsExposeCheckboxSemanticsAndVoiceOverPress() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_B_SHARED"
        let firstCall = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondCall = makeCall(sample: "AnimalB", genotype: second, reads: 9)
        controller.configure(result: makeResult(samples: [], calls: [firstCall, secondCall]))

        let row = try XCTUnwrap(
            controller.testingMatrixRowSelectorAccessibility(genotype: first)
        )
        XCTAssertEqual(row.role, .checkBox)
        XCTAssertFalse(row.value)
        XCTAssertEqual(row.numericValue, NSNumber(value: 0))
        XCTAssertEqual(row.valueDescription, "Not selected")
        XCTAssertTrue(row.acceptsKeyboardFocus)
        XCTAssertTrue(controller.testingPerformMatrixRowSelectorAccessibilityPress(genotype: first))
        XCTAssertTrue(controller.testingMatrixRowSelectorIsSelected(genotype: first))
        let selectedRow = try XCTUnwrap(
            controller.testingMatrixRowSelectorAccessibility(genotype: first)
        )
        XCTAssertEqual(selectedRow.numericValue, NSNumber(value: 1))
        XCTAssertEqual(selectedRow.valueDescription, "Selected")

        let column = try XCTUnwrap(
            controller.testingMatrixColumnSelectorAccessibility(sample: "AnimalB")
        )
        XCTAssertEqual(column.role, .checkBox)
        XCTAssertEqual(column.label, "Select sample column AnimalB")
        XCTAssertEqual(column.identifier, "genotype-column-selector.AnimalB")
        XCTAssertFalse(column.value)
        XCTAssertEqual(column.numericValue, NSNumber(value: 0))
        XCTAssertEqual(column.valueDescription, "Not selected")
        XCTAssertTrue(column.acceptsKeyboardFocus)
        XCTAssertTrue(controller.testingPerformMatrixColumnSelectorAccessibilityPress(sample: "AnimalB"))
        XCTAssertTrue(controller.testingMatrixColumnSelectorIsSelected(sample: "AnimalB"))
        let selectedColumn = try XCTUnwrap(
            controller.testingMatrixColumnSelectorAccessibility(sample: "AnimalB")
        )
        XCTAssertEqual(selectedColumn.numericValue, NSNumber(value: 1))
        XCTAssertEqual(selectedColumn.valueDescription, "Selected")

        let selectAll = try XCTUnwrap(controller.testingMatrixSelectAllAccessibility)
        XCTAssertEqual(selectAll.role, .checkBox)
        XCTAssertEqual(
            selectAll.label,
            "Select all visible allele rows and sample columns"
        )
        XCTAssertFalse(selectAll.value)
        XCTAssertEqual(selectAll.numericValue, NSNumber(value: 0))
        XCTAssertEqual(selectAll.valueDescription, "Not selected")
        XCTAssertTrue(selectAll.acceptsKeyboardFocus)
        XCTAssertTrue(controller.testingPerformMatrixSelectAllAccessibilityPress())
        let selectedAll = try XCTUnwrap(controller.testingMatrixSelectAllAccessibility)
        XCTAssertTrue(selectedAll.value)
        XCTAssertEqual(selectedAll.numericValue, NSNumber(value: 1))
        XCTAssertEqual(selectedAll.valueDescription, "Selected")

        let rowTree = try XCTUnwrap(
            controller.testingComparisonMatrix
                .testingRowSelectorAccessibilityTree(genotype: first)
        )
        XCTAssertFalse(rowTree.cellIsAccessibilityElement)
        XCTAssertFalse(rowTree.chicletIsAccessibilityElement)
        XCTAssertEqual(rowTree.actionableDescendantCount, 1)
    }


    func testMatrixSelectorReuseNotifiesOnlyStateChangesForSameIdentity() {
        let matrix = GenotypeComparisonMatrixView()

        XCTAssertEqual(
            matrix.testingSelectorReuseNotificationSnapshot(),
            GenotypeMatrixSelectorReuseNotificationSnapshot(
                afterInitialConfiguration: 0,
                afterDifferentIdentityConfiguration: 0,
                afterSameIdentityStateChange: 1
            )
        )
        XCTAssertEqual(
            matrix.testingAccessibilityPressModifiers(),
            NSEvent.ModifierFlags()
        )
    }


    func testMatrixSelectorAccessibilityProxiesAreStableAndPostStateNotifications() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 12)
        let second = makeCall(sample: "AnimalB", genotype: "02_Mafa_B", reads: 9)
        controller.configure(result: makeResult(samples: [], calls: [first, second]))
        let matrix = controller.testingComparisonMatrix
        let rowProxy = try XCTUnwrap(
            matrix.testingRowSelectorObjectIdentifier(genotype: first.genotype)
        )
        let columnProxy = try XCTUnwrap(
            matrix.testingColumnSelectorObjectIdentifier(sample: "AnimalB")
        )
        let selectAllProxy = try XCTUnwrap(
            matrix.testingSelectAllSelectorObjectIdentifier
        )
        let valueChangedBaseline =
            matrix.testingAccessibilityValueChangedNotificationCount

        XCTAssertTrue(
            controller.testingPerformMatrixRowSelectorAccessibilityPress(
                genotype: first.genotype
            )
        )
        XCTAssertTrue(
            controller.testingPerformMatrixColumnSelectorAccessibilityPress(
                sample: "AnimalB"
            )
        )

        XCTAssertEqual(
            matrix.testingRowSelectorObjectIdentifier(genotype: first.genotype),
            rowProxy
        )
        XCTAssertEqual(
            matrix.testingColumnSelectorObjectIdentifier(sample: "AnimalB"),
            columnProxy
        )
        XCTAssertEqual(matrix.testingSelectAllSelectorObjectIdentifier, selectAllProxy)
        XCTAssertGreaterThan(
            matrix.testingAccessibilityValueChangedNotificationCount,
            valueChangedBaseline
        )

        let layoutBaseline = matrix.testingAccessibilityLayoutChangedNotificationCount
        controller.testingHideSelectedMatrixColumns()
        XCTAssertGreaterThan(
            matrix.testingAccessibilityLayoutChangedNotificationCount,
            layoutBaseline
        )
    }


    func testMatrixVisibilityPublishesImmutableCapabilitiesAndSupportsAllSetActions() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_B_SHARED"
        let firstCall = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondCall = makeCall(sample: "AnimalB", genotype: second, reads: 9)
        var snapshots: [GenotypeMatrixVisibilityCapabilitySnapshot] = []
        controller.onMatrixVisibilityCapabilityChanged = { snapshots.append($0) }
        controller.configure(result: makeResult(samples: [], calls: [firstCall, secondCall]))

        controller.testingClickMatrixRowChiclet(genotype: first)
        XCTAssertEqual(snapshots.last?.summary, "Selected: 1 allele row")
        XCTAssertEqual(snapshots.last?.selectedRowCount, 1)
        XCTAssertEqual(snapshots.last?.selectedColumnCount, 0)
        XCTAssertEqual(snapshots.last?.canHideSelectedRows, true)
        XCTAssertEqual(snapshots.last?.canShowAllRows, false)

        controller.testingShowOnlySelectedMatrixRows()
        XCTAssertEqual(controller.testingVisibleGenotypes, [first])
        XCTAssertEqual(snapshots.last?.canShowAllRows, true)

        controller.testingShowAllMatrixRows()
        XCTAssertEqual(Set(controller.testingVisibleGenotypes), [first, second])

        controller.testingClickMatrixRowChiclet(genotype: second)
        controller.testingHideSelectedMatrixRows()
        XCTAssertEqual(controller.testingVisibleGenotypes, [first])

        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingHideSelectedMatrixColumns()
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalB"])
        controller.testingShowAllMatrixColumns()
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])

        controller.testingResetMatrixVisibility()
        XCTAssertEqual(Set(controller.testingVisibleGenotypes), [first, second])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])
        XCTAssertEqual(snapshots.last?.canResetVisibility, false)
    }


    func testMatrixManualVisibilityComposesWithSearchInspectorThresholdAndSort() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let low = "01_Mafa_A1_LOW"
        let excluded = "02_Mafa_B_EXCLUDED"
        let high = "03_Mafa_A1_HIGH"
        let lowCall = makeCall(sample: "AnimalA", genotype: low, reads: 3)
        let excludedCall = makeCall(sample: "AnimalB", genotype: excluded, reads: 40)
        let highCall = makeCall(sample: "AnimalA", genotype: high, reads: 30)
        controller.configure(result: makeResult(samples: [], calls: [lowCall, excludedCall, highCall]))

        controller.testingClickMatrixRowChiclet(genotype: low)
        controller.testingClickMatrixRowChiclet(genotype: high, modifiers: [.command])
        controller.testingShowOnlySelectedMatrixRows()
        XCTAssertEqual(Set(controller.testingVisibleGenotypes), [low, high])

        controller.testingSetQuickFilterSearchText("AnimalA")
        var state = controller.testingDisplayState
        state.matrixRowFilterText = "A1"
        state.minimumReads = 10
        controller.testingApplyDisplayStateImmediately(state)
        let matrix = controller.testingComparisonMatrix
        matrix.testingSetSortDescriptor(key: "genotype", ascending: false)
        XCTAssertEqual(controller.testingVisibleGenotypes, [high])

        controller.testingSetQuickFilterSearchText("")
        state.matrixRowFilterText = ""
        state.minimumReads = 0
        controller.testingApplyDisplayStateImmediately(state)
        XCTAssertEqual(Set(controller.testingVisibleGenotypes), [low, high])
        XCTAssertFalse(controller.testingVisibleGenotypes.contains(excluded))
    }


    func testMatrixInspectorAlleleFilterDoesNotMatchSampleNamesOrMetadata() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_FILTER_SCOPE"
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 8)]
        ))

        var state = controller.testingDisplayState
        state.matrixRowFilterText = "AnimalA"
        controller.testingApplyDisplayStateImmediately(state)

        XCTAssertTrue(controller.testingVisibleMatrixGenotypes.isEmpty)

        state.matrixRowFilterText = "A1_FILTER"
        controller.testingApplyDisplayStateImmediately(state)

        XCTAssertEqual(controller.testingVisibleMatrixGenotypes, [genotype])
    }


    func testMatrixInspectorAlleleFilterMatchesDisplayedReferenceAlias() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let rawGenotype = "raw-reference-sequence-42"
        let alleleField = GenBankRecordDatabase.FieldDefinition(
            key: "feature.allele",
            displayTitle: "Allele",
            valueType: "text",
            sourceCategory: "feature",
            preferredOrder: 0
        )
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: rawGenotype, reads: 8)],
            referenceMetadata: ONTGenotypeReferenceMetadata(
                fields: [alleleField],
                recordsBySequenceName: [
                    rawGenotype: [alleleField.key: "Mafa-A1*007:01"],
                ],
                alleleFieldKey: alleleField.key
            )
        ))

        var state = controller.testingDisplayState
        state.matrixRowFilterText = "A1*007"
        controller.testingApplyDisplayStateImmediately(state)

        XCTAssertEqual(controller.testingVisibleMatrixGenotypes, [rawGenotype])
    }


    func testMatrixMinimumReadsIgnoresSupportFromManuallyHiddenSamples() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_HIDDEN_SUPPORT"
        let hiddenHigh = makeCall(sample: "AnimalA", genotype: genotype, reads: 100)
        let visibleLow = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        controller.configure(result: makeResult(
            samples: [],
            calls: [hiddenHigh, visibleLow]
        ))

        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingHideSelectedMatrixColumns()
        var state = controller.testingDisplayState
        state.minimumReads = 50
        controller.testingApplyDisplayStateImmediately(state)

        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalB"])
        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)
    }


    func testMatrixSortByHiddenSampleRetainsStableSemantics() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_LOW_IN_A"
        let second = "02_Mafa_A1_HIGH_IN_A"
        let calls = [
            makeCall(sample: "AnimalA", genotype: first, reads: 3),
            makeCall(sample: "AnimalB", genotype: first, reads: 20),
            makeCall(sample: "AnimalA", genotype: second, reads: 30),
            makeCall(sample: "AnimalB", genotype: second, reads: 2),
        ]
        controller.configure(result: makeResult(samples: [], calls: calls))
        let matrix = controller.testingComparisonMatrix
        let animalASortKey = try XCTUnwrap(matrix.testingSortKey(forSample: "AnimalA"))
        matrix.testingSetSortDescriptor(key: animalASortKey, ascending: true)
        XCTAssertEqual(controller.testingVisibleGenotypes, [first, second])

        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingHideSelectedMatrixColumns()

        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalB"])
        XCTAssertEqual(matrix.testingActiveSortDescriptorKey, animalASortKey)
        XCTAssertEqual(controller.testingVisibleGenotypes, [first, second])
    }


    func testMatrixVisibilityNoOpCommandsDoNotTriggerProjectionMutation() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 12)
        let second = makeCall(sample: "AnimalB", genotype: "02_Mafa_B", reads: 9)
        controller.configure(result: makeResult(samples: [], calls: [first, second]))
        let matrix = controller.testingComparisonMatrix
        let baseline = matrix.testingVisibilityMutationCount

        controller.testingShowOnlySelectedMatrixRows()
        controller.testingHideSelectedMatrixRows()
        controller.testingShowAllMatrixRows()
        controller.testingShowOnlySelectedMatrixColumns()
        controller.testingHideSelectedMatrixColumns()
        controller.testingShowAllMatrixColumns()
        controller.testingResetMatrixVisibility()
        XCTAssertEqual(matrix.testingVisibilityMutationCount, baseline)

        controller.testingClickMatrixRowChiclet(genotype: first.genotype)
        controller.testingHideSelectedMatrixRows()
        XCTAssertEqual(matrix.testingVisibilityMutationCount, baseline + 1)

        controller.testingHideSelectedMatrixRows()
        XCTAssertEqual(matrix.testingVisibilityMutationCount, baseline + 1)
        controller.testingShowAllMatrixRows()
        XCTAssertEqual(matrix.testingVisibilityMutationCount, baseline + 2)
        controller.testingShowAllMatrixRows()
        XCTAssertEqual(matrix.testingVisibilityMutationCount, baseline + 2)
    }


    func testMatrixVisibilityActionsStayOnTheLightweightProjectionPath() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 12),
            makeCall(sample: "AnimalB", genotype: "02_Mafa_B", reads: 9),
        ]
        controller.configure(result: makeResult(samples: [], calls: calls))
        let searchBuilds = controller.testingSearchIndexBuildCount
        let searchQueries = controller.testingSearchQueryCount

        controller.testingClickMatrixRowChiclet(genotype: calls[0].genotype)
        controller.testingResetProjectionPerformanceCounters()
        var baseBuilds = controller.testingProjectionPerformanceSnapshot
            .matrix.baseProjectionBuildCount
        controller.testingShowOnlySelectedMatrixRows()
        var performance = controller.testingProjectionPerformanceSnapshot
        XCTAssertEqual(performance.matrix.baseProjectionBuildCount, baseBuilds)
        XCTAssertEqual(performance.matrix.derivedProjectionPassCount, 0)
        XCTAssertEqual(performance.matrix.columnRebuildCount, 0)
        XCTAssertEqual(performance.anchorLensRebuildCount, 0)
        XCTAssertEqual(performance.consumerLensRebuildCount, 0)
        XCTAssertEqual(performance.cohortSummaryRebuildCount, 0)
        XCTAssertEqual(controller.testingSearchIndexBuildCount, searchBuilds)
        XCTAssertEqual(controller.testingSearchQueryCount, searchQueries)

        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingResetProjectionPerformanceCounters()
        baseBuilds = controller.testingProjectionPerformanceSnapshot
            .matrix.baseProjectionBuildCount
        controller.testingHideSelectedMatrixColumns()
        performance = controller.testingProjectionPerformanceSnapshot
        XCTAssertEqual(performance.matrix.baseProjectionBuildCount, baseBuilds)
        XCTAssertEqual(performance.matrix.derivedProjectionPassCount, 0)
        XCTAssertEqual(performance.matrix.columnRebuildCount, 1)
        XCTAssertEqual(controller.testingSearchIndexBuildCount, searchBuilds)
        XCTAssertEqual(controller.testingSearchQueryCount, searchQueries)

        controller.testingShowAllMatrixColumns()
        controller.testingShowAllMatrixRows()
        controller.testingResetProjectionPerformanceCounters()
        baseBuilds = controller.testingProjectionPerformanceSnapshot
            .matrix.baseProjectionBuildCount
        controller.testingShowAllMatrixColumns()
        controller.testingResetMatrixVisibility()
        controller.testingResetMatrixVisibility()
        performance = controller.testingProjectionPerformanceSnapshot
        XCTAssertEqual(performance.matrix.baseProjectionBuildCount, baseBuilds)
        XCTAssertEqual(performance.matrix.derivedProjectionPassCount, 0)
        XCTAssertEqual(performance.matrix.commitToVisibleCount, 0)
        XCTAssertEqual(performance.matrix.columnRebuildCount, 0)
        XCTAssertEqual(performance.matrix.pinnedFullReloadCount, 0)
        XCTAssertEqual(performance.matrix.sampleFullReloadCount, 0)
        XCTAssertEqual(controller.testingSearchIndexBuildCount, searchBuilds)
        XCTAssertEqual(controller.testingSearchQueryCount, searchQueries)
    }


    func testMatrixVisibilityIsPerControllerAndResetsForANewResult() {
        let callA = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 12)
        let callB = makeCall(sample: "AnimalB", genotype: "02_Mafa_B", reads: 9)
        let result = makeResult(samples: [], calls: [callA, callB])
        let first = GenotypeResultViewController()
        let second = GenotypeResultViewController()
        _ = first.view
        _ = second.view
        first.configure(result: result)
        second.configure(result: result)

        first.testingClickMatrixRowChiclet(genotype: callA.genotype)
        first.testingShowOnlySelectedMatrixRows()
        XCTAssertEqual(first.testingVisibleGenotypes, [callA.genotype])
        XCTAssertEqual(Set(second.testingVisibleGenotypes), [callA.genotype, callB.genotype])

        let replacement = makeCall(sample: "AnimalC", genotype: "03_Mafa_C", reads: 7)
        first.configure(result: makeResult(samples: [], calls: [replacement]))
        XCTAssertEqual(first.testingVisibleGenotypes, [replacement.genotype])
        XCTAssertEqual(first.testingMatrixVisibilityCapability.summary, "Scope: Entire matrix")
        XCTAssertFalse(first.testingMatrixVisibilityCapability.canResetVisibility)
    }


    func testWorkbookReplacementPreservesStableCandidateVisibilityAcrossRenamedLabel() {
        let cluster = "stable-cluster"
        let oldName = "Old_provisional_nov"
        let newName = "Renamed_provisional_nov"
        let oldResult = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(
                    id: cluster,
                    name: oldName,
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: cluster,
                    sample: "AnimalA",
                    reads: 7
                ),
            ]
        )
        let replacement = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(
                    id: cluster,
                    name: newName,
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: cluster,
                    sample: "AnimalA",
                    reads: 9
                ),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: oldResult)
        matrix.testingClickRowChiclet(genotype: oldName)
        matrix.showOnlySelectedRows()
        XCTAssertEqual(matrix.testingVisibleGenotypes, [oldName])

        matrix.replaceResultPreservingPresentation(
            replacement,
            metadataStore: nil,
            sidecar: nil
        )

        XCTAssertEqual(matrix.testingVisibleGenotypes, [newName])
        XCTAssertTrue(matrix.testingVisibilityCapability.canResetVisibility)

        let newBundle = makeResult(
            bundleURL: URL(fileURLWithPath: "/tmp/different.lungfishgenotype"),
            samples: [],
            calls: [
                makeCall(
                    sample: "AnimalB",
                    genotype: "01_Mafa_A1_NEW_BUNDLE",
                    reads: 5
                ),
            ]
        )
        matrix.configure(result: newBundle)
        XCTAssertFalse(matrix.testingVisibilityCapability.canResetVisibility)
        XCTAssertEqual(
            matrix.testingVisibleGenotypes,
            ["01_Mafa_A1_NEW_BUNDLE"]
        )
    }


    func testMatrixVisibilityPreservesColumnGeometrySortAndSemanticScroll() throws {
        let sampleIDs = ["AnimalA", "AnimalB", "AnimalC", "AnimalD", "AnimalE"]
        let calls = (0..<12).flatMap { row -> [ONTGenotypeCall] in
            sampleIDs.enumerated().map { sample, sampleID in
                makeCall(
                    sample: sampleID,
                    genotype: String(format: "%02d_Mafa_A1", row),
                    reads: row + sample + 1
                )
            }
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))
        let matrix = controller.testingComparisonMatrix
        matrix.frame = NSRect(x: 0, y: 0, width: 640, height: 260)
        matrix.layoutSubtreeIfNeeded()
        matrix.testingMoveSampleColumn(sample: "AnimalE", to: 0)
        matrix.testingSetSampleColumnWidth(sample: "AnimalB", width: 123)
        let sortKey = try XCTUnwrap(matrix.testingSortKey(forSample: "AnimalC"))
        matrix.testingSetSortDescriptor(key: sortKey, ascending: false)
        matrix.testingSetContentScrollOrigins(
            pinned: NSPoint(x: 0, y: matrix.testingMatrixRowHeight * 4 + 3),
            samples: NSPoint(x: 37, y: matrix.testingMatrixRowHeight * 4 + 3)
        )
        let anchor = matrix.testingSemanticScrollAnchor

        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingHideSelectedMatrixColumns()
        controller.testingShowAllMatrixColumns()

        XCTAssertEqual(
            controller.testingVisibleMatrixSampleColumnTitles,
            ["AnimalE", "AnimalA", "AnimalB", "AnimalC", "AnimalD"]
        )
        XCTAssertEqual(matrix.testingSampleColumnWidth(sample: "AnimalB"), 123, accuracy: 0.01)
        XCTAssertEqual(matrix.testingActiveSortDescriptorKey, sortKey)
        XCTAssertEqual(matrix.testingSemanticScrollAnchor.rowID, anchor.rowID)
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.withinRowOffset,
            anchor.withinRowOffset,
            accuracy: 0.01
        )
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.sampleHorizontalOrigin,
            anchor.sampleHorizontalOrigin,
            accuracy: 0.01
        )
    }


    func testHidingLeadingSampleAnchorsToNearestSuccessorThenPredecessor() {
        let samples = ["AnimalA", "AnimalB", "AnimalC", "AnimalD", "AnimalE"]
        let calls = samples.map {
            makeCall(sample: $0, genotype: "01_Mafa_A1", reads: 10)
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))
        let matrix = controller.testingComparisonMatrix
        matrix.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        matrix.layoutSubtreeIfNeeded()
        matrix.testingSetLeadingSampleScrollAnchor(sample: "AnimalC", offset: 7)
        XCTAssertEqual(matrix.testingSemanticScrollAnchor.leadingSampleID, "AnimalC")

        controller.testingSelectMatrixColumn(sample: "AnimalC")
        controller.testingHideSelectedMatrixColumns()

        XCTAssertEqual(matrix.testingSemanticScrollAnchor.leadingSampleID, "AnimalD")
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.withinSampleOffset,
            7,
            accuracy: 0.01
        )

        matrix.testingSetLeadingSampleScrollAnchor(sample: "AnimalE", offset: 5)
        controller.testingSelectMatrixColumn(sample: "AnimalE")
        controller.testingHideSelectedMatrixColumns()

        XCTAssertEqual(matrix.testingSemanticScrollAnchor.leadingSampleID, "AnimalD")
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.withinSampleOffset,
            5,
            accuracy: 0.01
        )
    }


    func testHorizontalSemanticAnchorSurvivesZeroVisibleRows() {
        let samples = ["AnimalA", "AnimalB", "AnimalC", "AnimalD"]
        let calls = samples.map {
            makeCall(sample: $0, genotype: "01_Mafa_A1", reads: 10)
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))
        let matrix = controller.testingComparisonMatrix
        matrix.frame = NSRect(x: 0, y: 0, width: 260, height: 220)
        matrix.layoutSubtreeIfNeeded()
        matrix.testingSetLeadingSampleScrollAnchor(sample: "AnimalC", offset: 6)
        controller.testingClickMatrixRowChiclet(genotype: "01_Mafa_A1")

        controller.testingHideSelectedMatrixRows()

        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)
        XCTAssertEqual(matrix.testingSemanticScrollAnchor.leadingSampleID, "AnimalC")
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.withinSampleOffset,
            6,
            accuracy: 0.01
        )
    }


    func testResetVisibilityRecoversFromEmptySampleColumns() {
        let samples = ["AnimalA", "AnimalB", "AnimalC"]
        let calls = samples.map {
            makeCall(sample: $0, genotype: "01_Mafa_A1", reads: 10)
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))

        controller.testingSelectMatrixColumns(samples: samples)
        controller.testingHideSelectedMatrixColumns()
        XCTAssertTrue(controller.testingVisibleMatrixSamples.isEmpty)

        controller.testingResetMatrixVisibility()

        XCTAssertEqual(controller.testingVisibleMatrixSamples, samples)
        XCTAssertEqual(
            controller.testingComparisonMatrix
                .testingSemanticScrollAnchor.sampleHorizontalOrigin,
            0,
            accuracy: 0.01
        )
    }


    func testHidingFocusedSelectionPrunesItAndMovesFocusToNearestRowSelector() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 12)
        let second = makeCall(sample: "AnimalA", genotype: "02_Mafa_A1", reads: 9)
        controller.configure(result: makeResult(samples: [], calls: [first, second]))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        controller.testingClickMatrixRowChiclet(genotype: first.genotype)
        XCTAssertTrue(controller.testingFocusMatrixRowSelector(genotype: first.genotype))
        let focusNotificationBaseline = controller.testingComparisonMatrix
            .testingAccessibilityFocusChangedNotificationCount

        controller.testingHideSelectedMatrixRows()

        XCTAssertTrue(controller.testingCurrentSelectionMatrixTargets.isEmpty)
        XCTAssertEqual(controller.testingFocusedMatrixRowSelectorGenotype, second.genotype)
        XCTAssertEqual(controller.testingMatrixVisibilityCapability.summary, "Scope: Entire matrix")
        XCTAssertGreaterThan(
            controller.testingComparisonMatrix
                .testingAccessibilityFocusChangedNotificationCount,
            focusNotificationBaseline
        )
    }


    func testHidingAccessibilityFocusedRowRecoversNearestWithoutStealingKeyboardFocus() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 12)
        let second = makeCall(sample: "AnimalA", genotype: "02_Mafa_A1", reads: 9)
        controller.configure(result: makeResult(samples: [], calls: [first, second]))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        let keyboardSentinel = NSTextField(string: "Keyboard focus stays here")
        host.addSubview(controller.view)
        host.addSubview(keyboardSentinel)
        window.contentView = host
        XCTAssertTrue(window.makeFirstResponder(keyboardSentinel))
        let keyboardResponder = window.firstResponder

        controller.testingClickMatrixRowChiclet(genotype: first.genotype)
        XCTAssertTrue(
            controller.testingComparisonMatrix
                .testingSetAccessibilityFocusedRowSelector(genotype: first.genotype)
        )
        XCTAssertEqual(
            controller.testingComparisonMatrix
                .testingAccessibilityFocusedRowSelectorGenotype,
            first.genotype
        )

        controller.testingHideSelectedMatrixRows()

        XCTAssertEqual(
            controller.testingComparisonMatrix
                .testingAccessibilityFocusedRowSelectorGenotype,
            second.genotype
        )
        XCTAssertTrue(window.firstResponder === keyboardResponder)
    }


    func testVisibilityActionDoesNotStealUnrelatedKeyboardOrAccessibilityFocus() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 12)
        let second = makeCall(sample: "AnimalA", genotype: "02_Mafa_A1", reads: 9)
        controller.configure(result: makeResult(samples: [], calls: [first, second]))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        let sentinel = NSTextField(string: "Keep focus")
        host.addSubview(controller.view)
        host.addSubview(sentinel)
        window.contentView = host
        XCTAssertTrue(window.makeFirstResponder(sentinel))
        let responder = window.firstResponder

        controller.testingClickMatrixRowChiclet(genotype: first.genotype)
        controller.testingHideSelectedMatrixRows()

        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertNil(
            controller.testingComparisonMatrix
                .testingAccessibilityFocusedRowSelectorGenotype
        )
    }


    func testHidingOnlyAccessibilityFocusedRowMovesAXFocusToMatrixWithoutKeyboardTheft() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let only = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 12)
        controller.configure(result: makeResult(samples: [], calls: [only]))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        let sentinel = NSTextField(string: "Keep keyboard focus")
        host.addSubview(controller.view)
        host.addSubview(sentinel)
        window.contentView = host
        XCTAssertTrue(window.makeFirstResponder(sentinel))
        let responder = window.firstResponder
        controller.testingClickMatrixRowChiclet(genotype: only.genotype)
        XCTAssertTrue(
            controller.testingComparisonMatrix
                .testingSetAccessibilityFocusedRowSelector(genotype: only.genotype)
        )

        controller.testingHideSelectedMatrixRows()

        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)
        XCTAssertTrue(
            controller.testingComparisonMatrix
                .testingAccessibilityFocusFallsBackToMatrix
        )
        XCTAssertTrue(window.firstResponder === responder)
    }


    func testMatrixVisibilityActionsDoNotMutateBundleArtifactsOrAudit() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeVisibilityNoMutation")
        defer { TestTempDirectory.cleanup(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let call = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 12)
        _ = try GenotypeAnnotationStore(bundleURL: root, author: "seed")
        let annotationsURL = root.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: annotationsURL)
        )
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "A1",
            genotype: call.genotype,
            sample: call.sample
        )
        sidecar.matrixComments.append(.init(
            target: target,
            body: "Existing analyst comment",
            author: "analyst",
            timestamp: "2026-07-26T00:00:00Z"
        ))
        sidecar.matrixReviews.append(.init(
            target: target,
            disposition: .falsePositive,
            author: "analyst",
            timestamp: "2026-07-26T00:00:00Z"
        ))
        sidecar.auditLog.append(.init(
            action: "setMatrixReview",
            sample: call.sample,
            locus: "A1",
            slot: nil,
            before: nil,
            after: "falsePositive",
            color: nil,
            reason: "matrix-review",
            rationale: target.stableAuditDescription,
            author: "analyst",
            timestamp: "2026-07-26T00:00:00Z"
        ))
        try sidecar.encoded().write(to: annotationsURL)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("provenance", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("provenance-sentinel".utf8).write(
            to: root.appendingPathComponent("provenance/workflow.json")
        )
        try Data("xlsx-sentinel".utf8).write(
            to: root.appendingPathComponent("current.xlsx")
        )
        try Data("nested-artifact".utf8).write(
            to: root.appendingPathComponent("artifact.bin")
        )

        func recursiveBytes() throws -> [String: Data] {
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey]
                )
            )
            var bytes: [String: Data] = [:]
            for case let url as URL in enumerator {
                guard try url.resourceValues(forKeys: [.isRegularFileKey])
                    .isRegularFile == true else {
                    continue
                }
                let relative = url.path.replacingOccurrences(
                    of: root.path + "/",
                    with: ""
                )
                bytes[relative] = try Data(contentsOf: url)
            }
            return bytes
        }

        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [call]))
        let before = try recursiveBytes()
        controller.testingResetProjectionPerformanceCounters()

        controller.testingClickMatrixRowChiclet(genotype: call.genotype)
        controller.testingShowOnlySelectedMatrixRows()
        controller.testingSelectMatrixColumn(sample: call.sample)
        controller.testingShowOnlySelectedMatrixColumns()
        controller.testingSetQuickFilterSearchText("AnimalA")
        var state = controller.testingDisplayState
        state.minimumReads = 5
        controller.testingApplyDisplayStateImmediately(state)
        controller.testingResetMatrixVisibility()

        XCTAssertEqual(try recursiveBytes(), before)
        XCTAssertFalse(controller.testingCurrentWorkbookNeedsRefresh)
        XCTAssertFalse(controller.testingCurrentWorkbookRequiresFullUpdate)
        XCTAssertGreaterThan(
            controller.testingComparisonMatrix.testingVisibilityMutationCount,
            0
        )
    }

}

/// Polls a debounce-dependent condition instead of sleeping a fixed wall-clock
/// interval, so this stays reliable under full-suite serial/parallel load
/// where the run loop may be delayed in delivering the debounce timer.
@MainActor
private func waitUntilQuickSearchSettles(
    _ controller: GenotypeResultViewController,
    timeout: TimeInterval = 10.0,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), file: file, line: line)
}
