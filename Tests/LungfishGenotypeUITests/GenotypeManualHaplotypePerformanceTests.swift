import AppKit
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeManualHaplotypePerformanceTests: XCTestCase {
    func testRepresentativeMatrixInteractionsMeetReleaseFrameBudgets()
        throws
    {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let baseline = try MatrixInteractionHarness(
            result: fixture.result(workflowMode: .haplotyped),
            sidecar: nil
        )
        let withBand = try MatrixInteractionHarness(
            result: fixture.result(workflowMode: .genotypeOnly),
            sidecar: fixture.sidecar
        )

        baseline.warmUp()
        withBand.warmUp()

        let pairedSamples = baseline.measureRepresentativeInteractions(
            alongside: withBand
        )
        let baselineSamples = pairedSamples.primary
        let bandSamples = pairedSamples.secondary
        let operations: [(
            name: String,
            band: [TimeInterval],
            baseline: [TimeInterval]
        )] = [
            ("scroll", bandSamples.scroll, baselineSamples.scroll),
            ("reorder", bandSamples.reorder, baselineSamples.reorder),
            ("resize", bandSamples.resize, baselineSamples.resize),
        ]
        let bandAggregate = bandSamples.scroll
            + bandSamples.reorder
            + bandSamples.resize
        let baselineAggregate = baselineSamples.scroll
            + baselineSamples.reorder
            + baselineSamples.resize
        let p95 = percentile(bandAggregate, 0.95)
        let p99 = percentile(bandAggregate, 0.99)
        let baselineP95 = percentile(baselineAggregate, 0.95)
        let aggregateRegression = baselineP95 > 0
            ? (p95 - baselineP95) / baselineP95
            : 0

        print(
            "Manual haplotype release benchmark (seconds): "
                + operations.map { operation in
                    let operationP95 = percentile(operation.band, 0.95)
                    let operationP99 = percentile(operation.band, 0.99)
                    let operationBaselineP95 = percentile(
                        operation.baseline,
                        0.95
                    )
                    let operationRegression = regression(
                        p95: operationP95,
                        baselineP95: operationBaselineP95
                    )
                    return
                        "\(operation.name)_p95=\(operationP95), "
                        + "\(operation.name)_p99=\(operationP99), "
                        + "\(operation.name)_no_band_p95="
                        + "\(operationBaselineP95), "
                        + "\(operation.name)_regression="
                        + "\(operationRegression)"
                }.joined(separator: ", ")
                + ", "
                + "aggregate_p95=\(p95), aggregate_p99=\(p99), "
                + "no_band_p95=\(baselineP95), "
                + "regression=\(aggregateRegression)"
        )

        let enforcesReleaseBudget: Bool
        #if DEBUG
        enforcesReleaseBudget =
            ProcessInfo.processInfo.environment[
                "LUNGFISH_RELEASE_PERFORMANCE_TEST"
            ] == "1"
        #else
        enforcesReleaseBudget = true
        #endif
        if enforcesReleaseBudget {
            for operation in operations {
                let operationP95 = percentile(operation.band, 0.95)
                let operationP99 = percentile(operation.band, 0.99)
                let operationRegression = regression(
                    p95: operationP95,
                    baselineP95: percentile(operation.baseline, 0.95)
                )
                XCTAssertLessThanOrEqual(
                    operationP95,
                    0.0167,
                    "\(operation.name) p95 exceeded one frame."
                )
                XCTAssertLessThanOrEqual(
                    operationP99,
                    0.0334,
                    "\(operation.name) p99 exceeded two frames."
                )
                XCTAssertLessThanOrEqual(
                    operationRegression,
                    0.10,
                    "\(operation.name) p95 regressed more than 10% versus the otherwise-identical no-band matrix."
                )
            }
        } else {
            XCTAssertTrue(operations.allSatisfy { !$0.band.isEmpty })
        }
    }

    func testFourteenSlotSavePreparationExcludesFilesystemAndStaysBounded() {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: fixture.assignments
        )
        let draft = GenotypeManualHaplotypeDraft(
            sample: fixture.samples[0],
            index: index
        )
        let model = GenotypeManualHaplotypeEditorModel(
            snapshot: .init(
                draft: draft,
                copyCandidates: [],
                isReadOnly: false
            ),
            onSave: { _ in
                XCTFail("Save preparation must not perform persistence.")
                return draft
            },
            onReload: {
                XCTFail("Save preparation must not reload persistence.")
                return .init(
                    draft: draft,
                    copyCandidates: [],
                    isReadOnly: false
                )
            },
            onExport: {}
        )
        for locus in GenotypeManualHaplotypeLocus.allCases {
            for slot in HaplotypeSlot.allCases {
                model.updateLabel(
                    "Edited \(locus.workbookLabel) \(slot.rawValue)",
                    locus: locus,
                    slot: slot
                )
            }
        }

        var samples: [TimeInterval] = []
        samples.reserveCapacity(100)
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            XCTAssertTrue(model.prepareSave())
            samples.append(CFAbsoluteTimeGetCurrent() - start)
            model.cancelPreparedSave()
        }

        let p99 = percentile(samples, 0.99)
        print(
            "Manual haplotype save preparation p99 (seconds): \(p99)"
        )
        XCTAssertLessThanOrEqual(p99, 0.250)
    }

    func testSingleSampleEditProducesOneVisibleColumnInvalidation() {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let before = GenotypeManualHaplotypeAssignmentBandSnapshot(
            index: GenotypeManualHaplotypeAssignmentIndex(
                assignments: fixture.assignments
            ),
            samples: fixture.samples
        )
        var changedAssignments = fixture.assignments
        changedAssignments[0].label = "Changed MHC-A H1"
        let after = GenotypeManualHaplotypeAssignmentBandSnapshot(
            index: GenotypeManualHaplotypeAssignmentIndex(
                assignments: changedAssignments
            ),
            samples: fixture.samples
        )
        let changedSamples = after.changedSamples(comparedTo: before)
        let columnFrames = Dictionary(
            uniqueKeysWithValues: fixture.samples.enumerated().map {
                index,
                sample in
                (
                    sample,
                    NSRect(
                        x: CGFloat(index) * 110,
                        y: 0,
                        width: 110,
                        height: 176
                    )
                )
            }
        )
        let visibleBounds = NSRect(x: 0, y: 0, width: 1_320, height: 176)

        let invalidation = GenotypeManualHaplotypeBandInvalidationPlan(
            samples: changedSamples,
            columnFrames: columnFrames,
            visibleBounds: visibleBounds
        )

        XCTAssertEqual(changedSamples, [fixture.samples[0]])
        XCTAssertEqual(invalidation.rects, [columnFrames[fixture.samples[0]]])
    }

    func testTypingDraftDoesNotResizeColumnsOrRebuildProjection() throws {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeDraft-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try fixture.sidecar.encoded().write(
            to: bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            ),
            options: .atomic
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 1_200,
            height: 800
        )
        controller.configure(
            result: fixture.result(
                workflowMode: .genotypeOnly,
                bundleURL: bundleURL
            )
        )
        controller.testingShowMatrixTargetSelection([
            .column(sample: fixture.samples[0]),
        ])
        controller.testingSetManualHaplotypeBandDisclosureExpanded(true)
        let matrix = controller.testingComparisonMatrix
        let widthBeforeTyping = matrix.testingSampleColumnWidth(
            sample: fixture.samples[0]
        )
        controller.testingResetProjectionPerformanceCounters()
        matrix.testingResetManualHaplotypeAutoFitMeasurementCounts()
        let projectionBeforeTyping =
            controller.testingProjectionPerformanceSnapshot

        controller.testingUpdateManualHaplotypeLabel(
            "A draft that has not been saved"
        )

        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(
            matrix.testingSampleColumnWidth(sample: fixture.samples[0]),
            widthBeforeTyping,
            accuracy: 0.5
        )
        XCTAssertTrue(
            matrix.testingManualHaplotypeAutoFitMeasurementCounts.isEmpty
        )
        let projectionAfterTyping =
            controller.testingProjectionPerformanceSnapshot
        XCTAssertEqual(
            projectionAfterTyping.matrix.baseProjectionBuildCount,
            projectionBeforeTyping.matrix.baseProjectionBuildCount
        )
        XCTAssertEqual(
            projectionAfterTyping.matrix.derivedProjectionPassCount,
            projectionBeforeTyping.matrix.derivedProjectionPassCount
        )
        XCTAssertEqual(
            projectionAfterTyping.matrix.columnRebuildCount,
            projectionBeforeTyping.matrix.columnRebuildCount
        )
    }

    func testSingleSaveRemeasuresOnlyChangedSample() {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let matrix = GenotypeComparisonMatrixView(
            frame: NSRect(x: 0, y: 0, width: 1_440, height: 720)
        )
        matrix.configure(
            result: fixture.result(workflowMode: .genotypeOnly),
            sidecar: fixture.sidecar
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.testingResetManualHaplotypeAutoFitMeasurementCounts()
        matrix.testingResetProjectionPerformanceCounters()
        let projectionBeforeSave =
            matrix.testingProjectionPerformanceSnapshot
        var changedAssignments = fixture.assignments
        changedAssignments[0].label = "Changed after a successful save"

        matrix.applyManualHaplotypeAssignments(changedAssignments)

        XCTAssertEqual(
            matrix.testingManualHaplotypeAutoFitMeasurementCounts,
            [fixture.samples[0]: 1]
        )
        let projectionAfterSave =
            matrix.testingProjectionPerformanceSnapshot
        XCTAssertEqual(
            projectionAfterSave.baseProjectionBuildCount,
            projectionBeforeSave.baseProjectionBuildCount
        )
        XCTAssertEqual(
            projectionAfterSave.derivedProjectionPassCount,
            projectionBeforeSave.derivedProjectionPassCount
        )
        XCTAssertEqual(
            projectionAfterSave.columnRebuildCount,
            projectionBeforeSave.columnRebuildCount
        )
    }

    private func percentile(
        _ values: [TimeInterval],
        _ quantile: Double
    ) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let ordered = values.sorted()
        let index = min(
            ordered.count - 1,
            max(0, Int(ceil(Double(ordered.count) * quantile)) - 1)
        )
        return ordered[index]
    }

    private func regression(
        p95: TimeInterval,
        baselineP95: TimeInterval
    ) -> Double {
        baselineP95 > 0
            ? (p95 - baselineP95) / baselineP95
            : 0
    }
}

