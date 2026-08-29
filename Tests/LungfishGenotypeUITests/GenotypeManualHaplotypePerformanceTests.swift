import AppKit
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeManualHaplotypePerformanceTests: XCTestCase {
    func testHaplotypedMiSeqDefaultPerformsZeroMatrixConfigurationWork()
        throws
    {
        let fixture = GenotypeManualHaplotypeTask10Fixture(sampleCount: 150)
        let bundleURL = try makeTemporaryBundleURL(
            named: "DefaultHaplotypeCalls"
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.testingResetSynchronizedMiSeqPerformanceCounters()

        controller.configure(
            result: fixture.result(
                workflowMode: .haplotyped,
                bundleURL: bundleURL,
                haplotypeAnalysis: fixture.haplotypeAnalysis
            )
        )

        let performance =
            controller.testingSynchronizedMiSeqPerformanceSnapshot
        XCTAssertEqual(controller.testingSummaryViewMode, .outline)
        XCTAssertEqual(performance.matrixConfigureCount, 0)
        XCTAssertEqual(performance.baseProjectionBuildCount, 0)
        XCTAssertEqual(performance.columnRebuildCount, 0)
        XCTAssertEqual(performance.unrelatedRowReloadCount, 0)
    }

    func testWarmHaplotypedMiSeqPresentationSwitchesReuseConfiguredModels()
        throws
    {
        let fixture = GenotypeManualHaplotypeTask10Fixture(sampleCount: 150)
        let bundleURL = try makeTemporaryBundleURL(named: "WarmSwitches")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(
            result: fixture.result(
                workflowMode: .haplotyped,
                bundleURL: bundleURL,
                haplotypeAnalysis: fixture.haplotypeAnalysis
            )
        )
        controller.testingApplyDisplayState(
            GenotypeResultDisplayState(summaryViewMode: .matrix)
        )
        controller.testingApplyDisplayState(
            GenotypeResultDisplayState(summaryViewMode: .outline)
        )
        controller.testingResetSynchronizedMiSeqPerformanceCounters()

        for index in 0..<20 {
            controller.testingApplyDisplayState(
                GenotypeResultDisplayState(
                    summaryViewMode: index.isMultiple(of: 2)
                        ? .matrix
                        : .outline
                )
            )
        }

        let performance =
            controller.testingSynchronizedMiSeqPerformanceSnapshot
        XCTAssertEqual(performance.matrixConfigureCount, 0)
        XCTAssertEqual(performance.baseProjectionBuildCount, 0)
        XCTAssertEqual(performance.columnRebuildCount, 0)
        XCTAssertEqual(performance.haplotypeAnalysisRunCount, 0)
        XCTAssertEqual(performance.workbookReloadCount, 0)
        XCTAssertEqual(performance.haplotypeModelRebuildCount, 0)
        XCTAssertEqual(performance.unrelatedRowReloadCount, 0)
    }

    func testChangedKeyOverrideInvalidatesOnlyItsBandSample()
        throws
    {
        let fixture = GenotypeManualHaplotypeTask10Fixture(sampleCount: 100)
        let bundleURL = try makeTemporaryBundleURL(named: "TargetedOverride")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(
            result: fixture.result(
                workflowMode: .haplotyped,
                bundleURL: bundleURL,
                haplotypeAnalysis: fixture.haplotypeAnalysis
            )
        )
        controller.testingApplyDisplayState(
            GenotypeResultDisplayState(summaryViewMode: .matrix)
        )
        let row = try XCTUnwrap(
            controller.testingSampleDetailRows(sample: fixture.samples[0])
                .first { $0.locus == "MHC-A" && $0.slot == .h1 }
        )
        controller.testingResetSynchronizedMiSeqPerformanceCounters()

        XCTAssertNil(
            controller.testingSaveSampleDetailOverrideWithoutPresentingSheet(
                sample: fixture.samples[0],
                row: row,
                target: "MHC-A-Override"
            )
        )

        let performance =
            controller.testingSynchronizedMiSeqPerformanceSnapshot
        XCTAssertEqual(performance.matrixConfigureCount, 0)
        XCTAssertEqual(performance.baseProjectionBuildCount, 0)
        XCTAssertEqual(performance.columnRebuildCount, 0)
        XCTAssertEqual(performance.bandInvalidationCount, 1)
        XCTAssertEqual(performance.haplotypeAnalysisRunCount, 0)
        XCTAssertEqual(performance.workbookReloadCount, 0)
        XCTAssertEqual(performance.haplotypeModelRebuildCount, 0)
        XCTAssertEqual(performance.unrelatedRowReloadCount, 0)
        XCTAssertEqual(
            controller.testingLastEffectiveHaplotypeRefreshedKeys,
            [
                .init(
                    sample: fixture.samples[0],
                    locus: "MHC-A",
                    slot: .h1
                ),
            ]
        )
    }

    func testRetainedDemultiplexingSizeWarmSwitchesMeetReleaseFrameBudgets()
        throws
    {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[
                "LUNGFISH_RELEASE_PERFORMANCE_TEST"
            ] == "1",
            "Set LUNGFISH_RELEASE_PERFORMANCE_TEST=1 for the local release gate."
        )
        let fixture = GenotypeManualHaplotypeTask10Fixture(sampleCount: 52)
        let bundleURL = try makeTemporaryBundleURL(named: "ReleaseWarmSwitch")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 720),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = controller.view
        controller.view.frame = window.contentView?.bounds ?? .zero
        controller.configure(
            result: fixture.result(
                workflowMode: .haplotyped,
                bundleURL: bundleURL,
                haplotypeAnalysis: fixture.haplotypeAnalysis,
                genotypeCount: 120
            )
        )
        window.makeKeyAndOrderFront(nil)
        controller.testingApplyDisplayState(
            GenotypeResultDisplayState(summaryViewMode: .matrix)
        )
        controller.testingApplyDisplayState(
            GenotypeResultDisplayState(summaryViewMode: .outline)
        )
        settleVisiblePresentation(controller: controller, window: window)
        for index in 0..<20 {
            controller.testingApplyDisplayState(
                GenotypeResultDisplayState(
                    summaryViewMode: index.isMultiple(of: 2)
                        ? .matrix
                        : .outline
                )
            )
            settleVisiblePresentation(
                controller: controller,
                window: window
            )
        }
        controller.testingResetSynchronizedMiSeqPerformanceCounters()

        var samples: [TimeInterval] = []
        var matrixSamples: [TimeInterval] = []
        var outlineSamples: [TimeInterval] = []
        samples.reserveCapacity(240)
        for index in 0..<240 {
            let start = CFAbsoluteTimeGetCurrent()
            controller.testingApplyDisplayState(
                GenotypeResultDisplayState(
                    summaryViewMode: index.isMultiple(of: 2)
                        ? .matrix
                        : .outline
                )
            )
            settleVisiblePresentation(
                controller: controller,
                window: window
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            samples.append(elapsed)
            if index.isMultiple(of: 2) {
                matrixSamples.append(elapsed)
            } else {
                outlineSamples.append(elapsed)
            }
        }

        let p95 = percentile(samples, 0.95)
        let p99 = percentile(samples, 0.99)
        print(
            "Synchronized miSeq warm switch benchmark (seconds): "
                + "samples=\(samples.count), p95=\(p95), p99=\(p99), "
                + "matrix_p95=\(percentile(matrixSamples, 0.95)), "
                + "outline_p95=\(percentile(outlineSamples, 0.95))"
        )
        XCTAssertLessThanOrEqual(p95, 0.0167)
        XCTAssertLessThanOrEqual(p99, 0.0334)
    }

    private func settleVisiblePresentation(
        controller: GenotypeResultViewController,
        window: NSWindow
    ) {
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func testRepresentativeMatrixInteractionsMeetReleaseFrameBudgets()
        throws
    {
        let fixture = GenotypeManualHaplotypeTask10Fixture(sampleCount: 12)
        let baseline = try MatrixInteractionHarness(
            result: fixture.result(workflowMode: .genotypeOnly),
            sidecar: nil,
            benchmarksManualFeatures: false
        )
        let withBand = try MatrixInteractionHarness(
            result: fixture.result(workflowMode: .genotypeOnly),
            sidecar: fixture.sidecar,
            benchmarksManualFeatures: true
        )

        let baselineWarmUp = baseline.warmUp()
        let featureWarmUp = withBand.warmUp()
        for coverage in [baselineWarmUp, featureWarmUp] {
            XCTAssertEqual(coverage.expandedDisclosureCount, 10)
            XCTAssertEqual(coverage.collapsedDisclosureCount, 10)
            XCTAssertEqual(coverage.selectedComparisonSourceCount, 10)
            XCTAssertEqual(coverage.clearedComparisonSourceCount, 10)
        }

        let pairedSamples = baseline.measureRepresentativeInteractions(
            alongside: withBand
        )
        let baselineSamples = pairedSamples.primary
        let bandSamples = pairedSamples.secondary
        // A matrix without the manual feature has no equivalent disclosure,
        // hydrated-evidence, or selected-source comparison action. Keep their
        // absolute frame budgets, while applying the paired regression gate
        // to shared scrolling, reordering, and resizing interactions.
        let operations: [(
            name: String,
            band: [TimeInterval],
            baseline: [TimeInterval],
            enforcesRegression: Bool
        )] = [
            ("scroll", bandSamples.scroll, baselineSamples.scroll, true),
            ("reorder", bandSamples.reorder, baselineSamples.reorder, true),
            ("resize", bandSamples.resize, baselineSamples.resize, true),
            (
                "disclosure",
                bandSamples.disclosure,
                baselineSamples.disclosure,
                false
            ),
            ("evidence", bandSamples.evidence, baselineSamples.evidence, false),
            ("compare", bandSamples.compare, baselineSamples.compare, false),
        ]
        let bandAggregate = bandSamples.scroll
            + bandSamples.reorder
            + bandSamples.resize
            + bandSamples.disclosure
            + bandSamples.evidence
            + bandSamples.compare
        let baselineAggregate = baselineSamples.scroll
            + baselineSamples.reorder
            + baselineSamples.resize
            + baselineSamples.disclosure
            + baselineSamples.evidence
            + baselineSamples.compare
        let p95 = percentile(bandAggregate, 0.95)
        let p99 = percentile(bandAggregate, 0.99)
        let baselineP95 = percentile(baselineAggregate, 0.95)
        let aggregateRegression = baselineP95 > 0
            ? (p95 - baselineP95) / baselineP95
            : 0

        let operationSummaries: [String] = operations.map { operation in
                    let operationP95 = percentile(operation.band, 0.95)
                    let operationP99 = percentile(operation.band, 0.99)
                    let operationP50 = percentile(operation.band, 0.50)
                    let operationBaselineP95 = percentile(
                        operation.baseline,
                        0.95
                    )
                    let operationRegression = regression(
                        p95: operationP95,
                        baselineP95: operationBaselineP95
                    )
                    return
                        "\(operation.name)_samples=\(operation.band.count), "
                        + "\(operation.name)_p50=\(operationP50), "
                        + "\(operation.name)_p95=\(operationP95), "
                        + "\(operation.name)_p99=\(operationP99), "
                        + "\(operation.name)_no_band_p95="
                        + "\(operationBaselineP95), "
                        + "\(operation.name)_regression="
                        + "\(operationRegression), "
                        + "\(operation.name)_regression_gate="
                        + (
                            operation.enforcesRegression
                                ? "paired"
                                : "absolute-only-no-equivalent-baseline"
                        )
        }
        let aggregateSummary = "aggregate_p95=\(p95), aggregate_p99=\(p99), "
            + "no_band_p95=\(baselineP95), regression=\(aggregateRegression)"
        print(
            "Manual haplotype release benchmark (seconds): "
                + operationSummaries.joined(separator: ", ")
                + ", " + aggregateSummary
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
                if operation.enforcesRegression {
                    XCTAssertLessThanOrEqual(
                        operationRegression,
                        0.10,
                        "\(operation.name) p95 regressed more than 10% versus the otherwise-identical no-content matrix."
                    )
                }
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
            }
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

#if DEBUG
    func testDisclosureAndTypographyMeasurementIsSamplesTimesSeven() {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let matrix = GenotypeComparisonMatrixView(
            frame: NSRect(x: 0, y: 0, width: 1_440, height: 720)
        )
        matrix.configure(
            result: fixture.result(workflowMode: .genotypeOnly),
            sidecar: fixture.sidecar
        )
        matrix.testingResetManualHaplotypeAutoFitValueMeasurementCounts()

        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)

        XCTAssertEqual(
            matrix.testingManualHaplotypeAutoFitValueMeasurementCounts.values
                .reduce(0, +),
            fixture.samples.count
                * GenotypeManualHaplotypeLocus.allCases.count
        )
        XCTAssertTrue(
            matrix.testingManualHaplotypeAutoFitValueMeasurementCounts.values
                .allSatisfy {
                    $0 == GenotypeManualHaplotypeLocus.allCases.count
                }
        )

        matrix.testingSetManualHaplotypeBandDisclosureExpanded(false)
        matrix.testingResetManualHaplotypeAutoFitValueMeasurementCounts()
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        XCTAssertTrue(
            matrix.testingManualHaplotypeAutoFitValueMeasurementCounts.isEmpty,
            "Re-expansion must reuse settled assignment measurements."
        )

        matrix.testingResetManualHaplotypeAutoFitValueMeasurementCounts()
        matrix.testingSetManualHaplotypeBandTypographyScale(1.5)

        XCTAssertEqual(
            matrix.testingManualHaplotypeAutoFitValueMeasurementCounts.values
                .reduce(0, +),
            fixture.samples.count
                * GenotypeManualHaplotypeLocus.allCases.count
        )
    }

    func testSingleSaveMeasurementIsSevenPerChangedSample() {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let matrix = GenotypeComparisonMatrixView(
            frame: NSRect(x: 0, y: 0, width: 1_440, height: 720)
        )
        matrix.configure(
            result: fixture.result(workflowMode: .genotypeOnly),
            sidecar: fixture.sidecar
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.testingResetManualHaplotypeAutoFitValueMeasurementCounts()
        var changedAssignments = fixture.assignments
        changedAssignments[0].label = "Changed after save"

        matrix.applyManualHaplotypeAssignments(changedAssignments)

        XCTAssertEqual(
            matrix.testingManualHaplotypeAutoFitValueMeasurementCounts,
            [
                fixture.samples[0]:
                    GenotypeManualHaplotypeLocus.allCases.count,
            ]
        )
    }

    func testCollapsedSaveInvalidatesChangedSampleWidthBeforeReExpansion() {
        let fixture = GenotypeManualHaplotypeTask10Fixture(sampleCount: 4)
        let matrix = GenotypeComparisonMatrixView(
            frame: NSRect(x: 0, y: 0, width: 1_440, height: 720)
        )
        matrix.configure(
            result: fixture.result(workflowMode: .genotypeOnly),
            sidecar: fixture.sidecar
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        let originalWidth = matrix.testingSampleColumnWidth(
            sample: fixture.samples[0]
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(false)
        matrix.testingResetManualHaplotypeAutoFitValueMeasurementCounts()
        var changedAssignments = fixture.assignments
        changedAssignments[0].label = String(
            repeating: "A much longer saved haplotype label ",
            count: 4
        )

        matrix.applyManualHaplotypeAssignments(changedAssignments)
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)

        XCTAssertGreaterThan(
            matrix.testingSampleColumnWidth(sample: fixture.samples[0]),
            originalWidth
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeAutoFitValueMeasurementCounts,
            [
                fixture.samples[0]:
                    GenotypeManualHaplotypeLocus.allCases.count,
            ]
        )
    }

    func testScrollingPerformsNoAssignmentMeasurementOrComparisonWork() {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let matrix = GenotypeComparisonMatrixView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 420)
        )
        matrix.configure(
            result: fixture.result(workflowMode: .genotypeOnly),
            sidecar: fixture.sidecar
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        let comparison = makePerformanceComparisonModel(
            rowCount: 250,
            candidateCount: 12
        )
        comparison.selectSource("SOURCE_000")
        matrix.testingResetManualHaplotypeAutoFitValueMeasurementCounts()
        comparison.testingResetPerformanceCounters()

        for offset in stride(from: 0, through: 1_200, by: 40) {
            matrix.testingSetContentScrollOrigins(
                pinned: NSPoint(x: 0, y: 0),
                samples: NSPoint(x: CGFloat(offset), y: 0)
            )
            matrix.layoutSubtreeIfNeeded()
        }

        XCTAssertTrue(
            matrix.testingManualHaplotypeAutoFitValueMeasurementCounts.isEmpty
        )
        XCTAssertEqual(
            comparison.testingPerformanceCounters.sourceSnapshotBuildCount,
            0
        )
        XCTAssertEqual(
            comparison.testingPerformanceCounters
                .comparisonEvidenceRowInspectionCount,
            0
        )
    }

    func testComparisonSelectionIsLinearInVisibleRowsAndSearchDoesNotBuildSnapshots()
    {
        let rowCount = 500
        let comparison = makePerformanceComparisonModel(
            rowCount: rowCount,
            candidateCount: 100
        )
        comparison.testingResetPerformanceCounters()

        for query in ["source", "042", "complete", "not-present"] {
            comparison.updateSearch(query)
        }

        XCTAssertEqual(
            comparison.testingPerformanceCounters.sourceSnapshotBuildCount,
            0
        )
        XCTAssertEqual(
            comparison.testingPerformanceCounters
                .comparisonEvidenceRowInspectionCount,
            0
        )

        comparison.selectSource("SOURCE_042")

        XCTAssertEqual(
            comparison.testingPerformanceCounters.sourceSnapshotBuildCount,
            1
        )
        XCTAssertEqual(
            comparison.testingPerformanceCounters
                .comparisonEvidenceRowInspectionCount,
            rowCount * 2
        )
        XCTAssertEqual(comparison.comparisonRows.count, rowCount)
    }
#endif

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

    private func makeTemporaryBundleURL(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(name)-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try Data(#"{"analysis":"performance-test-fixture"}"#.utf8)
            .write(
                to: url.appendingPathComponent(
                    ONTGenotypeResultBundleManifest.filename
                )
            )
        return url
    }

#if DEBUG
    private func makePerformanceComparisonModel(
        rowCount: Int,
        candidateCount: Int
    ) -> GenotypeSampleComparisonModel {
        let rows = (0..<rowCount).map { index in
            GenotypeSampleEvidenceRow(
                id: .known(
                    locus: "MHC-A",
                    genotype: String(format: "ALLELE_%04d", index)
                ),
                allele: String(format: "Mafa-A1*%04d:01", index),
                readSupport: index + 1,
                indicators: [],
                accessibilityLabel: "Allele \(index)"
            )
        }
        let candidates = (0..<candidateCount).map { index in
            let sample = String(format: "SOURCE_%03d", index)
            return GenotypeManualHaplotypeEditorModel.CopyCandidate(
                sample: sample,
                assignedSlotCount: 14,
                completenessSummary: "14 of 14 assigned",
                compactSummary: "Complete",
                accessibilityLabel: "\(sample), complete"
            )
        }
        return GenotypeSampleComparisonModel(
            targetSample: "TARGET",
            targetRows: rows,
            candidates: candidates,
            rowsForSource: { _ in rows }
        )
    }
#endif
}

@MainActor
private final class MatrixInteractionHarness {
    struct WarmUpCoverage {
        var expandedDisclosureCount = 0
        var collapsedDisclosureCount = 0
        var selectedComparisonSourceCount = 0
        var clearedComparisonSourceCount = 0
    }

    private struct Views {
        let matrix: GenotypeComparisonMatrixView
        let table: NSTableView
        let clipView: NSClipView
    }

    private let views: Views
    private let primarySample: String
    private let secondarySample: String
    private let supportsDisclosure: Bool
    private var comparisonModel: GenotypeSampleComparisonModel?
    private var scrollSequence = 0
    private var reorderSequence = 0
    private var resizeSequence = 0
    private var disclosureSequence = 0
    private var comparisonSequence = 0

    init(
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar?,
        benchmarksManualFeatures: Bool
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
        let resolvedPrimarySample = result.calls.first?.sample ?? ""
        let resolvedSecondarySample = result.calls.first {
            $0.sample != resolvedPrimarySample
        }?.sample ?? resolvedPrimarySample
        views = Views(matrix: matrix, table: table, clipView: clipView)
        primarySample = resolvedPrimarySample
        secondarySample = resolvedSecondarySample
        let isGenotypeOnly = result.manifest.workflowMode == .genotypeOnly
        supportsDisclosure = benchmarksManualFeatures && isGenotypeOnly
        if isGenotypeOnly {
            let targetRows = matrix.visibleSampleEvidenceRows(
                sample: primarySample
            )
            let sourceRows = benchmarksManualFeatures
                ? matrix.visibleSampleEvidenceRows(sample: secondarySample)
                : []
            comparisonModel = GenotypeSampleComparisonModel(
                targetSample: primarySample,
                targetRows: targetRows,
                candidates: [
                    .init(
                        sample: secondarySample,
                        assignedSlotCount: 14,
                        completenessSummary: "14 of 14 assigned",
                        compactSummary: "Complete",
                        accessibilityLabel:
                            "\(secondarySample), 14 of 14 assigned"
                    ),
                ],
                rowsForSource: { _ in sourceRows }
            )
        }
    }

    func warmUp() -> WarmUpCoverage {
        var coverage = WarmUpCoverage()
        for _ in 0..<20 {
            performScroll()
            performReorder()
            performResize()
            if disclosureSequence.isMultiple(of: 2) {
                coverage.expandedDisclosureCount += 1
            } else {
                coverage.collapsedDisclosureCount += 1
            }
            performDisclosure()
            performEvidenceRefresh()
            if comparisonSequence.isMultiple(of: 2) {
                coverage.selectedComparisonSourceCount += 1
            } else {
                coverage.clearedComparisonSourceCount += 1
            }
            performSelectedSourceCompare()
        }
        return coverage
    }

    func measureRepresentativeInteractions(
        alongside other: MatrixInteractionHarness
    ) -> (
        primary: (
            scroll: [TimeInterval],
            reorder: [TimeInterval],
            resize: [TimeInterval],
            disclosure: [TimeInterval],
            evidence: [TimeInterval],
            compare: [TimeInterval]
        ),
        secondary: (
            scroll: [TimeInterval],
            reorder: [TimeInterval],
            resize: [TimeInterval],
            disclosure: [TimeInterval],
            evidence: [TimeInterval],
            compare: [TimeInterval]
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
        let disclosure = measurePaired(
            primary: performDisclosure,
            secondary: other.performDisclosure
        )
        let evidence = measurePaired(
            primary: performEvidenceRefresh,
            secondary: other.performEvidenceRefresh
        )
        let compare = measurePaired(
            primary: performSelectedSourceCompare,
            secondary: other.performSelectedSourceCompare
        )
        return (
            primary: (
                scroll: scroll.primary,
                reorder: reorder.primary,
                resize: resize.primary,
                disclosure: disclosure.primary,
                evidence: evidence.primary,
                compare: compare.primary
            ),
            secondary: (
                scroll: scroll.secondary,
                reorder: reorder.secondary,
                resize: resize.secondary,
                disclosure: disclosure.secondary,
                evidence: evidence.secondary,
                compare: compare.secondary
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
        let measurementCount = 240
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
        scrollSequence &+= 1
        let maximumX = max(
            0,
            views.table.bounds.width - views.clipView.bounds.width
        )
        let x = maximumX == 0
            ? 0
            : CGFloat((scrollSequence * 37) % max(1, Int(maximumX)))
        views.clipView.setBoundsOrigin(NSPoint(x: x, y: 0))
        views.table.enclosingScrollView?.reflectScrolledClipView(
            views.clipView
        )
        views.matrix.layoutSubtreeIfNeeded()
    }

    private func performReorder() {
        guard views.table.numberOfColumns > 2 else { return }
        let destination = reorderSequence.isMultiple(of: 2)
            ? 1
            : views.table.numberOfColumns - 1
        views.table.moveColumn(0, toColumn: destination)
        views.matrix.layoutSubtreeIfNeeded()
        reorderSequence &+= 1
    }

    private func performResize() {
        guard let column = views.table.tableColumns.first else { return }
        column.width = resizeSequence.isMultiple(of: 2) ? 106 : 114
        views.matrix.layoutSubtreeIfNeeded()
        resizeSequence &+= 1
    }

    private func performDisclosure() {
        guard supportsDisclosure else {
            views.matrix.layoutSubtreeIfNeeded()
            disclosureSequence &+= 1
            return
        }
        views.matrix.testingSetManualHaplotypeBandDisclosureExpanded(
            disclosureSequence.isMultiple(of: 2)
        )
        views.matrix.layoutSubtreeIfNeeded()
        disclosureSequence &+= 1
    }

    private func performEvidenceRefresh() {
        _ = views.matrix.visibleSampleEvidenceRows(sample: primarySample)
    }

    private func performSelectedSourceCompare() {
        if let comparisonModel {
            comparisonModel.selectSource(
                comparisonSequence.isMultiple(of: 2)
                    ? secondarySample
                    : nil
            )
        } else {
            _ = views.matrix.visibleSampleEvidenceRows(
                sample: secondarySample
            )
        }
        comparisonSequence &+= 1
    }

    private static func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
struct GenotypeManualHaplotypeTask10Fixture {
    let samples: [String]

    init(sampleCount: Int = 100) {
        samples = (0..<sampleCount).map {
            String(format: "SAMPLE_%03d", $0)
        }
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
        bundleURL requestedBundleURL: URL? = nil,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil,
        genotypeCount: Int? = nil
    ) -> ONTGenotypeResultBundleData {
        let genotypes: [String]
        if let genotypeCount {
            genotypes = (0..<genotypeCount).map { index in
                let locus = index.isMultiple(of: 2) ? "A1" : "DQB1"
                return String(
                    format: "%02d_Mafa_%@_%03d_01",
                    index % 20,
                    locus,
                    index
                )
            }
        } else {
            genotypes = [
                "01_Mafa_A1_001_01",
                "12_Mafa_B_001_01",
                "21_Mafa_DRB_001_01",
                "31_Mafa_DQA1_001_01",
                "41_Mafa_DQB1_001_01",
                "51_Mafa_DPA1_001_01",
                "61_Mafa_DPB1_001_01",
            ]
        }
        let retainedSampleTotalReads = genotypeCount == nil ? nil : 16_000
        let retainedSampleUniqueReads = genotypeCount == nil ? nil : 12_000
        let retainedSamplePercent = genotypeCount == nil ? nil : 75.0
        let retainedOverallInputReads = genotypeCount == nil
            ? nil
            : 16_000 * samples.count
        let retainedOverallUniqueReads = genotypeCount == nil
            ? nil
            : 12_000 * samples.count
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
                    sampleTotalReads: retainedSampleTotalReads,
                    sampleUniqueRetainedReads: retainedSampleUniqueReads,
                    sampleUniqueRetainedPercent: retainedSamplePercent,
                    overallInputReads: retainedOverallInputReads,
                    overallUniqueRetainedReads: retainedOverallUniqueReads,
                    overallUniqueRetainedPercent: retainedSamplePercent
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
                    sampleTotalReads: retainedSampleTotalReads,
                    sampleUniqueRetainedPercent: retainedSamplePercent,
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
            haplotypeAnalysis: haplotypeAnalysis,
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

    var haplotypeAnalysis: GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "performance.haplotype-definitions",
            definitionSetName: "Performance haplotype definitions",
            speciesName: "Test species",
            samples: samples.enumerated().map { index, sample in
                .init(sample: sample, calls: [
                    .init(
                        locus: "MHC-A",
                        sourceLocus: "Mafa-A",
                        haplotype1: "A\(index % 11)-H1",
                        haplotype2: "A\(index % 13)-H2",
                        status: .called,
                        matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: ["A1", "A2"]
                    ),
                    .init(
                        locus: "MHC-B",
                        sourceLocus: "Mafa-B",
                        haplotype1: "B\(index % 17)-H1",
                        haplotype2: "B\(index % 19)-H2",
                        status: .called,
                        matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: ["B1", "B2"]
                    ),
                ])
            }
        )
    }
}
