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

// Matrix false-positive/negative rendering, context menus, visibility and review capability
@MainActor
final class GenotypeResultViewportMatrixReviewTests: GenotypeResultViewportTestCase {
    func testMatrixFalsePositiveRendersBracketedReadCountWithoutChangingEvidence() {
        let genotype = "01_Mafa_A1_FALSE_POSITIVE"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: target,
                disposition: .falsePositive,
                author: "test",
                timestamp: "2026-07-24T00:00:01Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(
            result: makeResult(samples: [], calls: [call]),
            sidecar: sidecar
        )

        XCTAssertEqual(matrix.testingCellValue(genotype: genotype, sample: "AnimalA"), "[42]")
        XCTAssertEqual(matrix.testingVisibleRows.first?.support(for: "AnimalA")?.passedUniqueReads, 42)
    }


    func testStableCandidateRowDoesNotInheritLegacyStableIDLessReview() {
        let genotype = "Collision_nov"
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(
                    id: "cluster-a",
                    name: genotype,
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 7),
            ]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A1",
                    genotype: genotype,
                    sample: "AnimalA",
                    stableClusterID: nil
                ),
                disposition: .falsePositive,
                author: "legacy",
                timestamp: "2026-07-24T00:00:01Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()

        matrix.configure(result: result, sidecar: sidecar)

        XCTAssertEqual(matrix.testingCellValue(genotype: genotype, sample: "AnimalA"), "7")
    }


    func testMatrixFalseNegativeKeepsExplicitZeroAndUsesEmDashOnlyForAbsentSupport() {
        let genotype = "01_Mafa_A1_FALSE_NEGATIVE"
        let zero = makeCall(sample: "AnimalA", genotype: genotype, reads: 0)
        let explicitZero = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let absent = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalB"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: explicitZero,
                disposition: .falseNegative,
                author: "test",
                timestamp: "2026-07-24T00:00:01Z"
            ),
            .init(
                target: absent,
                disposition: .falseNegative,
                author: "test",
                timestamp: "2026-07-24T00:00:02Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(
            result: makeResult(
                samples: [
                    ONTGenotypeSampleResult(
                        sample: "AnimalA",
                        passedAlignments: 0,
                        passedUniqueReads: 0,
                        sampleTotalReads: nil,
                        sampleUniqueRetainedPercent: nil,
                        calls: [zero]
                    ),
                    ONTGenotypeSampleResult(
                        sample: "AnimalB",
                        passedAlignments: 0,
                        passedUniqueReads: 0,
                        sampleTotalReads: nil,
                        sampleUniqueRetainedPercent: nil,
                        calls: []
                    ),
                ],
                calls: [zero]
            ),
            sidecar: sidecar
        )

        XCTAssertEqual(matrix.testingCellValue(genotype: genotype, sample: "AnimalA"), "0")
        XCTAssertEqual(matrix.testingCellValue(genotype: genotype, sample: "AnimalB"), "—")
    }


    func testMatrixReviewChromeKeepsSemanticDecorativeSelectionAndCommentLayersIndependent() throws {
        let genotype = "01_Mafa_A1_LAYERED"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 0)
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: target,
                style: .init(borderColor: "#336699"),
                author: "test",
                timestamp: "2026-07-24T00:00:01Z"
            ),
        ]
        sidecar.matrixReviews = [
            .init(
                target: target,
                disposition: .falseNegative,
                author: "test",
                timestamp: "2026-07-24T00:00:02Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: target,
                body: "Cell-level concern.",
                author: "test",
                timestamp: "2026-07-24T00:00:03Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(samples: [], calls: [call]), sidecar: sidecar)
        matrix.testingSelectCell(genotype: genotype, sample: "AnimalA")

        let support = try XCTUnwrap(matrix.testingSemanticCellState(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(support.review, .falseNegative)
        XCTAssertEqual(support.text.value, "0")
        XCTAssertEqual(support.text.colorRole, .primary)
        XCTAssertFalse(support.text.isItalic)
        XCTAssertNotNil(support.chrome.semanticInnerFrameWidth)
        XCTAssertNotNil(support.chrome.decorativeBorderWidth)
        XCTAssertNotNil(support.chrome.selectionCornerBracketWidth)
        XCTAssertNotNil(support.chrome.commentFoldSize)
        XCTAssertTrue(support.hasNativeCellCommentMarker)

        var state = GenotypeResultDisplayState(cellColorMode: .highlights)
        matrix.applyDisplayState(state)
        let highlights = try XCTUnwrap(matrix.testingSemanticCellState(genotype: genotype, sample: "AnimalA"))
        XCTAssertNotNil(highlights.chrome.semanticInnerFrameWidth)
        XCTAssertNotNil(highlights.chrome.decorativeBorderWidth)
        XCTAssertNotNil(highlights.chrome.selectionCornerBracketWidth)
        XCTAssertTrue(highlights.hasNativeCellCommentMarker)

        state.cellColorMode = .none
        matrix.applyDisplayState(state)
        let none = try XCTUnwrap(matrix.testingSemanticCellState(genotype: genotype, sample: "AnimalA"))
        XCTAssertNotNil(none.chrome.semanticInnerFrameWidth)
        XCTAssertNil(none.chrome.decorativeBorderWidth)
        XCTAssertNotNil(none.chrome.selectionCornerBracketWidth)
        XCTAssertTrue(none.hasNativeCellCommentMarker)
    }


    func testMatrixFalsePositiveUsesDynamicSecondaryItalicTextWithoutWholeCellAlpha() throws {
        let genotype = "01_Mafa_A1_FALSE_POSITIVE_PRESENTATION"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: target,
                disposition: .falsePositive,
                author: "test",
                timestamp: "2026-07-24T00:00:01Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: target,
                body: "Retain the count.",
                author: "test",
                timestamp: "2026-07-24T00:00:02Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(samples: [], calls: [call]), sidecar: sidecar)

        let semantic = try XCTUnwrap(matrix.testingSemanticCellState(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(semantic.text.value, "[42]")
        XCTAssertEqual(semantic.text.colorRole, .secondary)
        XCTAssertTrue(semantic.text.isItalic)
        XCTAssertEqual(matrix.testingRenderedCellAlpha(genotype: genotype, sample: "AnimalA"), 1)
        XCTAssertTrue(semantic.hasNativeCellCommentMarker)

        let light = try XCTUnwrap(matrix.testingResolvedSemanticTextColor(
            genotype: genotype,
            sample: "AnimalA",
            appearance: .aqua
        ))
        let dark = try XCTUnwrap(matrix.testingResolvedSemanticTextColor(
            genotype: genotype,
            sample: "AnimalA",
            appearance: .darkAqua
        ))
        XCTAssertNotEqual(light, dark)
    }


    func testMatrixCommentMarkersStayAtNativeScopesAndTooltipOrderIsStable() throws {
        let genotype = "01_Mafa_A1_COMMENT_SCOPES"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 12)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixComments = [
            .init(
                target: .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
                body: "Cell note.",
                author: "test",
                timestamp: "2026-07-24T00:00:03Z"
            ),
            .init(
                target: .column(sample: "AnimalA"),
                body: "Column note.",
                author: "test",
                timestamp: "2026-07-24T00:00:02Z"
            ),
            .init(
                target: .row(locus: "MHC-A", genotype: genotype),
                body: "Row note.",
                author: "test",
                timestamp: "2026-07-24T00:00:01Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(samples: [], calls: [call]), sidecar: sidecar)

        XCTAssertTrue(matrix.testingHasRowCommentMarker(genotype: genotype))
        XCTAssertTrue(matrix.testingHasColumnCommentMarker(sample: "AnimalA"))
        XCTAssertTrue(matrix.testingHasCellCommentMarker(genotype: genotype, sample: "AnimalA"))
        let semantic = try XCTUnwrap(matrix.testingSemanticCellState(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(semantic.commentCounts, .init(alleleRow: 1, sampleColumn: 1, cell: 1))
        XCTAssertTrue(semantic.hasNativeCellCommentMarker)
        XCTAssertEqual(
            matrix.testingCellToolTip(genotype: genotype, sample: "AnimalA"),
            """
            AnimalA: 12 unique reads
            Allele Row: Row note.
            Sample Column: Column note.
            Cell: Cell note.
            """
        )
    }


    func testMatrixSemanticGeometryIncreasesWithAccessibilityContrast() throws {
        let genotype = "01_Mafa_A1_CONTRAST"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 0)
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: target,
                disposition: .falseNegative,
                author: "test",
                timestamp: "2026-07-24T00:00:01Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: target,
                body: "Contrast marker.",
                author: "test",
                timestamp: "2026-07-24T00:00:02Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(samples: [], calls: [call]), sidecar: sidecar)
        matrix.testingSelectCell(genotype: genotype, sample: "AnimalA")
        matrix.testingSetIncreaseContrastOverride(false)
        let standard = try XCTUnwrap(matrix.testingSemanticCellState(genotype: genotype, sample: "AnimalA"))

        matrix.testingSetIncreaseContrastOverride(true)
        let increased = try XCTUnwrap(matrix.testingSemanticCellState(genotype: genotype, sample: "AnimalA"))

        XCTAssertGreaterThan(
            try XCTUnwrap(increased.chrome.semanticInnerFrameWidth),
            try XCTUnwrap(standard.chrome.semanticInnerFrameWidth)
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(increased.chrome.selectionCornerBracketWidth),
            try XCTUnwrap(standard.chrome.selectionCornerBracketWidth)
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(increased.chrome.commentFoldSize),
            try XCTUnwrap(standard.chrome.commentFoldSize)
        )
    }


    func testMatrixFilteredHighlightHidingDoesNotHideReviewSelectionOrCommentSemantics() throws {
        let genotype = "01_Mafa_A1_FILTERED_SEMANTICS"
        let other = "02_Mafa_A1_HIGH_SUPPORT"
        let selected = makeCall(sample: "AnimalA", genotype: genotype, reads: 100)
        let filtered = makeCall(sample: "AnimalB", genotype: genotype, reads: 1)
        let denominator = makeCall(sample: "AnimalB", genotype: other, reads: 99)
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalB"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: target,
                style: .init(borderColor: "#336699"),
                author: "test",
                timestamp: "2026-07-24T00:00:01Z"
            ),
        ]
        sidecar.matrixReviews = [
            .init(
                target: target,
                disposition: .falseNegative,
                author: "test",
                timestamp: "2026-07-24T00:00:02Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: target,
                body: "Review remains visible.",
                author: "test",
                timestamp: "2026-07-24T00:00:03Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(
            result: makeResult(samples: [], calls: [selected, filtered, denominator]),
            sidecar: sidecar
        )
        matrix.testingSelectCell(genotype: genotype, sample: "AnimalB")
        matrix.applyDisplayState(GenotypeResultDisplayState(
            hideLowSupport: true,
            minimumSupportPercent: 50,
            supportDenominator: .viewedLocus,
            cellColorMode: .highlights,
            hideFilteredHighlights: true
        ))

        let semantic = try XCTUnwrap(matrix.testingSemanticCellState(
            genotype: genotype,
            sample: "AnimalB"
        ))
        XCTAssertEqual(semantic.review, .falseNegative)
        XCTAssertNil(semantic.chrome.decorativeBorderWidth)
        XCTAssertNotNil(semantic.chrome.semanticInnerFrameWidth)
        XCTAssertNotNil(semantic.chrome.selectionCornerBracketWidth)
        XCTAssertNotNil(semantic.chrome.commentFoldSize)
    }


    func testMatrixContextMenuPreservesInsideSelectionAndSelectsOutsideWithoutRebuildingIndexes() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixContextSelection")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_FIRST"
        let second = "02_Mafa_A1_SECOND"
        let firstCall = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondCall = makeCall(sample: "AnimalA", genotype: second, reads: 8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 20,
                    passedUniqueReads: 20,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [firstCall, secondCall]
                ),
                ONTGenotypeSampleResult(
                    sample: "AnimalB",
                    passedAlignments: 0,
                    passedUniqueReads: 0,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: []
                ),
            ],
            calls: [firstCall, secondCall]
        ))
        controller.testingSelectMatrixRows(genotypes: [first, second], sample: "AnimalA")
        let selected = controller.testingCurrentSelectionMatrixTargets
        let evidenceBuildCount = controller.testingMatrixEvidenceIndexBuildCount
        let annotationBuildCount = controller.testingMatrixAnnotationIndexBuildCount

        let inside = try XCTUnwrap(controller.testingBuildMatrixContextMenu(
            for: .cell(locus: "MHC-A", genotype: first, sample: "AnimalA")
        ))

        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, selected)
        XCTAssertEqual(inside.selectionTargets, selected)
        XCTAssertEqual(controller.testingMatrixEvidenceIndexBuildCount, evidenceBuildCount)
        XCTAssertEqual(controller.testingMatrixAnnotationIndexBuildCount, annotationBuildCount)

        let outside = try XCTUnwrap(controller.testingBuildMatrixContextMenu(
            for: .cell(locus: "MHC-A", genotype: first, sample: "AnimalB")
        ))

        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalB"),
        ])
        XCTAssertEqual(outside.selectionTargets, controller.testingCurrentSelectionMatrixTargets)
        XCTAssertEqual(controller.testingMatrixReviewCapability.falseNegative, .enabled)
        XCTAssertEqual(controller.testingMatrixEvidenceIndexBuildCount, evidenceBuildCount)
        XCTAssertEqual(controller.testingMatrixAnnotationIndexBuildCount, annotationBuildCount)
    }


    func testMatrixActualContextMenuKeepsCachedDisabledStateAfterAppKitUpdate() throws {
        let genotype = "01_Mafa_A1_ACTUAL_MENU"
        let supported = makeCall(sample: "AnimalB", genotype: genotype, reads: 9)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 0,
                    passedUniqueReads: 0,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: []
                ),
                ONTGenotypeSampleResult(
                    sample: "AnimalB",
                    passedAlignments: 9,
                    passedUniqueReads: 9,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [supported]
                ),
            ],
            calls: [supported]
        ))
        var snapshotSourceSpy: MatrixContextMenuSnapshotSourceSpy?
        controller.testingSetMatrixContextMenuSnapshotSourceFactory { snapshot in
            let spy = MatrixContextMenuSnapshotSourceSpy(snapshot: snapshot)
            snapshotSourceSpy = spy
            return spy
        }
        defer { controller.testingSetMatrixContextMenuSnapshotSourceFactory(nil) }

        let menu = try XCTUnwrap(controller.testingBuildActualMatrixContextMenu(
            for: .cell(
                locus: "MHC-A",
                genotype: genotype,
                sample: "AnimalA"
            )
        ))
        let falsePositive = try XCTUnwrap(menu.items.first {
            $0.title == "Mark False Positive"
        })

        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertFalse(falsePositive.isEnabled)
        menu.update()
        XCTAssertFalse(falsePositive.isEnabled)
        XCTAssertEqual(snapshotSourceSpy?.snapshotReadCount, 1)
    }


    func testMatrixVisibilityContextBuilderUsesTopLevelCommandsForPureDimensions() {
        let rowTargets: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .row(locus: "MHC-A", genotype: "A1"),
            .row(locus: "MHC-B", genotype: "B1"),
        ]
        let rowCapability = GenotypeMatrixVisibilityCapabilitySnapshot(
            selection: .init(targets: rowTargets),
            visibility: .init()
        )
        let reviewCapability = GenotypeMatrixReviewCapability.evaluate(
            selection: rowTargets,
            evidence: .init(),
            reviews: [],
            comments: [],
            isWritable: false
        )

        let rows = GenotypeMatrixContextMenuBuilder.make(snapshot: .init(
            selectionTargets: rowTargets,
            capability: reviewCapability,
            visibilityCapability: rowCapability,
            keyModifierRawValue: 0
        ))

        XCTAssertEqual(
            rows.visibilityItems.map(\.title),
            ["Hide 2 Selected Rows", "Show Only 2 Selected Rows"]
        )
        XCTAssertEqual(
            rows.visibilityItems.map(\.command),
            [.hideSelectedRows, .showOnlySelectedRows]
        )
        XCTAssertTrue(rows.visibilitySubmenus.isEmpty)
        XCTAssertEqual(rows.items.first?.command, .markFalsePositive)

        let columnTargets: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .column(sample: "AnimalA"),
        ]
        let columns = GenotypeMatrixContextMenuBuilder.make(snapshot: .init(
            selectionTargets: columnTargets,
            capability: GenotypeMatrixReviewCapability.evaluate(
                selection: columnTargets,
                evidence: .init(),
                reviews: [],
                comments: [],
                isWritable: false
            ),
            visibilityCapability: .init(
                selection: .init(targets: columnTargets),
                visibility: .init()
            ),
            keyModifierRawValue: 0
        ))

        XCTAssertEqual(
            columns.visibilityItems.map(\.title),
            ["Hide 1 Selected Column", "Show Only 1 Selected Column"]
        )
        XCTAssertEqual(
            columns.visibilityItems.map(\.command),
            [.hideSelectedColumns, .showOnlySelectedColumns]
        )
        XCTAssertTrue(columns.visibilitySubmenus.isEmpty)
    }


    func testMatrixVisibilityContextBuilderDeduplicatesCellDimensionsIntoSubmenus() {
        let targets: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .cell(locus: "MHC-A", genotype: "A1", sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: "A1", sample: "AnimalB"),
            .cell(locus: "MHC-B", genotype: "B1", sample: "AnimalA"),
            .cell(locus: "MHC-B", genotype: "B1", sample: "AnimalB"),
        ]
        let capability = GenotypeMatrixVisibilityCapabilitySnapshot(
            selection: .init(targets: targets),
            visibility: GenotypeMatrixVisibilityState()
                .hidingSamples(["AnimalC"])
        )
        let state = GenotypeMatrixContextMenuBuilder.make(snapshot: .init(
            selectionTargets: targets,
            capability: GenotypeMatrixReviewCapability.evaluate(
                selection: targets,
                evidence: .init(),
                reviews: [],
                comments: [],
                isWritable: false
            ),
            visibilityCapability: capability,
            keyModifierRawValue: 0
        ))

        XCTAssertEqual(state.visibilitySubmenus.map(\.title), [
            "Row Visibility",
            "Column Visibility",
        ])
        XCTAssertEqual(state.visibilitySubmenus[0].items.map(\.title), [
            "Hide 2 Selected Rows",
            "Show Only 2 Selected Rows",
        ])
        XCTAssertEqual(state.visibilitySubmenus[1].items.map(\.title), [
            "Hide 2 Selected Columns",
            "Show Only 2 Selected Columns",
        ])
        XCTAssertEqual(
            state.visibilityItems.map(\.command),
            [.resetVisibility]
        )
        XCTAssertEqual(
            state.visibilityItems.map(\.title),
            ["Show All Rows and Columns"]
        )
        XCTAssertEqual(state.inspectedTargetCount, 4)
    }


    func testSingleRowContextFilterReportsWhetherAnyColumnsHaveCalls() throws {
        let target = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A",
            genotype: "A1"
        )
        func item(callSampleCount: Int) throws -> GenotypeMatrixContextMenuItemState {
            let state = GenotypeMatrixContextMenuBuilder.make(snapshot: .init(
                selectionTargets: [target],
                capability: GenotypeMatrixReviewCapability.evaluate(
                    selection: [target],
                    evidence: .init(),
                    reviews: [],
                    comments: [],
                    isWritable: false
                ),
                visibilityCapability: .init(
                    selection: .init(targets: [target]),
                    visibility: .init()
                ),
                keyModifierRawValue: 0,
                selectedRowCallSampleCount: callSampleCount
            ))
            return try XCTUnwrap(state.visibilityItems.first {
                $0.command == .showOnlyColumnsWithSelectedRowCalls
            })
        }

        XCTAssertEqual(try item(callSampleCount: 2).availability, .enabled)
        XCTAssertEqual(
            try item(callSampleCount: 0).availability.disabledReason,
            "This row has no genotype calls with read support."
        )
    }


    func testMatrixVisibilityContextBuilderCoversSparseMixedAndEmptySelections() {
        func state(
            _ targets: [GenotypeAnnotationSidecar.MatrixTarget]
        ) -> GenotypeMatrixContextMenuState {
            GenotypeMatrixContextMenuBuilder.make(snapshot: .init(
                selectionTargets: targets,
                capability: GenotypeMatrixReviewCapability.evaluate(
                    selection: targets,
                    evidence: .init(),
                    reviews: [],
                    comments: [],
                    isWritable: false
                ),
                visibilityCapability: .init(
                    selection: .init(targets: targets),
                    visibility: .init()
                ),
                keyModifierRawValue: 0
            ))
        }

        let sparse = state([
            .cell(locus: "MHC-A", genotype: "A1", sample: "AnimalA"),
            .cell(locus: "MHC-B", genotype: "B1", sample: "AnimalB"),
        ])
        XCTAssertEqual(sparse.visibilitySubmenus.map(\.title), [
            "Row Visibility",
            "Column Visibility",
        ])
        XCTAssertEqual(
            sparse.visibilitySubmenus[0].items.first?.title,
            "Hide 2 Selected Rows"
        )
        XCTAssertEqual(
            sparse.visibilitySubmenus[1].items.first?.title,
            "Hide 2 Selected Columns"
        )

        let mixed = state([
            .row(locus: "MHC-A", genotype: "A1"),
            .column(sample: "AnimalA"),
        ])
        XCTAssertEqual(mixed.visibilitySubmenus.map(\.title), [
            "Row Visibility",
            "Column Visibility",
        ])
        XCTAssertEqual(
            mixed.visibilitySubmenus.flatMap(\.items).map(\.title),
            [
                "Hide 1 Selected Row",
                "Show Only 1 Selected Row",
                "Hide 1 Selected Column",
                "Show Only 1 Selected Column",
            ]
        )

        let empty = state([])
        XCTAssertTrue(empty.visibilityItems.isEmpty)
        XCTAssertTrue(empty.visibilitySubmenus.isEmpty)
        XCTAssertEqual(empty.items.first?.command, .markFalsePositive)

        let emptyWithManualVisibility = GenotypeMatrixContextMenuBuilder.make(snapshot: .init(
            selectionTargets: [],
            capability: GenotypeMatrixReviewCapability.evaluate(
                selection: [],
                evidence: .init(),
                reviews: [],
                comments: [],
                isWritable: false
            ),
            visibilityCapability: .init(
                selection: .init(targets: []),
                visibility: GenotypeMatrixVisibilityState()
                    .hidingSamples(["AnimalA"])
            ),
            keyModifierRawValue: 0
        ))
        XCTAssertEqual(
            emptyWithManualVisibility.visibilityItems.map(\.command),
            [.resetVisibility]
        )
        XCTAssertEqual(
            emptyWithManualVisibility.visibilityItems.map(\.title),
            ["Show All Rows and Columns"]
        )
        XCTAssertTrue(emptyWithManualVisibility.visibilitySubmenus.isEmpty)
    }


    func testMatrixContextMenusRejectTargetsHiddenByManualVisibility() {
        let first = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 8)
        let second = makeCall(sample: "AnimalB", genotype: "02_Mafa_B", reads: 7)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [first, second]))

        controller.testingSelectMatrixRows(genotypes: [first.genotype], sample: nil)
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.hideSelectedRows))
        XCTAssertNil(controller.testingBuildMatrixContextMenu(for: .row(
            locus: "MHC-A",
            genotype: first.genotype
        )))

        controller.testingSelectMatrixColumns(samples: ["AnimalB"])
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.hideSelectedColumns))
        XCTAssertNil(controller.testingBuildMatrixContextMenu(for: .column(
            sample: "AnimalB"
        )))
    }


    func testMatrixVisibilityActualContextMenuPreservesReviewGroupAndStableIdentifiers() throws {
        let first = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 8)
        let second = makeCall(sample: "AnimalA", genotype: "02_Mafa_B", reads: 6)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [first, second]))

        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: first.genotype,
            sample: "AnimalA"
        )
        let menu = try XCTUnwrap(controller.testingBuildActualMatrixContextMenu(for: target))

        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.first?.title, "Mark False Positive")
        let rowItem = try XCTUnwrap(menu.items.first {
            $0.identifier?.rawValue == "genotype-matrix-visibility-rows"
        })
        let columnItem = try XCTUnwrap(menu.items.first {
            $0.identifier?.rawValue == "genotype-matrix-visibility-columns"
        })
        XCTAssertFalse(try XCTUnwrap(rowItem.submenu).autoenablesItems)
        XCTAssertFalse(try XCTUnwrap(columnItem.submenu).autoenablesItems)
        XCTAssertEqual(rowItem.submenu?.items.map(\.identifier?.rawValue), [
            "genotype-matrix-visibility-hide-rows",
            "genotype-matrix-visibility-show-only-rows",
        ])
        XCTAssertEqual(columnItem.submenu?.items.map(\.identifier?.rawValue), [
            "genotype-matrix-visibility-hide-columns",
            "genotype-matrix-visibility-show-only-columns",
        ])
        XCTAssertGreaterThan(
            try XCTUnwrap(menu.items.firstIndex(of: rowItem)),
            try XCTUnwrap(menu.items.firstIndex { $0.title == "Remove Comment" })
        )

        controller.testingSelectMatrixColumn(sample: "AnimalA")
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.hideSelectedColumns))
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.showAllColumns))
        controller.testingSelectMatrixRows(genotypes: [second.genotype], sample: nil)
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.hideSelectedRows))
        let activeMenu = try XCTUnwrap(
            controller.testingBuildActualMatrixContextMenu(for: target)
        )
        let rowIndex = try XCTUnwrap(activeMenu.items.firstIndex {
            $0.identifier?.rawValue == "genotype-matrix-visibility-rows"
        })
        let columnIndex = try XCTUnwrap(activeMenu.items.firstIndex {
            $0.identifier?.rawValue == "genotype-matrix-visibility-columns"
        })
        let showAllIndex = try XCTUnwrap(activeMenu.items.firstIndex {
            $0.identifier?.rawValue == "genotype-matrix-visibility-show-all"
        })
        XCTAssertLessThan(rowIndex, columnIndex)
        XCTAssertLessThan(columnIndex, showAllIndex)
    }


    func testMatrixVisibilityContextCommandRevalidatesCurrentCapability() throws {
        let call = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 8)
        let second = makeCall(sample: "AnimalA", genotype: "02_Mafa_B", reads: 7)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [call, second]))
        let rowTarget = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A",
            genotype: call.genotype
        )
        let menu = try XCTUnwrap(controller.testingBuildActualMatrixContextMenu(
            for: rowTarget
        ))
        XCTAssertNotNil(menu.items.first {
            $0.identifier?.rawValue == "genotype-matrix-visibility-hide-rows"
        })

        controller.testingSelectMatrixRows(genotypes: [second.genotype], sample: nil)
        let capturedHideRow = try XCTUnwrap(menu.items.first {
            $0.identifier?.rawValue == "genotype-matrix-visibility-hide-rows"
        })

        XCTAssertFalse(controller.testingActivateMatrixContextMenuItem(capturedHideRow))
        XCTAssertEqual(
            Set(controller.testingVisibleMatrixGenotypes),
            Set([call.genotype, second.genotype])
        )

        let firstCell = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: call.genotype,
            sample: "AnimalA"
        )
        let cellMenu = try XCTUnwrap(
            controller.testingBuildActualMatrixContextMenu(for: firstCell)
        )
        let capturedCellHideRow = try XCTUnwrap(
            cellMenu.items
                .first {
                    $0.identifier?.rawValue == "genotype-matrix-visibility-rows"
                }?
                .submenu?
                .items
                .first {
                    $0.identifier?.rawValue == "genotype-matrix-visibility-hide-rows"
                }
        )
        controller.testingSelectMatrixCell(
            genotype: second.genotype,
            sample: "AnimalA"
        )

        XCTAssertFalse(
            controller.testingActivateMatrixContextMenuItem(capturedCellHideRow)
        )
        XCTAssertEqual(
            Set(controller.testingVisibleMatrixGenotypes),
            Set([call.genotype, second.genotype])
        )
    }


    func testMatrixVisibilityActualContextMenuCapturesImmutableSnapshotTargets() throws {
        let first = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 8)
        let second = makeCall(sample: "AnimalA", genotype: "02_Mafa_B", reads: 7)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [first, second]))
        controller.testingSetMatrixContextMenuSnapshotSourceFactory { snapshot in
            controller.testingSelectMatrixRows(genotypes: [second.genotype], sample: nil)
            return GenotypeMatrixImmutableContextMenuSnapshotSource(snapshot: snapshot)
        }
        defer { controller.testingSetMatrixContextMenuSnapshotSourceFactory(nil) }

        let menu = try XCTUnwrap(controller.testingBuildActualMatrixContextMenu(
            for: .row(locus: "MHC-A", genotype: first.genotype)
        ))
        let capturedHide = try XCTUnwrap(menu.items.first {
            $0.identifier?.rawValue == "genotype-matrix-visibility-hide-rows"
        })

        XCTAssertFalse(controller.testingActivateMatrixContextMenuItem(capturedHide))
        XCTAssertEqual(
            Set(controller.testingVisibleMatrixGenotypes),
            Set([first.genotype, second.genotype])
        )
    }


    func testMatrixShowAllContextCommandRemainsGlobalWhenSelectionChanges() throws {
        let first = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 8)
        let second = makeCall(sample: "AnimalA", genotype: "02_Mafa_B", reads: 7)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [first, second]))
        controller.testingSelectMatrixRows(genotypes: [first.genotype], sample: nil)
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.hideSelectedRows))

        let menu = try XCTUnwrap(controller.testingBuildActualMatrixContextMenu(
            for: .row(locus: "MHC-B", genotype: second.genotype)
        ))
        let showAll = try XCTUnwrap(menu.items.first {
            $0.identifier?.rawValue == "genotype-matrix-visibility-show-all"
        })
        controller.testingSelectMatrixColumn(sample: "AnimalA")

        XCTAssertTrue(controller.testingActivateMatrixContextMenuItem(showAll))
        XCTAssertEqual(
            Set(controller.testingVisibleMatrixGenotypes),
            Set([first.genotype, second.genotype])
        )
    }


    func testMatrixAnnotationContextCommandContinuesToUseCurrentSelection() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixCurrentAnnotationSelection")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 8)
        let second = makeCall(sample: "AnimalA", genotype: "02_Mafa_B", reads: 7)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [first, second]
        ))

        let menu = try XCTUnwrap(controller.testingBuildActualMatrixContextMenu(
            for: .cell(locus: "MHC-A", genotype: first.genotype, sample: "AnimalA")
        ))
        let falsePositive = try XCTUnwrap(menu.items.first {
            $0.title == "Mark False Positive"
        })
        controller.testingSelectMatrixCell(
            genotype: second.genotype,
            sample: "AnimalA"
        )

        _ = controller.testingActivateMatrixContextMenuItem(falsePositive)

        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(
            forBundleAt: bundleURL
        )
        XCTAssertEqual(sidecar.matrixReviews.map(\.target), [
            .cell(locus: "MHC-B", genotype: second.genotype, sample: "AnimalA"),
        ])
        XCTAssertEqual(sidecar.matrixReviews.map(\.disposition), [.falsePositive])
    }


    func testMatrixVisibilityCommandsPostOneExactAnnouncementAndNoOpIsSilent() {
        let first = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 8)
        let second = makeCall(sample: "AnimalB", genotype: "02_Mafa_B", reads: 6)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [first, second]))
        let announcements = RecordingGenotypeSearchAnnouncements()
        controller.testingSetMatrixVisibilityAnnouncementPoster(announcements)

        controller.testingSelectMatrixRows(genotypes: [first.genotype], sample: nil)
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.hideSelectedRows))
        XCTAssertFalse(controller.performMatrixVisibilityCommand(.hideSelectedRows))
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.showAllRows))

        controller.testingSelectMatrixRows(genotypes: [first.genotype], sample: nil)
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.showOnlySelectedRows))
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.reset))

        controller.testingSelectMatrixColumns(samples: ["AnimalA"])
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.hideSelectedColumns))
        XCTAssertFalse(controller.performMatrixVisibilityCommand(.hideSelectedColumns))
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.showAllColumns))

        controller.testingSelectMatrixColumns(samples: ["AnimalA"])
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.showOnlySelectedColumns))
        XCTAssertTrue(controller.performMatrixVisibilityCommand(.reset))

        XCTAssertEqual(announcements.messages, [
            "Selected rows hidden.",
            "All rows shown.",
            "Showing only selected rows.",
            "All rows and columns shown.",
            "Selected columns hidden.",
            "All columns shown.",
            "Showing only selected columns.",
            "All rows and columns shown.",
        ])
    }


    func testMatrixVisibilityCanRecoverThroughCapabilityAfterEveryRowIsHidden() {
        let call = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.testingSelectMatrixRows(genotypes: [call.genotype], sample: nil)

        XCTAssertTrue(controller.performMatrixVisibilityCommand(.hideSelectedRows))
        XCTAssertTrue(controller.testingVisibleMatrixGenotypes.isEmpty)
        XCTAssertTrue(controller.testingMatrixVisibilityCapability.canResetVisibility)
        XCTAssertEqual(controller.testingMatrixVisibilityCapability.summary, "Scope: Entire matrix")

        XCTAssertTrue(controller.performMatrixVisibilityCommand(.reset))
        XCTAssertEqual(controller.testingVisibleMatrixGenotypes, [call.genotype])
    }


    func testDetachingHostPresentationCallbacksClearsMatrixVisibilityPublication() {
        let controller = GenotypeResultViewController()
        var received = 0
        controller.onMatrixVisibilityCapabilityChanged = { _ in received += 1 }

        controller.detachHostPresentationCallbacks()
        controller.notifyMatrixVisibilityCapabilityIfAvailable()

        XCTAssertEqual(received, 0)
    }


    func testMatrixCandidateSelectionHotPathUsesIndexedRowIdentity() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func stableSelectionAllows("))
        let end = try XCTUnwrap(source.range(
            of: "private static func color(",
            range: start.upperBound..<source.endIndex
        ))
        let hotPath = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(hotPath.contains("visibleRowIndexByID[selectedRowID]"))
        XCTAssertFalse(hotPath.contains("visibleRows.first"))
        XCTAssertFalse(hotPath.contains("private func targetIdentity"))
    }


    func testMatrixRowCommentMarkerFallsBackToVisibleSelectorAndRetainsAccessibility() throws {
        let genotype = "01_Mafa_A1_ROW_MARKER_FALLBACK"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 4)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixComments = [
            .init(
                target: .row(locus: "MHC-A", genotype: genotype),
                body: "Fallback marker.",
                author: "test",
                timestamp: "2026-07-24T00:00:01Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(samples: [], calls: [call]), sidecar: sidecar)
        matrix.testingSetStandardColumnVisibleWithoutPersist("genotype", visible: false)
        matrix.testingSetStandardColumnVisibleWithoutPersist("locus", visible: false)

        XCTAssertEqual(
            matrix.testingNativeRowCommentMarkerColumnIdentifier(genotype: genotype),
            "rowSelector"
        )
        XCTAssertTrue(
            try XCTUnwrap(matrix.testingNativeRowCommentAccessibilityLabel(genotype: genotype))
                .contains("1 allele row comment")
        )
    }


    func testMatrixRowCommentMarkerHostsExposeScopedTooltipAcrossFallbackColumns() throws {
        let genotype = "01_Mafa_A1_ROW_TOOLTIP"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 4)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixComments = [
            .init(
                target: .row(locus: "MHC-A", genotype: genotype),
                body: "Scoped row note.",
                author: "test",
                timestamp: "2026-07-24T00:00:01Z"
            ),
        ]
        let fastaMatrix = GenotypeComparisonMatrixView()
        fastaMatrix.configure(
            result: makeResult(samples: [], calls: [call]),
            sidecar: sidecar
        )
        fastaMatrix.testingSetStandardColumnVisibleWithoutPersist("genotype", visible: true)
        XCTAssertTrue(
            try XCTUnwrap(fastaMatrix.testingNativeRowCommentToolTip(genotype: genotype))
                .contains("Allele Row: Scoped row note.")
        )

        fastaMatrix.testingSetStandardColumnVisibleWithoutPersist("genotype", visible: false)
        fastaMatrix.testingSetStandardColumnVisibleWithoutPersist("locus", visible: true)
        XCTAssertTrue(
            try XCTUnwrap(fastaMatrix.testingNativeRowCommentToolTip(genotype: genotype))
                .contains("Allele Row: Scoped row note.")
        )

        fastaMatrix.testingSetStandardColumnVisibleWithoutPersist("locus", visible: false)
        XCTAssertEqual(
            fastaMatrix.testingNativeRowCommentMarkerColumnIdentifier(genotype: genotype),
            "rowSelector"
        )
        XCTAssertTrue(
            try XCTUnwrap(fastaMatrix.testingNativeRowCommentToolTip(genotype: genotype))
                .contains("Allele Row: Scoped row note.")
        )

        let referenceMatrix = GenotypeComparisonMatrixView()
        referenceMatrix.configure(
            result: makeResult(
                samples: [],
                calls: [call],
                referenceMetadata: makeGenBankReferenceMetadata()
            ),
            sidecar: sidecar
        )
        referenceMatrix.testingSetStandardColumnVisibleWithoutPersist("genotype", visible: false)
        referenceMatrix.testingSetReferenceColumnVisibleWithoutPersist(
            fieldKey: "feature.allele",
            visible: true
        )
        XCTAssertEqual(
            referenceMatrix.testingNativeRowCommentMarkerColumnIdentifier(genotype: genotype),
            "reference.feature.allele"
        )
        XCTAssertTrue(
            try XCTUnwrap(referenceMatrix.testingNativeRowCommentToolTip(genotype: genotype))
                .contains("Allele Row: Scoped row note.")
        )
    }


    func testMatrixMenuAndKeyboardCommandsShareCachedCapabilityAndDisabledReasons() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixMenuKeyboardState")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_MISSING"
        let visible = makeCall(sample: "AnimalA", genotype: genotype, reads: 9)
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
                    calls: [visible]
                ),
                ONTGenotypeSampleResult(
                    sample: "AnimalB",
                    passedAlignments: 0,
                    passedUniqueReads: 0,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: []
                ),
            ],
            calls: [visible]
        ))
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalB"
        )
        let menu = try XCTUnwrap(controller.testingBuildMatrixContextMenu(for: target))
        let falsePositive = try XCTUnwrap(menu.items.first { $0.command == .markFalsePositive })
        let falseNegative = try XCTUnwrap(menu.items.first { $0.command == .markFalseNegative })

        XCTAssertEqual(
            falsePositive.availability.disabledReason,
            controller.testingMatrixReviewCapability.falsePositive.disabledReason
        )
        XCTAssertEqual(falseNegative.availability, controller.testingMatrixReviewCapability.falseNegative)
        XCTAssertFalse(controller.testingPerformMatrixKeyboardCommand(.markFalsePositive))
        XCTAssertTrue(controller.testingPerformMatrixKeyboardCommand(.markFalseNegative))

        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        XCTAssertEqual(sidecar.matrixReviews.map(\.target), [target])
        XCTAssertEqual(sidecar.matrixReviews.map(\.disposition), [.falseNegative])
    }


    func testMatrixRowAndHeaderMenusOfferScopedCommentsAndSupportSelectionHelper() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixScopedContextMenus")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SCOPED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 11)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 0)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [strong, weak]
        ))
        var drafts = ["Row note.", "Column note."]
        controller.testingSetMatrixCommentBodyProvider { _ in drafts.removeFirst() }

        let rowTarget = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A",
            genotype: genotype
        )
        let rowMenu = try XCTUnwrap(controller.testingBuildMatrixContextMenu(for: rowTarget))
        XCTAssertNotNil(rowMenu.items.first { $0.command == .editComment })
        XCTAssertNotNil(rowMenu.items.first { $0.command == .selectSupportedCells })
        XCTAssertEqual(rowMenu.visibilityItems.map(\.title), [
            "Hide 1 Selected Row",
            "Show Only 1 Selected Row",
            "Show Only Columns with Calls in This Row",
        ])
        XCTAssertTrue(controller.testingPerformMatrixContextCommand(.editComment))
        XCTAssertTrue(controller.testingPerformMatrixContextCommand(.showOnlyColumnsWithSelectedRowCalls))
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA"])

        let columnTarget = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        let headerMenu = try XCTUnwrap(controller.testingBuildMatrixContextMenu(for: columnTarget))
        XCTAssertNotNil(headerMenu.items.first { $0.command == .editComment })
        XCTAssertNotNil(headerMenu.items.first { $0.command == .selectSupportedCells })
        XCTAssertEqual(headerMenu.visibilityItems.map(\.title), [
            "Hide 1 Selected Column",
            "Show Only 1 Selected Column",
            "Show All Rows and Columns",
        ])
        XCTAssertTrue(controller.testingPerformMatrixContextCommand(.editComment))

        _ = controller.testingBuildMatrixContextMenu(for: rowTarget)
        XCTAssertTrue(controller.testingPerformMatrixContextCommand(.selectSupportedCells))
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
        ])

        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        XCTAssertEqual(
            Set(sidecar.resolvedMatrixComments.keys),
            Set([rowTarget, columnTarget])
        )
    }


    func testMatrixAccessibilityDescribesEvidenceReviewSelectionAndScopedCommentsWithoutMarkerStops() throws {
        let genotype = "01_Mafa_A1_ACCESSIBLE"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let cellTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-24T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: cellTarget,
                disposition: .falsePositive,
                author: "test",
                timestamp: "2026-07-24T00:00:01Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: .row(locus: "MHC-A", genotype: genotype),
                body: "Row.",
                author: "test",
                timestamp: "2026-07-24T00:00:02Z"
            ),
            .init(
                target: .column(sample: "AnimalA"),
                body: "Column.",
                author: "test",
                timestamp: "2026-07-24T00:00:03Z"
            ),
            .init(
                target: cellTarget,
                body: "Cell.",
                author: "test",
                timestamp: "2026-07-24T00:00:04Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(samples: [], calls: [call]), sidecar: sidecar)
        matrix.testingSelectCell(genotype: genotype, sample: "AnimalA")

        let label = try XCTUnwrap(matrix.testingCellAccessibilityLabel(
            genotype: genotype,
            sample: "AnimalA"
        ))
        XCTAssertTrue(label.contains("Sample AnimalA, genotype \(genotype), locus MHC-A"))
        XCTAssertTrue(label.contains("Evidence: 42 unique reads"))
        XCTAssertTrue(label.contains("Review: false positive"))
        XCTAssertTrue(label.contains("Selected"))
        XCTAssertTrue(label.contains("allele row 1, sample column 1, cell 1"))
        XCTAssertTrue(
            try XCTUnwrap(matrix.testingColumnAccessibilityLabel(sample: "AnimalA"))
                .contains("1 sample column comment")
        )
        let commentHost = try XCTUnwrap(matrix.testingCellCommentMarkerHost(
            genotype: genotype,
            sample: "AnimalA"
        ))
        let accessibilityElements = ([commentHost] + descendants(of: commentHost))
            .filter { $0.isAccessibilityElement() }
        XCTAssertEqual(accessibilityElements.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(accessibilityElements.first?.accessibilityLabel())
                .contains("Comments: allele row 1, sample column 1, cell 1")
        )
        XCTAssertEqual(
            matrix.testingReviewLegendText,
            "[n] False positive   ▣ False negative   ◥ Comment"
        )
    }


    func testMatrixMenuReviewMutationUsesTargetedReloadAndSelectionKeepsEvidenceIndex() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixMenuTargetedReload")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_TARGETED"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 7)
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))
        let evidenceBuildCount = controller.testingMatrixEvidenceIndexBuildCount
        controller.testingResetMatrixReloadCounters()

        _ = controller.testingBuildMatrixContextMenu(for: target)
        XCTAssertEqual(controller.testingMatrixEvidenceIndexBuildCount, evidenceBuildCount)
        XCTAssertTrue(controller.testingPerformMatrixContextCommand(.markFalsePositive))

        XCTAssertEqual(controller.testingMatrixFullReloadCount, 0)
        XCTAssertGreaterThan(controller.testingMatrixPartialReloadCount, 0)
        XCTAssertEqual(controller.testingMatrixEvidenceIndexBuildCount, evidenceBuildCount)
    }


    func testMatrixRowCommentMenuMutationUsesTargetedReloadAcrossPinnedAndSampleTables() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixRowCommentTargetedReload")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_ROW_TARGETED"
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 7)]
        ))
        controller.testingSetMatrixCommentBodyProvider { _ in "Pinned row note." }
        let target = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A",
            genotype: genotype
        )
        _ = controller.testingBuildMatrixContextMenu(for: target)
        controller.testingResetMatrixReloadCounters()

        XCTAssertTrue(controller.testingPerformMatrixContextCommand(.editComment))

        XCTAssertEqual(controller.testingPinnedMatrixFullReloadCount, 0)
        XCTAssertEqual(controller.testingSampleMatrixFullReloadCount, 0)
        XCTAssertGreaterThan(controller.testingPinnedMatrixPartialReloadCount, 0)
        XCTAssertGreaterThan(controller.testingSampleMatrixPartialReloadCount, 0)
    }


    func testMatrixRepresentativeBenchmarkRecordsLinearTargetsAndMenuProductObservation() {
        let samples = (0..<8).map { "Animal\($0)" }
        let calls = (0..<40).flatMap { row in
            samples.map { sample in
                makeCall(
                    sample: sample,
                    genotype: String(format: "%02d_Mafa_A1_BENCHMARK", row),
                    reads: row + 1
                )
            }
        }
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(samples: [], calls: calls))

        let record = matrix.testingRecordRepresentativeBenchmark(
            smallSelectionCount: 8,
            largeSelectionCount: 200,
            visibleRowLimit: 30
        )
        print(
            "Matrix representative benchmark (seconds): "
                + "small=\(record.smallSelectionAggregation.wallTime), "
                + "large=\(record.largeSelectionAggregation.wallTime), "
                + "menu=\(record.menuConstruction.wallTime), "
                + "redraw=\(record.visibleRedraw.wallTime), "
                + "bulkSidecar=\(record.bulkSidecarMutation.wallTime)"
        )

        XCTAssertEqual(record.smallSelectionAggregation.targetCount, 8)
        XCTAssertEqual(record.largeSelectionAggregation.targetCount, 200)
        XCTAssertEqual(record.menuConstruction.targetCount, 200)
        XCTAssertEqual(record.visibleRedraw.targetCount, 30 * 8)
        XCTAssertEqual(record.bulkSidecarMutation.targetCount, 200)
        XCTAssertGreaterThanOrEqual(record.smallSelectionAggregation.wallTime, 0)
        XCTAssertGreaterThanOrEqual(record.largeSelectionAggregation.wallTime, 0)
        XCTAssertGreaterThanOrEqual(record.menuConstruction.wallTime, 0)
        XCTAssertGreaterThanOrEqual(record.visibleRedraw.wallTime, 0)
        XCTAssertGreaterThanOrEqual(record.bulkSidecarMutation.wallTime, 0)
    }


    func testMatrixReviewCapabilityUsesRawEvidenceIndependentOfFiltersAndDisplayThresholds() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixRawEvidenceFilters")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SUPPORTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))
        controller.testingShowMatrixTargetSelection([target])
        let unfiltered = controller.testingMatrixReviewCapability
        let evidenceBuildCount = controller.testingMatrixEvidenceIndexBuildCount

        var state = controller.testingDisplayState
        state.hideLowSupport = true
        state.minimumSupportPercent = 100
        state.matrixMinimumReads = 100
        state.matrixMinimumPercent = 100
        state.matrixRowFilterText = "does-not-match"
        state.matrixSampleFilterText = "hidden-sample"
        controller.testingApplyDisplayState(state)

        XCTAssertEqual(unfiltered.falsePositive, .enabled)
        XCTAssertEqual(controller.testingMatrixReviewCapability.falsePositive, .enabled)
        XCTAssertEqual(controller.testingMatrixEvidenceIndexBuildCount, evidenceBuildCount)
    }


    func testMatrixReviewCapabilityTreatsAbsentExactRecordAsFalseNegativeEligible() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixAbsentEvidence")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_EXPECTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalB"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))

        controller.testingShowMatrixTargetSelection([target])

        XCTAssertEqual(controller.testingMatrixReviewCapability.falseNegative, .enabled)
        XCTAssertEqual(controller.testingMatrixReviewCapability.support.unsupportedCount, 1)
    }


    func testMatrixReviewCapabilityUsesFullStableCandidateIdentityAndRejectsMixedSelection() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixCandidateEvidenceIdentity")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let supported = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Collision_nov",
            sample: "AnimalA",
            stableClusterID: "cluster-supported"
        )
        let absent = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Collision_nov",
            sample: "AnimalA",
            stableClusterID: "cluster-absent"
        )
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-supported", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
                makeCandidate(id: "cluster-absent", name: "Collision_nov", classification: .novel, support: .singleton, samples: []),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-supported", sample: "AnimalA", reads: 5),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        controller.testingShowMatrixTargetSelection([supported])
        XCTAssertEqual(controller.testingMatrixReviewCapability.falsePositive, .enabled)
        controller.testingShowMatrixTargetSelection([absent])
        XCTAssertEqual(controller.testingMatrixReviewCapability.falseNegative, .enabled)
        controller.testingShowMatrixTargetSelection([supported, absent])

        XCTAssertFalse(controller.testingMatrixReviewCapability.falsePositive.isEnabled)
        XCTAssertFalse(controller.testingMatrixReviewCapability.falseNegative.isEnabled)
        XCTAssertEqual(controller.testingMatrixReviewCapability.support.supportedCount, 1)
        XCTAssertEqual(controller.testingMatrixReviewCapability.support.unsupportedCount, 1)
    }


    func testInspectorAndMatrixConsumeSameCapabilitySnapshotWithoutRebuildingIndexesOnSelection() {
        let genotype = "01_Mafa_A1_SUPPORTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()
        let controller = GenotypeResultViewController()
        controller.onMatrixReviewCapabilityChanged = { viewModel.updateMatrixReviewCapability($0) }
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))
        let evidenceBuildCount = controller.testingMatrixEvidenceIndexBuildCount
        let annotationBuildCount = controller.testingMatrixAnnotationIndexBuildCount

        controller.testingShowMatrixTargetSelection([target])

        XCTAssertEqual(viewModel.matrixReviewCapability, controller.testingMatrixReviewCapability)
        XCTAssertEqual(
            controller.testingComparisonMatrixReviewCapability,
            controller.testingMatrixReviewCapability
        )
        XCTAssertEqual(controller.testingMatrixEvidenceIndexBuildCount, evidenceBuildCount)
        XCTAssertEqual(controller.testingMatrixAnnotationIndexBuildCount, annotationBuildCount)
    }


    func testInspectorCapabilityCarriesApplicableCachedScopedCommentsForSelectedCell() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixInspectorScopedComments")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SUPPORTED"
        let cell = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let row = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A",
            genotype: genotype
        )
        let column = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        let viewModel = GenotypeResultDisplaySectionViewModel()
        let controller = GenotypeResultViewController()
        controller.onSelectionStateChanged = { viewModel.updateSelection($0) }
        controller.onMatrixReviewCapabilityChanged = { viewModel.updateMatrixReviewCapability($0) }
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))
        controller.editMatrixComment(.init(targets: [cell], intent: .upsert(body: "Cell note")))
        controller.editMatrixComment(.init(targets: [row], intent: .upsert(body: "Row note")))
        controller.editMatrixComment(.init(targets: [column], intent: .upsert(body: "Column note")))

        controller.testingShowMatrixTargetSelection([cell])

        XCTAssertEqual(
            viewModel.matrixCommentCards.map(\.displayBody),
            ["Cell note", "Row note", "Column note"]
        )
        XCTAssertEqual(
            Set(controller.testingMatrixReviewCapability.commentsByTarget.keys),
            [cell, row, column]
        )
    }


    func testReviewRequestIsRevalidatedAgainstCurrentRawEvidenceBeforeStorePublication() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixReviewRevalidation")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SUPPORTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let request = GenotypeMatrixReviewRequest(
            targets: [target],
            intent: .set(.falsePositive)
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))
        controller.testingShowMatrixTargetSelection([target])
        XCTAssertEqual(controller.testingMatrixReviewCapability.falsePositive, .enabled)

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: []
        ))
        let annotationBuildCount = controller.testingMatrixAnnotationIndexBuildCount
        var surfacedError: Error?
        controller.onMatrixAnnotationCommandError = { surfacedError = $0 }
        controller.applyMatrixReview(request)

        XCTAssertEqual(
            surfacedError as? GenotypeMatrixReviewMutationError,
            .ineligibleEvidence
        )
        XCTAssertTrue(
            try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
                .matrixReviews.isEmpty
        )
        XCTAssertEqual(controller.testingMatrixAnnotationIndexBuildCount, annotationBuildCount)
    }


    func testSemanticCommentRequestsUpsertReplaceAndRemoveExactTargets() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixCommentIntents")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        let second = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalB")
        let visibleCall = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_VISIBLE",
            reads: 5
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 5,
                passedUniqueReads: 5,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [visibleCall]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 0,
                passedUniqueReads: 0,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: []
            ),
        ], calls: [visibleCall]))
        controller.testingResetMatrixReloadCounters()

        controller.editMatrixComment(.init(targets: [first], intent: .upsert(body: "first")))
        controller.editMatrixComment(.init(targets: [first], intent: .upsert(body: "edited")))
        controller.editMatrixComment(.init(
            targets: [first, second],
            intent: .replace(body: "bulk replacement")
        ))
        var sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        XCTAssertEqual(sidecar.matrixComments.count, 2)
        XCTAssertEqual(Set(sidecar.matrixComments.map(\.body)), ["bulk replacement"])

        controller.editMatrixComment(.init(targets: [first], intent: .remove))
        sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        XCTAssertEqual(sidecar.matrixComments.map(\.target), [second])
        XCTAssertEqual(controller.testingMatrixFullReloadCount, 0)
        XCTAssertGreaterThan(controller.testingMatrixPartialReloadCount, 0)
    }


    func testSuccessfulMatrixAnnotationBurstMarksDirtyWithoutLegacyAutoPublication() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixWorkbookCoalesce")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SUPPORTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let scheduler = MatrixWorkbookUpdateSchedulerSpy()
        let controller = GenotypeResultViewController()
        controller.matrixWorkbookUpdateScheduler = scheduler
        var requests: [GenotypeCurrentWorkbookUIRequest] = []
        controller.onCurrentWorkbookSyncRequested = { requests.append($0) }
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))

        controller.applyMatrixReview(.init(targets: [target], intent: .set(.falsePositive)))
        controller.editMatrixComment(.init(targets: [target], intent: .upsert(body: "reviewed")))

        XCTAssertEqual(scheduler.scheduledCount, 0)
        XCTAssertEqual(requests.map(\.action), [.markDirty, .markDirty])
        XCTAssertTrue(requests.allSatisfy(\.snapshot.annotationOnly))
        scheduler.fireScheduledActions()
        XCTAssertEqual(requests.map(\.action), [.markDirty, .markDirty])
    }

}