@MainActor
private final class MatrixInteractionHarness {
    private struct Views {
        let matrix: GenotypeComparisonMatrixView
        let table: NSTableView
        let clipView: NSClipView
    }

    private let views: Views
    private var sequence = 0

    init(
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar?
    ) throws {
        let matrix = GenotypeComparisonMatrixView(
            frame: NSRect(x: 0, y: 0, width: 1_440, height: 720)
        )
        matrix.configure(result: result, sidecar: sidecar)
        matrix.layoutSubtreeIfNeeded()
        let descendants = Self.descendants(of: matrix)
        let table = try XCTUnwrap(
            descendants.compactMap { $0 as? NSTableView }.first {
                $0.accessibilityIdentifier() == "genotype-comparison-table"
            }
        )
        let clipView = try XCTUnwrap(table.enclosingScrollView?.contentView)
        views = Views(matrix: matrix, table: table, clipView: clipView)
    }

    func warmUp() {
        for _ in 0..<20 {
            performScroll()
            performReorder()
            performResize()
        }
    }

    func measureRepresentativeInteractions(
        alongside other: MatrixInteractionHarness
    ) -> (
        primary: (
            scroll: [TimeInterval],
            reorder: [TimeInterval],
            resize: [TimeInterval]
        ),
        secondary: (
            scroll: [TimeInterval],
            reorder: [TimeInterval],
            resize: [TimeInterval]
        )
    ) {
        let scroll = measurePaired(
            primary: performScroll,
            secondary: other.performScroll
        )
        let reorder = measurePaired(
            primary: performReorder,
            secondary: other.performReorder
        )
        let resize = measurePaired(
            primary: performResize,
            secondary: other.performResize
        )
        return (
            primary: (
                scroll: scroll.primary,
                reorder: reorder.primary,
                resize: resize.primary
            ),
            secondary: (
                scroll: scroll.secondary,
                reorder: reorder.secondary,
                resize: resize.secondary
            )
        )
    }

    private func measurePaired(
        primary primaryOperation: () -> Void,
        secondary secondaryOperation: () -> Void
    ) -> (
        primary: [TimeInterval],
        secondary: [TimeInterval]
    ) {
        let measurementCount = 1_200
        var primary: [TimeInterval] = []
        var secondary: [TimeInterval] = []
        primary.reserveCapacity(measurementCount)
        secondary.reserveCapacity(measurementCount)
        for measurementIndex in 0..<measurementCount {
            let first = measurementIndex.isMultiple(of: 2)
                ? primaryOperation
                : secondaryOperation
            let second = measurementIndex.isMultiple(of: 2)
                ? secondaryOperation
                : primaryOperation
            let start = CFAbsoluteTimeGetCurrent()
            first()
            let firstDuration = CFAbsoluteTimeGetCurrent() - start
            let secondStart = CFAbsoluteTimeGetCurrent()
            second()
            let secondDuration =
                (CFAbsoluteTimeGetCurrent() - secondStart)
            if measurementIndex.isMultiple(of: 2) {
                primary.append(firstDuration)
                secondary.append(secondDuration)
            } else {
                secondary.append(firstDuration)
                primary.append(secondDuration)
            }
        }
        return (primary, secondary)
    }

    private func performScroll() {
        sequence &+= 1
        let maximumX = max(
            0,
            views.table.bounds.width - views.clipView.bounds.width
        )
        let x = maximumX == 0
            ? 0
            : CGFloat((sequence * 37) % max(1, Int(maximumX)))
        views.clipView.setBoundsOrigin(NSPoint(x: x, y: 0))
        views.table.enclosingScrollView?.reflectScrolledClipView(
            views.clipView
        )
        views.matrix.layoutSubtreeIfNeeded()
    }

    private func performReorder() {
        guard views.table.numberOfColumns > 2 else { return }
        let destination = sequence.isMultiple(of: 2)
            ? 1
            : views.table.numberOfColumns - 1
        views.table.moveColumn(0, toColumn: destination)
        views.matrix.layoutSubtreeIfNeeded()
        sequence &+= 1
    }

    private func performResize() {
        guard let column = views.table.tableColumns.first else { return }
        column.width = sequence.isMultiple(of: 2) ? 106 : 114
        views.matrix.layoutSubtreeIfNeeded()
        sequence &+= 1
    }

    private static func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
struct GenotypeManualHaplotypeTask10Fixture {
    let samples = (0..<100).map {
        String(format: "SAMPLE_%03d", $0)
    }

    var assignments: [ManualHaplotypeAssignment] {
        samples.flatMap { sample in
            GenotypeManualHaplotypeLocus.allCases.flatMap { locus in
                HaplotypeSlot.allCases.enumerated().map { index, slot in
                    ManualHaplotypeAssignment(
                        sample: sample,
                        locus: locus.rawValue,
                        slot: slot,
                        label:
                            "\(locus.workbookLabel)-"
                            + (slot == .h1 ? "Alpha" : "Beta"),
                        colorTokenIndex: index + 1,
                        diagnosticAlleles: [],
                        notes: ""
                    )
                }
            }
        }
    }

    var sidecar: GenotypeAnnotationSidecar {
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = assignments
        return sidecar
    }

    func result(
        workflowMode: GenotypeResultWorkflowMode,
        bundleURL requestedBundleURL: URL? = nil
    ) -> ONTGenotypeResultBundleData {
        let genotypes = [
            "01_Mafa_A1_001_01",
            "12_Mafa_B_001_01",
            "21_Mafa_DRB_001_01",
            "31_Mafa_DQA1_001_01",
            "41_Mafa_DQB1_001_01",
            "51_Mafa_DPA1_001_01",
            "61_Mafa_DPB1_001_01",
        ]
        var allCalls: [ONTGenotypeCall] = []
        var sampleResults: [ONTGenotypeSampleResult] = []
        allCalls.reserveCapacity(samples.count * genotypes.count)
        sampleResults.reserveCapacity(samples.count)
        for (sampleIndex, sample) in samples.enumerated() {
            let calls = genotypes.enumerated().map { genotypeIndex, genotype in
                ONTGenotypeCall(
                    sample: sample,
                    genotype: genotype,
                    passedAlignments: 100 + sampleIndex + genotypeIndex,
                    passedUniqueReads: 100 + sampleIndex + genotypeIndex,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    overallInputReads: nil,
                    overallUniqueRetainedReads: nil,
                    overallUniqueRetainedPercent: nil
                )
            }
            allCalls += calls
            sampleResults.append(
                ONTGenotypeSampleResult(
                    sample: sample,
                    passedAlignments: calls.reduce(0) {
                        $0 + $1.passedAlignments
                    },
                    passedUniqueReads: calls.reduce(0) {
                        $0 + $1.passedUniqueReads
                    },
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            )
        }
        let bundleURL = requestedBundleURL ?? URL(
            fileURLWithPath:
                "/tmp/manual-haplotype-task10-\(workflowMode.rawValue).lungfishgenotype"
        )
        let manifest = ONTGenotypeResultBundleManifest(
            kind:
                GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: workflowMode,
            outputName: "manual-haplotype-task10",
            analysisName: "Manual Haplotype Task 10",
            primaryWorkbookPath: "current.xlsx",
            longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )
        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: bundleURL.appendingPathComponent("current.xlsx"),
                longSummaryCSVURL: bundleURL.appendingPathComponent("calls.csv"),
                sampleSummaryCSVURL: bundleURL.appendingPathComponent("samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
                provenanceURL: bundleURL.appendingPathComponent("provenance.json")
            ),
            stats: ONTGenotypeRunStats(
                totalInputReads: allCalls.reduce(0) {
                    $0 + $1.passedAlignments
                },
                retainedUniqueReads: allCalls.reduce(0) {
                    $0 + $1.passedUniqueReads
                }
            ),
            calls: allCalls,
            samples: sampleResults,
            haplotypeAnalysis: nil,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcCandidateGenBankArtifactURLs: .empty,
            mhcAlignmentArtifactURLs: .empty,
            mhcReferenceVisualizations: nil,
            integrityWarnings: [],
            referenceMetadata: nil
        )
    }
}
