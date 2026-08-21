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

// Matrix cell styling, stress tests, and haplotyped MiSeq end-to-end flows
@MainActor
final class GenotypeResultViewportStylingAndMiSeqE2ETests: GenotypeResultViewportTestCase {
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


    func testCurrentWorkbookFallbackReloadAppliesAsyncResult() async {
        let bundleURL = URL(fileURLWithPath: "/tmp/current-workbook-async.lungfishgenotype")
        let original = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            stats: ONTGenotypeRunStats(totalInputReads: 10, retainedUniqueReads: 5)
        )
        let updated = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            stats: ONTGenotypeRunStats(totalInputReads: 20, retainedUniqueReads: 9)
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: original)
        controller.genotypeResultLoader = { _ in updated }

        controller.testingReloadCurrentWorkbookResult()
        for _ in 0..<20 where controller.testingResultTotalInputReads != 20 {
            await Task.yield()
        }

        XCTAssertEqual(controller.testingResultTotalInputReads, 20)
    }


    func testCurrentWorkbookFallbackReloadCancelPreservesDraftOpenedWhileLoadIsInFlight()
        async throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CurrentWorkbookReloadDraftCancel-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let original = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call],
            stats: ONTGenotypeRunStats(
                totalInputReads: 10,
                retainedUniqueReads: 5
            )
        )
        let updated = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call],
            stats: ONTGenotypeRunStats(
                totalInputReads: 20,
                retainedUniqueReads: 9
            )
        )
        let loader = DeferredGenotypeResultLoader()
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: original)
        controller.genotypeResultLoader = { url in
            await loader.load(url)
        }

        controller.testingReloadCurrentWorkbookResult()
        await loader.waitUntilStarted()
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        var promptCount = 0
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            transition in
            XCTAssertEqual(transition, .reload)
            promptCount += 1
            return .cancel
        }
        await loader.resume(returning: updated)
        for _ in 0..<100 where promptCount == 0 {
            await Task.yield()
        }
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(controller.testingResultTotalInputReads, 10)
        XCTAssertEqual(
            controller.testingManualHaplotypeEditorSample,
            "AnimalA"
        )
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
    }


    func testCurrentWorkbookFallbackReloadDiscardAppliesLoadedEligibilityChangeWithoutReloading()
        async throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CurrentWorkbookReloadEligibility-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let original = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call],
            stats: ONTGenotypeRunStats(
                totalInputReads: 10,
                retainedUniqueReads: 5
            )
        )
        let updated = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis(),
            stats: ONTGenotypeRunStats(
                totalInputReads: 20,
                retainedUniqueReads: 9
            )
        )
        let loader = DeferredGenotypeResultLoader()
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: original)
        controller.genotypeResultLoader = { url in
            await loader.load(url)
        }

        controller.testingReloadCurrentWorkbookResult()
        await loader.waitUntilStarted()
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        var promptCount = 0
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            transition in
            XCTAssertEqual(transition, .reload)
            promptCount += 1
            return .discard
        }
        await loader.resume(returning: updated)
        for _ in 0..<100
        where controller.testingResultTotalInputReads != 20 {
            await Task.yield()
        }
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(controller.testingResultTotalInputReads, 20)
        XCTAssertEqual(promptCount, 1)
        XCTAssertFalse(controller.testingManualHaplotypeEditorIsDirty)
        if case .eligible = controller.manualHaplotypeEligibility {
            XCTFail("The loaded haplotyped result must become ineligible.")
        }
        let invocationCount = await loader.currentInvocationCount()
        XCTAssertEqual(invocationCount, 1)
    }


    func testCurrentWorkbookFallbackReloadIgnoresCancelledStaleResult() async {
        let firstBundleURL = URL(fileURLWithPath: "/tmp/current-workbook-first.lungfishgenotype")
        let secondBundleURL = URL(fileURLWithPath: "/tmp/current-workbook-second.lungfishgenotype")
        let first = makeResult(bundleURL: firstBundleURL, samples: [], calls: [])
        let staleUpdate = makeResult(
            bundleURL: firstBundleURL,
            samples: [],
            calls: [],
            stats: ONTGenotypeRunStats(totalInputReads: 99, retainedUniqueReads: 50)
        )
        let replacement = makeResult(
            bundleURL: secondBundleURL,
            samples: [],
            calls: [],
            stats: ONTGenotypeRunStats(totalInputReads: 2, retainedUniqueReads: 1)
        )
        let loader = DeferredGenotypeResultLoader()
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: first)
        controller.genotypeResultLoader = { url in
            await loader.load(url)
        }

        controller.testingReloadCurrentWorkbookResult()
        await loader.waitUntilStarted()
        controller.configure(result: replacement)
        await loader.resume(returning: staleUpdate)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(controller.testingResultBundleURL, secondBundleURL.standardizedFileURL)
        XCTAssertEqual(controller.testingResultTotalInputReads, 2)
    }


    func testQueuedConfigurationImmediatelyInvalidatesInFlightWorkbookReload()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "QueuedConfigureInvalidatesReload-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBundleURL = root.appendingPathComponent(
            "first.lungfishgenotype",
            isDirectory: true
        )
        let secondBundleURL = root.appendingPathComponent(
            "second.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstBundleURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondBundleURL,
            withIntermediateDirectories: true
        )
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let first = makeResult(
            bundleURL: firstBundleURL,
            samples: [],
            calls: [call],
            stats: ONTGenotypeRunStats(
                totalInputReads: 1,
                retainedUniqueReads: 1
            )
        )
        let staleUpdate = makeResult(
            bundleURL: firstBundleURL,
            samples: [],
            calls: [call],
            stats: ONTGenotypeRunStats(
                totalInputReads: 99,
                retainedUniqueReads: 99
            )
        )
        let replacement = makeResult(
            bundleURL: secondBundleURL,
            samples: [],
            calls: [],
            stats: ONTGenotypeRunStats(
                totalInputReads: 2,
                retainedUniqueReads: 2
            )
        )
        let loader = DeferredGenotypeResultLoader()
        let decisionGate = ManualHaplotypeViewportDecisionGate()
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: first)
        controller.genotypeResultLoader = { url in
            await loader.load(url)
        }

        controller.testingReloadCurrentWorkbookResult()
        await loader.waitUntilStarted()
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            transition in
            XCTAssertEqual(transition, .eligibilityChange)
            return await decisionGate.wait()
        }

        controller.configure(result: replacement)
        await decisionGate.waitUntilPending()
        await loader.resume(returning: staleUpdate)
        await decisionGate.resume(with: .discard)
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(
            controller.testingResultBundleURL,
            secondBundleURL.standardizedFileURL
        )
        XCTAssertEqual(controller.testingResultTotalInputReads, 2)
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
        controller.addMatrixComment(GenotypeMatrixCommentEditRequest(
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

        controller.addMatrixComment(GenotypeMatrixCommentEditRequest(
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


    func testRapidTwentyDraftThresholdEditsUseOneCachedDerivedPassAndPreserveMatrixState() async throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeRetainedDemuxSizedResult())
        let matrix = controller.testingComparisonMatrix
        matrix.frame = NSRect(x: 0, y: 0, width: 1_200, height: 320)
        matrix.layoutSubtreeIfNeeded()
        matrix.testingSetSortDescriptor(key: "genotype", ascending: false)
        let selectedGenotype = try XCTUnwrap(
            matrix.testingVisibleRows.first {
                $0.sampleSupport.allSatisfy { $0.passedUniqueReads >= 20 }
            }?.genotype
        )
        matrix.testingSelectCell(genotype: selectedGenotype, sample: "LF2800")
        matrix.testingSetContentScrollOrigins(
            pinned: NSPoint(x: 0, y: 180),
            samples: NSPoint(x: 43, y: 180)
        )

        let expectedSelection = matrix.testingSelectedMatrixTargets
        let expectedSortKey = matrix.testingActiveSortDescriptorKey
        let expectedWidths = matrix.testingAllColumnWidths
        let expectedSamples = matrix.testingVisibleSampleNames
        let expectedAnchor = matrix.testingSemanticScrollAnchor
        let expectedRowOrder = matrix.testingVisibleRows.map(\.id)
        controller.testingResetProjectionPerformanceCounters()

        let scheduler = MatrixProjectionManualNumericScheduler()
        let viewModel = GenotypeResultDisplaySectionViewModel(
            numericFilterScheduler: scheduler,
            numericFilterLocale: Locale(identifier: "en_US"),
            numericFilterValidationAnnouncementPoster:
                AccessibilityAnnouncementPoster()
        )
        viewModel.onDisplayStateChanged = { controller.applyDisplayState($0) }
        for threshold in 1...20 {
            viewModel.updateMatrixMinimumReadsDraft(String(threshold))
        }

        scheduler.runPending()
        matrix.layoutSubtreeIfNeeded()
        await Task.yield()

        let aggregate = controller.testingProjectionPerformanceSnapshot
        let performance = aggregate.matrix
        XCTAssertEqual(performance.baseProjectionBuildCount, 1)
        XCTAssertEqual(performance.derivedProjectionPassCount, 1)
        XCTAssertEqual(performance.columnRebuildCount, 0)
        XCTAssertLessThanOrEqual(performance.pinnedFullReloadCount, 1)
        XCTAssertLessThanOrEqual(performance.sampleFullReloadCount, 1)
        XCTAssertLessThanOrEqual(performance.derivedProjectionMaximumSeconds, 0.5)
        XCTAssertEqual(performance.commitToVisibleCount, 1)
        XCTAssertLessThanOrEqual(performance.commitToVisibleTotalSeconds, 0.5)
        XCTAssertLessThanOrEqual(performance.commitToVisibleMaximumSeconds, 0.5)
        XCTAssertEqual(aggregate.anchorLensRebuildCount, 0)
        XCTAssertEqual(aggregate.consumerLensRebuildCount, 0)
        XCTAssertEqual(aggregate.cohortSummaryRebuildCount, 0)
        XCTAssertEqual(aggregate.layoutApplicationCount, 0)
        XCTAssertEqual(controller.testingDisplayState.matrixMinimumReads, 20)
        XCTAssertEqual(matrix.testingSelectedMatrixTargets, expectedSelection)
        XCTAssertEqual(matrix.testingActiveSortDescriptorKey, expectedSortKey)
        XCTAssertEqual(matrix.testingAllColumnWidths, expectedWidths)
        XCTAssertEqual(matrix.testingVisibleSampleNames, expectedSamples)
        XCTAssertEqual(matrix.testingSemanticScrollAnchor.rowID, expectedAnchor.rowID)
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.withinRowOffset,
            expectedAnchor.withinRowOffset,
            accuracy: 0.5
        )
        XCTAssertFalse(matrix.testingVisibleRows.contains {
            $0.sampleSupport.contains { $0.passedUniqueReads < 20 }
        })
        XCTAssertEqual(
            matrix.testingVisibleRows.map(\.id),
            expectedRowOrder.filter { id in
                matrix.testingVisibleRows.contains { $0.id == id }
            }
        )
        print(
            "Task6 52x120 Debug metrics: derived_total=\(performance.derivedProjectionTotalSeconds), "
                + "derived_max=\(performance.derivedProjectionMaximumSeconds), "
                + "visible_total=\(performance.commitToVisibleTotalSeconds), "
                + "visible_max=\(performance.commitToVisibleMaximumSeconds)"
        )
    }


    func testOneHundredFiftyColumnThresholdStressDoesNotRebuildColumnsOrLoseWidths() async throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeManySampleResult(sampleCount: 150))
        let matrix = controller.testingComparisonMatrix
        matrix.frame = NSRect(x: 0, y: 0, width: 1_200, height: 320)
        matrix.layoutSubtreeIfNeeded()
        matrix.testingSetSortDescriptor(key: "genotype", ascending: false)
        matrix.testingSelectCell(genotype: "12_M3_B_075_01", sample: "SAMPLE_149")
        matrix.testingSetContentScrollOrigins(
            pinned: NSPoint(x: 0, y: 0),
            samples: NSPoint(x: 197, y: 0)
        )
        let expectedWidths = matrix.testingAllColumnWidths
        let expectedSamples = matrix.testingVisibleSampleNames
        let expectedRows = matrix.testingVisibleRows.map(\.id)
        let expectedSelection = matrix.testingSelectedMatrixTargets
        let expectedSortKey = matrix.testingActiveSortDescriptorKey
        let expectedAnchor = matrix.testingSemanticScrollAnchor
        controller.testingResetProjectionPerformanceCounters()

        let scheduler = MatrixProjectionManualNumericScheduler()
        let viewModel = GenotypeResultDisplaySectionViewModel(
            numericFilterScheduler: scheduler,
            numericFilterLocale: Locale(identifier: "en_US"),
            numericFilterValidationAnnouncementPoster:
                AccessibilityAnnouncementPoster()
        )
        viewModel.onDisplayStateChanged = { controller.applyDisplayState($0) }
        for threshold in 1...20 {
            viewModel.updateMatrixMinimumReadsDraft(String(threshold))
        }

        scheduler.runPending()
        matrix.layoutSubtreeIfNeeded()
        await Task.yield()

        let aggregate = controller.testingProjectionPerformanceSnapshot
        let performance = aggregate.matrix
        XCTAssertEqual(performance.baseProjectionBuildCount, 1)
        XCTAssertEqual(performance.derivedProjectionPassCount, 1)
        XCTAssertEqual(performance.columnRebuildCount, 0)
        XCTAssertLessThanOrEqual(performance.pinnedFullReloadCount, 1)
        XCTAssertLessThanOrEqual(performance.sampleFullReloadCount, 1)
        XCTAssertLessThanOrEqual(performance.derivedProjectionMaximumSeconds, 0.5)
        XCTAssertEqual(performance.commitToVisibleCount, 1)
        XCTAssertLessThanOrEqual(performance.commitToVisibleTotalSeconds, 0.5)
        XCTAssertLessThanOrEqual(performance.commitToVisibleMaximumSeconds, 0.5)
        XCTAssertEqual(aggregate.anchorLensRebuildCount, 0)
        XCTAssertEqual(aggregate.consumerLensRebuildCount, 0)
        XCTAssertEqual(aggregate.cohortSummaryRebuildCount, 0)
        XCTAssertEqual(aggregate.layoutApplicationCount, 0)
        XCTAssertEqual(controller.testingDisplayState.matrixMinimumReads, 20)
        XCTAssertEqual(matrix.testingSampleColumnCount, 150)
        XCTAssertEqual(matrix.testingVisibleSampleNames, expectedSamples)
        XCTAssertEqual(matrix.testingAllColumnWidths, expectedWidths)
        XCTAssertEqual(matrix.testingVisibleRows.map(\.id), expectedRows)
        XCTAssertEqual(matrix.testingSelectedMatrixTargets, expectedSelection)
        XCTAssertEqual(matrix.testingActiveSortDescriptorKey, expectedSortKey)
        XCTAssertEqual(matrix.testingSemanticScrollAnchor.rowID, expectedAnchor.rowID)
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.withinRowOffset,
            expectedAnchor.withinRowOffset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.sampleHorizontalOrigin,
            expectedAnchor.sampleHorizontalOrigin,
            accuracy: 0.5
        )
        print(
            "Task6 150-column Debug metrics: derived_total=\(performance.derivedProjectionTotalSeconds), "
                + "derived_max=\(performance.derivedProjectionMaximumSeconds), "
                + "visible_total=\(performance.commitToVisibleTotalSeconds), "
                + "visible_max=\(performance.commitToVisibleMaximumSeconds)"
        )
    }


    func testRapidThresholdPipelineWithSearchAndManualVisibilityMeetsBudgetsWithoutMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeCompleteViewPipeline-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("provenance", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try GenotypeAnnotationStore(bundleURL: root, author: "benchmark-seed")
        try Data("workflow-provenance-sentinel\n".utf8).write(
            to: root.appendingPathComponent("provenance/workflow.json")
        )
        try Data("current-workbook-sentinel\n".utf8).write(
            to: root.appendingPathComponent("current.xlsx")
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

        let base = makeRetainedDemuxSizedResult()
        let result = makeResult(
            bundleURL: root,
            samples: base.samples,
            calls: base.calls,
            referenceMetadata: base.referenceMetadata
        )
        let before = try recursiveBytes()
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        let matrix = controller.testingComparisonMatrix
        matrix.frame = NSRect(x: 0, y: 0, width: 1_200, height: 320)
        matrix.layoutSubtreeIfNeeded()

        controller.testingSetQuickFilterSearchText("Mafa")
        controller.testingClickMatrixRowChiclet(
            genotype: "00_Mafa_A1_000_01"
        )
        controller.testingHideSelectedMatrixRows()
        controller.testingSelectMatrixColumn(sample: "LF2851")
        controller.testingHideSelectedMatrixColumns()
        XCTAssertEqual(controller.testingQuickSearchText, "Mafa")
        XCTAssertTrue(controller.testingMatrixVisibilityCapability.canResetVisibility)
        XCTAssertEqual(matrix.testingVisibleRows.count, 119)
        XCTAssertEqual(matrix.testingVisibleSampleNames.count, 51)

        controller.testingResetProjectionPerformanceCounters()
        let scheduler = MatrixProjectionManualNumericScheduler()
        let viewModel = GenotypeResultDisplaySectionViewModel(
            numericFilterScheduler: scheduler,
            numericFilterLocale: Locale(identifier: "en_US"),
            numericFilterValidationAnnouncementPoster:
                AccessibilityAnnouncementPoster()
        )
        viewModel.onDisplayStateChanged = { controller.applyDisplayState($0) }
        for threshold in 1...20 {
            viewModel.updateMatrixMinimumReadsDraft(String(threshold))
        }

        scheduler.runPending()
        matrix.layoutSubtreeIfNeeded()
        await Task.yield()

        let aggregate = controller.testingProjectionPerformanceSnapshot
        let performance = aggregate.matrix
        let enforcesReleaseBudget =
            ProcessInfo.processInfo.environment[
                "LUNGFISH_RELEASE_PERFORMANCE_TEST"
            ] == "1"
        let derivedCeiling: TimeInterval =
            enforcesReleaseBudget ? 0.050 : 0.500
        let visibleCeiling: TimeInterval =
            enforcesReleaseBudget ? 0.100 : 0.500
        XCTAssertEqual(performance.baseProjectionBuildCount, 1)
        XCTAssertEqual(performance.derivedProjectionPassCount, 1)
        XCTAssertLessThanOrEqual(
            performance.derivedProjectionMaximumSeconds,
            derivedCeiling
        )
        XCTAssertEqual(performance.commitToVisibleCount, 1)
        XCTAssertLessThanOrEqual(
            performance.commitToVisibleMaximumSeconds,
            visibleCeiling
        )
        XCTAssertEqual(performance.columnRebuildCount, 0)
        XCTAssertLessThanOrEqual(performance.pinnedFullReloadCount, 1)
        XCTAssertLessThanOrEqual(performance.sampleFullReloadCount, 1)
        XCTAssertEqual(aggregate.anchorLensRebuildCount, 0)
        XCTAssertEqual(aggregate.consumerLensRebuildCount, 0)
        XCTAssertEqual(aggregate.cohortSummaryRebuildCount, 0)
        XCTAssertEqual(aggregate.layoutApplicationCount, 0)
        XCTAssertEqual(controller.testingDisplayState.matrixMinimumReads, 20)
        XCTAssertEqual(controller.testingQuickSearchText, "Mafa")
        XCTAssertTrue(controller.testingMatrixVisibilityCapability.canResetVisibility)
        XCTAssertEqual(matrix.testingVisibleRows.count, 112)
        XCTAssertEqual(matrix.testingVisibleSampleNames.count, 51)
        XCTAssertEqual(try recursiveBytes(), before)
        XCTAssertFalse(controller.testingCurrentWorkbookNeedsRefresh)
        XCTAssertFalse(controller.testingCurrentWorkbookRequiresFullUpdate)
        print(
            "Complete pipeline \(enforcesReleaseBudget ? "Release" : "Debug") metrics: "
                + "derived_total=\(performance.derivedProjectionTotalSeconds), "
                + "derived_max=\(performance.derivedProjectionMaximumSeconds), "
                + "visible_total=\(performance.commitToVisibleTotalSeconds), "
                + "visible_max=\(performance.commitToVisibleMaximumSeconds)"
        )
    }


    func testRepresentativeSharedSearchStressUsesCachedIndexAndDoesNotMutateBundle() throws {
        func bundleBytes(at root: URL) throws -> [String: Data] {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else { return [:] }
            var bytes: [String: Data] = [:]
            for case let url as URL in enumerator {
                guard try url.resourceValues(
                    forKeys: [.isRegularFileKey]
                ).isRegularFile == true else { continue }
                bytes[url.path.replacingOccurrences(of: root.path + "/", with: "")] =
                    try Data(contentsOf: url)
            }
            return bytes
        }

        func exercise(
            base: ONTGenotypeResultBundleData,
            exactSample: String,
            equivalentSampleSubstring: String,
            alleleQuery: String
        ) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("GenotypeSearchStress-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bundleURL = root.appendingPathComponent(
                "stress.lungfishgenotype",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: bundleURL.appendingPathComponent("artifacts", isDirectory: true),
                withIntermediateDirectories: true
            )
            try ONTGenotypeResultBundleData.writeAnnotationSidecar(
                .empty(generatedAt: "2026-07-25T00:00:00Z"),
                forBundleAt: bundleURL
            )
            try Data("audit-sentinel\n".utf8).write(
                to: bundleURL.appendingPathComponent("audit.ndjson")
            )
            try Data([0x01, 0x02, 0x03]).write(
                to: bundleURL.appendingPathComponent("artifacts/scientific.bin")
            )
            let result = makeResult(
                bundleURL: bundleURL,
                samples: base.samples,
                calls: base.calls,
                referenceMetadata: base.referenceMetadata
            )
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: result)
            let matrix = controller.testingComparisonMatrix
            controller.testingResetProjectionPerformanceCounters()
            controller.testingResetSearchPerformanceCounters()
            let before = try bundleBytes(at: bundleURL)

            controller.testingSetQuickFilterSearchText(exactSample)
            controller.testingSetQuickFilterSearchText(exactSample)
            controller.testingSetQuickFilterSearchText(equivalentSampleSubstring)
            XCTAssertEqual(
                controller.testingVisibleMatrixSamples,
                [exactSample]
            )
            controller.testingSetQuickFilterSearchText(alleleQuery)

            let performance = controller.testingProjectionPerformanceSnapshot.matrix
            XCTAssertEqual(controller.testingSearchIndexBuildCount, 1)
            XCTAssertEqual(controller.testingSearchQueryCount, 3)
            XCTAssertEqual(performance.baseProjectionBuildCount, 1)
            XCTAssertEqual(performance.derivedProjectionPassCount, 0)
            XCTAssertEqual(performance.columnRebuildCount, 2)
            XCTAssertLessThanOrEqual(performance.pinnedFullReloadCount, 4)
            XCTAssertLessThanOrEqual(performance.sampleFullReloadCount, 4)
            XCTAssertTrue(
                controller.testingVisibleGenotypes.contains {
                    $0.localizedCaseInsensitiveContains(alleleQuery)
                }
            )
            XCTAssertEqual(try bundleBytes(at: bundleURL), before)
            XCTAssertFalse(matrix.testingVisibleRows.isEmpty)
        }

        try exercise(
            base: makeRetainedDemuxSizedResult(),
            exactSample: "LF2800",
            equivalentSampleSubstring: "2800",
            alleleQuery: "00_Mafa_A1_000_01"
        )
        try exercise(
            base: makeManySampleResult(sampleCount: 150),
            exactSample: "SAMPLE_149",
            equivalentSampleSubstring: "149",
            alleleQuery: "12_M3_B_075_01"
        )
    }


    func testCandidateTintOnlyChangeRedrawsWithoutBaseOrDerivedInvalidation() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(
                    id: "tint-only",
                    name: "Mafa-A1*900:01_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: "tint-only",
                    sample: "AnimalA",
                    reads: 7
                ),
            ]
        ))
        let rowID = GenotypeCandidateMatrixRowID.candidate(stableClusterID: "tint-only")
        let originalTint = matrix.testingBackgroundColor(
            rowID: rowID,
            column: .alleleName
        )
        matrix.testingResetProjectionPerformanceCounters()
        var state = GenotypeResultDisplayState()
        var settings = ONTMHCCandidateDisplaySettings.default
        settings.tints[.singletonNovel] = AnnotationColor(hex: "#123456")!
        state.mhcCandidateDisplaySettings = settings

        matrix.applyDisplayState(state)

        let performance = matrix.testingProjectionPerformanceSnapshot
        XCTAssertEqual(performance.baseProjectionBuildCount, 1)
        XCTAssertEqual(performance.derivedProjectionPassCount, 0)
        XCTAssertEqual(performance.columnRebuildCount, 0)
        XCTAssertEqual(performance.pinnedFullReloadCount, 0)
        XCTAssertEqual(performance.sampleFullReloadCount, 0)
        XCTAssertGreaterThan(matrix.testingPartialReloadCount, 0)
        XCTAssertNotEqual(
            matrix.testingBackgroundColor(rowID: rowID, column: .alleleName),
            originalTint
        )
    }


    func testCombinedCandidateVisibilityAndTintTransitionRedrawsSurvivingRenderedCell() throws {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(
                    id: "shared",
                    name: "Mafa-A1*900:01_nov",
                    classification: .novel,
                    support: .shared,
                    samples: ["AnimalA", "AnimalB"]
                ),
                makeCandidate(
                    id: "singleton",
                    name: "Mafa-A1*901:01_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: "shared",
                    sample: "AnimalA",
                    reads: 7
                ),
                makeCandidateObservation(
                    cluster: "shared",
                    sample: "AnimalB",
                    reads: 8
                ),
                makeCandidateObservation(
                    cluster: "singleton",
                    sample: "AnimalA",
                    reads: 6
                ),
            ]
        )
        let sharedID = GenotypeCandidateMatrixRowID.candidate(
            stableClusterID: "shared"
        )
        let replacement = AnnotationColor(hex: "#123456")!

        func assertCombinedTransition(
            _ apply: (GenotypeComparisonMatrixView, ONTMHCCandidateDisplaySettings) -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let matrix = GenotypeComparisonMatrixView()
            matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 240)
            matrix.configure(result: result)
            matrix.layoutSubtreeIfNeeded()
            let before = try XCTUnwrap(
                matrix.testingRenderedPinnedCellBackgroundColor(
                    rowID: sharedID,
                    column: .alleleName
                ),
                file: file,
                line: line
            )
            matrix.testingResetProjectionPerformanceCounters()
            var settings = ONTMHCCandidateDisplaySettings.default
            settings.showSingletonCandidates = false
            settings.tints[.sharedNovel] = replacement

            apply(matrix, settings)

            let after = try XCTUnwrap(
                matrix.testingRenderedPinnedCellBackgroundColor(
                    rowID: sharedID,
                    column: .alleleName
                )?.usingColorSpace(.deviceRGB),
                file: file,
                line: line
            )
            let expected = try XCTUnwrap(
                matrix.testingBackgroundColor(
                    rowID: sharedID,
                    column: .alleleName
                )?.usingColorSpace(.deviceRGB),
                file: file,
                line: line
            )
            XCTAssertNotEqual(after, before, file: file, line: line)
            XCTAssertEqual(
                Double(after.redComponent),
                Double(expected.redComponent),
                accuracy: 0.000_001,
                file: file,
                line: line
            )
            XCTAssertEqual(
                Double(after.greenComponent),
                Double(expected.greenComponent),
                accuracy: 0.000_001,
                file: file,
                line: line
            )
            XCTAssertEqual(
                Double(after.blueComponent),
                Double(expected.blueComponent),
                accuracy: 0.000_001,
                file: file,
                line: line
            )
            XCTAssertFalse(
                matrix.testingVisibleRows.contains {
                    $0.stableClusterID == "singleton"
                },
                file: file,
                line: line
            )
            XCTAssertGreaterThan(
                matrix.testingPartialReloadCount,
                0,
                file: file,
                line: line
            )
        }

        try assertCombinedTransition { matrix, settings in
            matrix.applyDisplayState(.init(
                mhcCandidateDisplaySettings: settings
            ))
        }
        try assertCombinedTransition { matrix, settings in
            var sidecar = GenotypeAnnotationSidecar.empty(
                generatedAt: "2026-07-25T00:00:00Z"
            )
            sidecar.settings.mhcCandidateDisplay = settings
            matrix.applyAnnotationSidecar(sidecar)
        }
    }


    func testSidecarVisibilityAndStyleReplacementRedrawsSurvivingRenderedCell() throws {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(
                    id: "shared",
                    name: "Mafa-A1*900:01_nov",
                    classification: .novel,
                    support: .shared,
                    samples: ["AnimalA", "AnimalB"]
                ),
                makeCandidate(
                    id: "singleton",
                    name: "Mafa-A1*901:01_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: "shared",
                    sample: "AnimalA",
                    reads: 7
                ),
                makeCandidateObservation(
                    cluster: "shared",
                    sample: "AnimalB",
                    reads: 8
                ),
                makeCandidateObservation(
                    cluster: "singleton",
                    sample: "AnimalA",
                    reads: 6
                ),
            ]
        )
        let sharedTarget = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: "Mafa-A1*900:01_nov",
            stableClusterID: "shared"
        )
        let sharedID = GenotypeCandidateMatrixRowID.candidate(
            stableClusterID: "shared"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-25T00:00:00Z"
        )
        sidecar.matrixStyles = [
            .init(
                target: sharedTarget,
                style: .init(fillColor: "#AA0000"),
                author: "test",
                timestamp: "2026-07-25T00:00:00Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 240)
        matrix.configure(result: result, sidecar: sidecar)
        matrix.layoutSubtreeIfNeeded()
        let before = try XCTUnwrap(
            matrix.testingRenderedPinnedCellBackgroundColor(
                rowID: sharedID,
                column: .alleleName
            )
        )
        matrix.testingResetProjectionPerformanceCounters()
        sidecar.settings.mhcCandidateDisplay.showSingletonCandidates = false
        sidecar.matrixStyles = [
            .init(
                target: sharedTarget,
                style: .init(fillColor: "#00AA00"),
                author: "test",
                timestamp: "2026-07-25T00:01:00Z"
            ),
        ]

        matrix.applyAnnotationSidecar(sidecar)

        let after = try XCTUnwrap(
            matrix.testingRenderedPinnedCellBackgroundColor(
                rowID: sharedID,
                column: .alleleName
            )?.usingColorSpace(.deviceRGB)
        )
        let expected = try XCTUnwrap(
            matrix.testingBackgroundColor(
                rowID: sharedID,
                column: .alleleName
            )?.usingColorSpace(.deviceRGB)
        )
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(
            Double(after.greenComponent),
            Double(expected.greenComponent),
            accuracy: 0.000_001
        )
        XCTAssertFalse(matrix.testingVisibleRows.contains {
            $0.stableClusterID == "singleton"
        })
        XCTAssertGreaterThan(matrix.testingPartialReloadCount, 0)
    }


    func testExplicitCandidateSettingsOverrideSidecarVisibilityAndRebuildBaseProjection() {
        let known = makeCall(
            sample: "AnimalA",
            genotype: "Mafa-A1*001:01",
            reads: 20
        )
        let result = makeCandidateResult(
            calls: [known],
            candidates: [
                makeCandidate(
                    id: "candidate",
                    name: "Mafa-A1*900:01_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: "candidate",
                    sample: "AnimalA",
                    reads: 7
                ),
            ]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-25T00:00:00Z"
        )
        sidecar.settings.mhcCandidateDisplay = .init(showKnown: false)
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result, sidecar: sidecar)
        XCTAssertFalse(matrix.testingVisibleGenotypes.contains(known.genotype))
        matrix.testingResetProjectionPerformanceCounters()

        matrix.applyDisplayState(.init(
            mhcCandidateDisplaySettings: .init(showKnown: false)
        ))

        XCTAssertEqual(
            matrix.testingProjectionPerformanceSnapshot.baseProjectionBuildCount,
            1
        )
        XCTAssertEqual(
            matrix.testingProjectionPerformanceSnapshot.derivedProjectionPassCount,
            0
        )

        matrix.applyDisplayState(.init(
            mhcCandidateDisplaySettings: .default
        ))

        XCTAssertTrue(matrix.testingVisibleGenotypes.contains(known.genotype))
        XCTAssertEqual(
            matrix.testingProjectionPerformanceSnapshot.baseProjectionBuildCount,
            2
        )
        XCTAssertEqual(
            matrix.testingProjectionPerformanceSnapshot.derivedProjectionPassCount,
            1
        )
    }


    func testHiddenTopScrollRowFallsForwardToNearestSurvivingStableRow() {
        let matrix = makeManyRowComparisonMatrix(sampleCount: 20)
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        matrix.layoutSubtreeIfNeeded()
        let oldRows = matrix.testingVisibleRows
        let targetRow = 10
        matrix.testingSetContentScrollOrigins(
            pinned: NSPoint(
                x: 0,
                y: CGFloat(targetRow) * matrix.testingMatrixRowHeight + 3
            ),
            samples: NSPoint(
                x: 29,
                y: CGFloat(targetRow) * matrix.testingMatrixRowHeight + 3
            )
        )
        let oldAnchor = matrix.testingSemanticScrollAnchor
        let oldAnchorIndex = oldRows.firstIndex { $0.id == oldAnchor.rowID }
        let expected = oldAnchorIndex.flatMap { index in
            oldRows.dropFirst(index + 1).first {
                $0.sampleSupport.contains { $0.passedUniqueReads >= 140 }
            }
        }

        matrix.applyDisplayState(.init(matrixMinimumReads: 140))

        let nextAnchor = matrix.testingSemanticScrollAnchor
        XCTAssertEqual(nextAnchor.rowID, expected?.id)
        XCTAssertEqual(nextAnchor.withinRowOffset, oldAnchor.withinRowOffset, accuracy: 0.5)
        XCTAssertEqual(nextAnchor.sampleHorizontalOrigin, 29, accuracy: 0.5)
    }


    func testProjectionRowDiffSuppressesTransientSelectionCallbacksAndRestoresThemAfterward() {
        let keep = makeCall(
            sample: "AnimalA",
            genotype: "Mafa-A1*001:01",
            reads: 100
        )
        let drop = makeCall(
            sample: "AnimalA",
            genotype: "Mafa-A1*002:01",
            reads: 1
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [keep, drop]
        ))
        var selections: [[GenotypeAnnotationSidecar.MatrixTarget]] = []
        var clearCount = 0
        matrix.onMatrixTargetsSelected = { selections.append($0) }
        matrix.onSharedCallSelected = { _, _, targets in
            selections.append(targets)
        }
        matrix.onSelectionCleared = { clearCount += 1 }
        matrix.testingSelectCell(
            genotype: keep.genotype,
            sample: keep.sample
        )

        matrix.applyDisplayState(.init(matrixMinimumReads: 20))

        XCTAssertEqual(clearCount, 0)
        XCTAssertEqual(selections.count, 2)
        XCTAssertEqual(
            matrix.testingSelectedMatrixTargets,
            [.cell(
                locus: keep.locusGroup,
                genotype: keep.genotype,
                sample: keep.sample,
                stableClusterID: nil
            )]
        )
        XCTAssertFalse(matrix.testingVisibleGenotypes.contains(drop.genotype))

        matrix.testingSelectCell(
            genotype: keep.genotype,
            sample: keep.sample
        )

        XCTAssertEqual(clearCount, 0)
        XCTAssertEqual(
            selections.count,
            3,
            "Selection callbacks must resume after the row-diff transaction."
        )
    }


    func testMatrixOnlyThresholdChangeSkipsAnchorConsumerAndLayoutRebuilds() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(
                sample: "AnimalA",
                genotype: "Mafa-A1*001:01",
                reads: 50
            )]
        ))
        controller.testingResetProjectionPerformanceCounters()

        controller.applyDisplayState(.init(matrixMinimumReads: 20))

        let performance = controller.testingProjectionPerformanceSnapshot
        XCTAssertEqual(performance.matrix.baseProjectionBuildCount, 1)
        XCTAssertEqual(performance.matrix.derivedProjectionPassCount, 1)
        XCTAssertEqual(performance.anchorLensRebuildCount, 0)
        XCTAssertEqual(performance.consumerLensRebuildCount, 0)
        XCTAssertEqual(performance.cohortSummaryRebuildCount, 0)
        XCTAssertEqual(performance.layoutApplicationCount, 0)
    }


    func testCohortFlagThresholdRebuildsOnlyCohortSummary() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(
                sample: "AnimalA",
                genotype: "Mafa-A1*001:01",
                reads: 50
            )]
        ))
        controller.testingResetProjectionPerformanceCounters()
        var state = controller.testingDisplayState
        state.cohortFlagThreshold = 7_500

        controller.applyDisplayState(state)

        let performance = controller.testingProjectionPerformanceSnapshot
        XCTAssertEqual(performance.matrix.derivedProjectionPassCount, 0)
        XCTAssertEqual(performance.anchorLensRebuildCount, 0)
        XCTAssertEqual(performance.consumerLensRebuildCount, 0)
        XCTAssertEqual(performance.cohortSummaryRebuildCount, 1)
        XCTAssertEqual(performance.layoutApplicationCount, 0)
    }


    func testLensTransitionAppliesLayoutExactlyOnce() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [],
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))
        controller.testingResetProjectionPerformanceCounters()
        var state = GenotypeResultDisplayState()
        state.viewportLens = .review

        controller.applyDisplayState(state)

        XCTAssertEqual(
            controller.testingProjectionPerformanceSnapshot.layoutApplicationCount,
            1
        )
    }


    func testCallOverridePreservesUnresolvedReviewStatusAndOutlineValue() throws {
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
        XCTAssertEqual(evidence.status, .noHaplotype)
        XCTAssertFalse(evidence.errorExplanation.isEmpty)
        XCTAssertFalse(evidence.isHomozygous)

        let mhcBSlot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })
        XCTAssertEqual(mhcBSlot.h1.testingLabel, "M3B")
        XCTAssertEqual(mhcBSlot.h2.testingLabel, "M2B")
    }


    func testHaplotypedMiSeqUsesExactlyTwoPresentationSegmentsAndBuildsComparisonMatrixLazily()
        throws
    {
        let known = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_KNOWN",
            reads: 42
        )
        let candidate = makeCandidate(
            id: "candidate-a",
            name: "Mafa-A1*001:01_1nt_nov",
            classification: .novel,
            support: .singleton,
            samples: ["AnimalA"]
        )
        let result = makeCandidateResult(
            calls: [known],
            candidates: [candidate],
            observations: [
                makeCandidateObservation(
                    cluster: candidate.stableClusterID,
                    sample: "AnimalA",
                    reads: 7
                ),
            ],
            kind: .miSeqAmpliconMHCGenotype,
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis(
                sample: "AnimalA"
            )
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        let selector = try XCTUnwrap(
            controller.view.firstDescendant(ofType: NSSegmentedControl.self)
        )
        let matrix = try XCTUnwrap(
            controller.view.firstDescendant(
                ofType: GenotypeComparisonMatrixView.self
            )
        )
        let definitionMatrix = try XCTUnwrap(
            controller.view.firstDescendant(
                ofType: GenotypeHaplotypeDefinitionMatrixView.self
            )
        )

        XCTAssertEqual(
            (0 ..< selector.segmentCount).map {
                selector.label(forSegment: $0) ?? ""
            },
            ["Haplotype Calls", "Genotype Matrix"]
        )
        XCTAssertEqual(selector.selectedSegment, 0)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .outline)
        XCTAssertEqual(
            matrix.testingProjectionPerformanceSnapshot.baseProjectionBuildCount,
            0,
            "Opening Haplotype Calls must not configure the genotype matrix."
        )
        let definitionMatrixConfigurationCount =
            definitionMatrix.testingConfigurationCount
        XCTAssertTrue(matrix.isHidden)
        XCTAssertTrue(definitionMatrix.isHidden)

        selector.selectedSegment = 1
        XCTAssertTrue(
            selector.sendAction(selector.action, to: selector.target)
        )

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(selector.selectedSegment, 1)
        XCTAssertFalse(matrix.isHidden)
        XCTAssertTrue(definitionMatrix.isHidden)
        XCTAssertEqual(
            matrix.testingProjectionPerformanceSnapshot.baseProjectionBuildCount,
            1
        )
        XCTAssertEqual(
            definitionMatrix.testingConfigurationCount,
            definitionMatrixConfigurationCount,
            "Genotype Matrix must not configure hidden diagnostic-definition rows."
        )
        XCTAssertTrue(
            definitionMatrix.testingRenderedRows.isEmpty,
            "Applicable miSeq must never build diagnostic-definition rows."
        )
        let knownRow = try XCTUnwrap(
            matrix.testingVisibleRows.first { $0.genotype == known.genotype }
        )
        XCTAssertEqual(
            knownRow.support(for: "AnimalA")?.passedUniqueReads,
            42
        )
        let candidateRow = try XCTUnwrap(
            matrix.testingVisibleRows.first {
                $0.stableClusterID == candidate.stableClusterID
            }
        )
        XCTAssertEqual(
            candidateRow.support(for: "AnimalA")?.passedUniqueReads,
            7
        )
    }


    func testBeta19ONTSampleBundleMiSeqResultUsesTwoPresentationSegments() throws {
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_KNOWN",
            reads: 42
        )
        let manifest = ONTGenotypeResultBundleManifest(
            kind: "ont-barcode-genotype",
            workflowKind: nil,
            workflowMode: nil,
            outputName: "legacy-miseq",
            analysisName: "Legacy miSeq",
            primaryWorkbookPath: "legacy-miseq.xlsx",
            longSummaryCSVPath: "legacy-miseq.retained-demux-genotypes.csv",
            sampleSummaryCSVPath: "legacy-miseq.retained-demux-samples.csv",
            statsJSONPath: "legacy-miseq.retained-demux-stats.json",
            provenancePath: ".lungfish-provenance.json",
            haplotypeDefinitionSetID: "mcm-mhc-miseq-primary-20260620",
            haplotypeAssayID: "MHC-exon2-miSeq"
        )
        let result = makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [call]
            )],
            calls: [call],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis(
                sample: "AnimalA"
            ),
            manifest: manifest
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        XCTAssertEqual(
            controller.testingLensControlLabels,
            ["Haplotype Calls", "Genotype Matrix"]
        )
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .outline)
    }


    func testHaplotypedMiSeqCandidateCellSelectionRetainsDetailsAndEvidence()
        throws
    {
        let candidate = makeCandidate(
            id: "candidate-a",
            name: "Mafa-A1*001:01_1nt_nov",
            classification: .novel,
            support: .singleton,
            samples: ["AnimalA"]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeCandidateResult(
            calls: [],
            candidates: [candidate],
            observations: [
                makeCandidateObservation(
                    cluster: candidate.stableClusterID,
                    sample: "AnimalA",
                    reads: 7
                ),
            ],
            kind: .miSeqAmpliconMHCGenotype,
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis(
                sample: "AnimalA"
            )
        ))
        controller.applyDisplayState(.init(
            viewportLens: .summary,
            summaryViewMode: .matrix
        ))

        controller.testingSelectCandidateCell(
            stableClusterID: candidate.stableClusterID,
            sample: "AnimalA"
        )

        XCTAssertEqual(
            controller.testingSelectedCandidateStableClusterID,
            candidate.stableClusterID
        )
        let details = Dictionary(
            uniqueKeysWithValues:
                controller.testingCurrentSelectionDetailRows
        )
        XCTAssertEqual(details["Stable Cluster ID"], candidate.stableClusterID)
        XCTAssertEqual(details["Selected Sample"], "AnimalA")
        XCTAssertEqual(details["Selected Sample Reads"], "7")
        XCTAssertEqual(
            controller.testingCandidateSelectionCallbackCounts,
            .init(known: 0, candidate: 1)
        )
        XCTAssertEqual(controller.testingCandidateAlleleDetailMountCount, 1)
        XCTAssertFalse(controller.testingCurrentSelectionMatrixTargets.isEmpty)
    }


    func testHaplotypedMiSeqInspectorAndViewportShareSummaryModeWithoutFeedbackLoops()
        throws
    {
        let result = makeResult(
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        let selector = try XCTUnwrap(
            controller.view.firstDescendant(ofType: NSSegmentedControl.self)
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(
            isAvailable: true,
            state: controller.testingDisplayState,
            hasHaplotypingResult: true,
            isGenotypeOnlyResult: false
        )
        viewModel.updateMHCCandidatePresentation(from: result)
        viewModel.updateDisplayState(.init(
            viewportLens: .audit,
            summaryViewMode: .matrix
        ))
        XCTAssertEqual(viewModel.displayState.viewportLens, .summary)
        XCTAssertEqual(viewModel.displayState.summaryViewMode, .outline)
        var viewportPublications = 0
        var inspectorPublications = 0
        controller.onDisplayStateChanged = { state in
            viewportPublications += 1
            viewModel.updateDisplayState(state)
        }
        viewModel.onDisplayStateChanged = { state in
            inspectorPublications += 1
            controller.applyDisplayState(state)
        }

        viewModel.setSummaryViewMode(.matrix)

        XCTAssertEqual(inspectorPublications, 1)
        XCTAssertEqual(viewportPublications, 0)
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(selector.selectedSegment, 1)

        selector.selectedSegment = 0
        XCTAssertTrue(
            selector.sendAction(selector.action, to: selector.target)
        )

        XCTAssertEqual(viewportPublications, 1)
        XCTAssertEqual(inspectorPublications, 1)
        XCTAssertEqual(viewModel.displayState.summaryViewMode, .outline)
        XCTAssertEqual(viewModel.displayState.viewportLens, .summary)
    }


    func testHaplotypedMiSeqRestoresLegacyPreferencePerBundleWithoutLeakage()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HaplotypedMiSeqPresentationBundles-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent(
            "first.lungfishgenotype",
            isDirectory: true
        )
        let secondURL = root.appendingPathComponent(
            "second.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondURL,
            withIntermediateDirectories: true
        )
        var firstSidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-08-04T00:00:00Z"
        )
        firstSidecar.settings.preferredSummaryViewMode =
            GenotypeSummaryViewMode.matrix.rawValue
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            firstSidecar,
            forBundleAt: firstURL
        )
        let analysis = makeUsableHaplotypedMiSeqAnalysis()
        let first = makeResult(
            bundleURL: firstURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: analysis
        )
        let second = makeResult(
            bundleURL: secondURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: analysis
        )
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: first)
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)

        controller.configure(result: second)
        XCTAssertEqual(controller.testingSummaryViewMode, .outline)
        var state = controller.testingDisplayState
        state.summaryViewMode = .matrix
        controller.applyDisplayState(state)
        XCTAssertEqual(
            try GenotypeAnnotationStore(
                bundleURL: secondURL,
                author: "test",
                seedBuiltInSmartCohorts: true
            ).sidecar.settings.preferredSummaryViewMode,
            GenotypeSummaryViewMode.matrix.rawValue
        )

        controller.configure(result: first)
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
    }


    func testHaplotypedMiSeqNormalizesStaleLensAndDefinitionsIngressToCalls()
        throws
    {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        ))

        for lens in [GenotypeResultViewportLens.review, .audit] {
            controller.applyDisplayState(.init(
                viewportLens: lens,
                summaryViewMode: .matrix
            ))
            XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
            XCTAssertEqual(controller.testingSummaryViewMode, .outline)
        }

        controller.applyDisplayState(.init(summaryViewMode: .matrix))
        NotificationCenter.default.post(
            name: .genotypeResultOpenHaplotypeDefinitions,
            object: nil
        )

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .outline)
        let selector = try XCTUnwrap(
            controller.view.firstDescendant(ofType: NSSegmentedControl.self)
        )
        XCTAssertEqual(selector.selectedSegment, 0)
    }


    func testHaplotypedMiSeqAICompletionReplacesActiveLegacyAuditWithCalls()
        throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HaplotypedMiSeqAIIngress-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call]
        ))
        controller.testingSelectLens(.audit)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "audit")

        controller.applyAIHaplotypingCompleted(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        ))

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .outline)
        let selector = try XCTUnwrap(
            controller.view.firstDescendant(ofType: NSSegmentedControl.self)
        )
        XCTAssertEqual(
            (0 ..< selector.segmentCount).map {
                selector.label(forSegment: $0) ?? ""
            },
            ["Haplotype Calls", "Genotype Matrix"]
        )
        XCTAssertEqual(selector.selectedSegment, 0)
    }


    func testHaplotypedMiSeqCallEvidenceAndReviewKeyboardCommandsStayInCalls()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HaplotypedMiSeqReviewIngress-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "result.lungfishgenotype",
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
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        ))

        controller.testingSelectCellEvidence(
            animalId: "AnimalA",
            locus: "MHC-A"
        )

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .outline)
        XCTAssertFalse(controller.testingCallEvidencePaneHidden)
        XCTAssertEqual(controller.testingCurrentCallEvidenceSample, "AnimalA")
        XCTAssertFalse(controller.testingSampleDetailRows(sample: "AnimalA").isEmpty)
        let flag = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "F",
            charactersIgnoringModifiers: "F",
            isARepeat: false,
            keyCode: 3
        ))

        XCTAssertTrue(controller.performKeyEquivalent(with: flag))
        let sidecar = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "test",
            seedBuiltInSmartCohorts: true
        ).sidecar
        XCTAssertTrue(sidecar.sampleStatusFlags.contains {
            $0.sample == "AnimalA" && $0.value == .needsReview
        })
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
    }


    func testHaplotypedMiSeqReconfigurationClearsReviewShortcutAuthority()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HaplotypedMiSeqReviewAuthority-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent(
            "first.lungfishgenotype",
            isDirectory: true
        )
        let secondURL = root.appendingPathComponent(
            "second.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondURL,
            withIntermediateDirectories: true
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: firstURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis(
                sample: "BundleAAnimal"
            )
        ))
        controller.testingSelectCellEvidence(
            animalId: "BundleAAnimal",
            locus: "MHC-A"
        )
        XCTAssertEqual(
            controller.testingCurrentCallEvidenceSample,
            "BundleAAnimal"
        )

        controller.configure(result: makeResult(
            bundleURL: secondURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis(
                sample: "BundleBAnimal"
            )
        ))
        let flag = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "F",
            charactersIgnoringModifiers: "F",
            isARepeat: false,
            keyCode: 3
        ))

        XCTAssertNil(controller.testingCurrentSelectedSample)
        XCTAssertNil(controller.testingCurrentCallEvidenceSample)
        XCTAssertFalse(controller.performKeyEquivalent(with: flag))
        let secondSidecar = try GenotypeAnnotationStore(
            bundleURL: secondURL,
            author: "test",
            seedBuiltInSmartCohorts: true
        ).sidecar
        XCTAssertFalse(secondSidecar.sampleStatusFlags.contains {
            $0.sample == "BundleAAnimal"
        })
    }


    func testHaplotypedMiSeqRemovedLensCapabilitiesRemainReachable()
        throws
    {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        ))
        let actionsButton = try XCTUnwrap(
            descendants(of: controller.view)
                .compactMap { $0 as? NSButton }
                .first {
                    $0.accessibilityIdentifier()
                        == "genotype-result-actions-menu"
                }
        )

        XCTAssertEqual(
            actionsButton.menu?.items.map(\.title),
            ["AI Discovery", "AI Refinement", "Export Excel View…"]
        )
        let documentSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift"
            )
        let documentSource = try String(
            contentsOf: documentSourceURL,
            encoding: .utf8
        )
        for title in ["Audit Timeline", "Current Workbook", "Artifacts"] {
            XCTAssertTrue(documentSource.contains(title), title)
        }
        let smartCohortSource = try String(
            contentsOf: documentSourceURL
                .deletingLastPathComponent()
                .appendingPathComponent("GenotypeSmartCohortSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(smartCohortSource.contains("Needs Review"))
        let inspectorSource = try String(
            contentsOf: documentSourceURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift"
                ),
            encoding: .utf8
        )
        XCTAssertTrue(inspectorSource.contains(
            "GenotypeResultArtifactRow(label: \"Provenance\""
        ))
        let evidenceSourceURL = documentSourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("GenotypeCallEvidenceView.swift")
        let evidenceSource = try String(
            contentsOf: evidenceSourceURL,
            encoding: .utf8
        )
        for title in ["Override", "Confirm", "Skip", "next review sample"] {
            XCTAssertTrue(evidenceSource.contains(title), title)
        }
        let displaySourceURL = documentSourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("GenotypeResultDisplaySection.swift")
        let displaySource = try String(
            contentsOf: displaySourceURL,
            encoding: .utf8
        )
        XCTAssertTrue(displaySource.contains("viewModel.presentationChoices"))
        XCTAssertFalse(
            displaySource.contains(
                "ForEach(GenotypeResultViewportLens.allCases"
            )
        )
    }


    func testActionsMenuAIRefinementDisabledWithoutAnalysis() throws {
        // Regression test for AS14: the toolbar "Actions" menu's AI
        // Refinement item must be disabled when no haplotype analysis
        // exists yet, matching the inline audit-section button.
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [],
            haplotypeAnalysis: nil
        ))

        let actionsButton = try XCTUnwrap(
            descendants(of: controller.view)
                .compactMap { $0 as? NSButton }
                .first {
                    $0.accessibilityIdentifier()
                        == "genotype-result-actions-menu"
                }
        )
        let menu = try XCTUnwrap(actionsButton.menu)
        menu.delegate?.menuNeedsUpdate?(menu)

        let discoveryItem = try XCTUnwrap(menu.items.first { $0.title == "AI Discovery" })
        let refinementItem = try XCTUnwrap(menu.items.first { $0.title == "AI Refinement" })
        XCTAssertTrue(discoveryItem.isEnabled)
        XCTAssertFalse(refinementItem.isEnabled, "Refinement should be disabled with no active haplotype analysis")
    }


    func testActionsMenuAIItemsDisabledWhenReadOnly() throws {
        // Regression test for AS14: the toolbar "Actions" menu's AI
        // Discovery/Refinement items must be disabled on a read-only
        // bundle, matching the inline audit-section buttons.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeResultActionsMenuReadOnly-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: root.path
        )
        let readOnlyStore = try GenotypeAnnotationStore(bundleURL: root, author: "test")
        XCTAssertTrue(readOnlyStore.isReadOnly)

        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: root,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        ))
        controller.testingInstallEffectiveHaplotypeAnnotationStore(readOnlyStore)

        let actionsButton = try XCTUnwrap(
            descendants(of: controller.view)
                .compactMap { $0 as? NSButton }
                .first {
                    $0.accessibilityIdentifier()
                        == "genotype-result-actions-menu"
                }
        )
        let menu = try XCTUnwrap(actionsButton.menu)
        menu.delegate?.menuNeedsUpdate?(menu)

        let discoveryItem = try XCTUnwrap(menu.items.first { $0.title == "AI Discovery" })
        let refinementItem = try XCTUnwrap(menu.items.first { $0.title == "AI Refinement" })
        XCTAssertFalse(discoveryItem.isEnabled, "Discovery should be disabled on a read-only bundle")
        XCTAssertFalse(refinementItem.isEnabled, "Refinement should be disabled on a read-only bundle")
    }


    func testHaplotypedMiSeqPreservesPerSlotStatusAndReviewEligibility() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeResultPerSlotProjection-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-08-03T00:00:00Z"
        )
        sidecar.callOverrides = [
            .init(
                sample: "DW472",
                locus: "MHC-A",
                slot: .h1,
                originalCall: "Not assayed",
                overrideCall: "M1A",
                reasonTag: .analystJudgment,
                rationale: "Resolved H1.",
                author: "test",
                timestamp: "2026-08-03T01:00:00Z"
            ),
            .init(
                sample: "DW472",
                locus: "MHC-A",
                slot: .h2,
                originalCall: "Not assayed",
                overrideCall: GenotypeHaplotypeOverrideTargets.unresolved,
                reasonTag: .analystJudgment,
                rationale: "H2 remains unresolved.",
                author: "test",
                timestamp: "2026-08-03T01:00:00Z"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundleURL
        )
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                .init(sample: "DW472", calls: [
                    .init(
                        locus: "MHC-A",
                        sourceLocus: "Mafa-A",
                        haplotype1: "Not assayed",
                        haplotype2: "Not assayed",
                        status: .notAssayed,
                        matchedHaplotypes: [],
                        observedGenotypeCount: 0,
                        observedGenotypes: []
                    ),
                ]),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: analysis
        ))

        let rows = controller.testingSampleDetailRows(sample: "DW472")
        let h1 = try XCTUnwrap(rows.first { $0.locus == "MHC-A" && $0.slot == .h1 })
        let h2 = try XCTUnwrap(rows.first { $0.locus == "MHC-A" && $0.slot == .h2 })
        XCTAssertEqual(h1.callName, "M1A")
        XCTAssertEqual(h1.status, .called)
        XCTAssertEqual(h1.source, .analystOverride)
        XCTAssertEqual(h2.callName, GenotypeHaplotypeOverrideTargets.unresolved)
        XCTAssertEqual(h2.status, .noHaplotype)
        XCTAssertEqual(h2.source, .analystOverride)
        XCTAssertEqual(controller.testingUnresolvedReviewLoci(sample: "DW472"), ["MHC-A"])

        let outline = try XCTUnwrap(
            controller.testingOutlineSlots(sample: "DW472").first {
                $0.locus == "MHC-A"
            }
        )
        XCTAssertEqual(outline.h1.testingLabel, "M1A")
        XCTAssertFalse(outline.h1.testingIsError)
        XCTAssertEqual(outline.h2.testingLabel, GenotypeHaplotypeOverrideTargets.unresolved)
        XCTAssertTrue(outline.h2.testingIsError)
    }


    func testHaplotypedMiSeqDetailUsesOnlyProjectionAuthoritativeOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeResultAuthoritativeOverride-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        func entry(_ value: String, timestamp: String) -> GenotypeAnnotationSidecar.CallOverride {
            .init(
                sample: "DW472",
                locus: "MHC-A",
                slot: .h1,
                originalCall: "M0A",
                overrideCall: value,
                reasonTag: .analystJudgment,
                rationale: value,
                author: "test",
                timestamp: timestamp
            )
        }
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-08-03T00:00:00Z"
        )
        sidecar.callOverrides = [
            entry("authoritative", timestamp: "2026-08-03T03:00:00Z"),
            entry("older-out-of-order", timestamp: "2026-08-03T01:00:00Z"),
            entry("malformed", timestamp: "not-a-timestamp"),
            .init(
                sample: "Other",
                locus: "MHC-A",
                slot: .h1,
                originalCall: "M0A",
                overrideCall: "unrelated",
                reasonTag: .analystJudgment,
                rationale: "unrelated",
                author: "test",
                timestamp: "2026-08-03T04:00:00Z"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundleURL
        )
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                .init(sample: "DW472", calls: [
                    .init(
                        locus: "MHC-A",
                        sourceLocus: "Mafa-A",
                        haplotype1: "M0A",
                        haplotype2: "M0A",
                        status: .called,
                        matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: []
                    ),
                ]),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: analysis
        ))

        let rows = controller.testingSampleDetailRows(sample: "DW472")
        XCTAssertEqual(
            rows.first { $0.locus == "MHC-A" && $0.slot == .h1 }?.callName,
            "authoritative"
        )
        let overrides = controller.testingSampleDetailOverrides(sample: "DW472")
        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(overrides.first?.overrideCall, "authoritative")
        XCTAssertEqual(overrides.first?.timestamp, "2026-08-03T03:00:00Z")
    }


    func testInspectorOverrideAppliesExplicitSelectedHaplotypeSlot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultExplicitOverride-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try installCallOverrideManifest(in: bundleURL)
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
        try installCallOverrideManifest(in: bundleURL)
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
        var annotationNotifications = 0
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
        controller.onAnnotationSidecarChanged = { _ in
            annotationNotifications += 1
        }
        controller.onCurrentWorkbookSyncRequested = {
            workbookActions.append($0.action)
        }
        let dirtyMarksBefore =
            controller.testingManualHaplotypeWorkbookDirtyMarkCount

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
        XCTAssertEqual(h1Override.operationID, h2Override.operationID)
        XCTAssertNotNil(h1Override.operationID)
        XCTAssertEqual(h1Override.timestamp, h2Override.timestamp)
        let expectedIdentity =
            GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity(
                assayID: analysis.assayID,
                analysisRevisionID: analysis.analysisRevisionID,
                definitionSetID: analysis.definitionSetID
            )
        XCTAssertEqual(h1Override.analysisIdentity, expectedIdentity)
        XCTAssertEqual(h2Override.analysisIdentity, expectedIdentity)

        let audits = sidecar.auditLog.filter {
            $0.sample == "DW472" && $0.locus == "MHC-DP"
                && ($0.action == "override" || $0.action == "clearOverride")
        }
        XCTAssertEqual(audits.count, 2)
        XCTAssertEqual(audits.map(\.slot), [.h1, .h2])
        XCTAssertEqual(Set(audits.map(\.timestamp)).count, 1)
        XCTAssertEqual(
            Set(audits.compactMap {
                $0.callOverrideMutation?.operationID
            }).count,
            1
        )
        XCTAssertEqual(
            audits.map { $0.callOverrideMutation?.analysisIdentity },
            [expectedIdentity, expectedIdentity]
        )
        XCTAssertEqual(annotationNotifications, 1)
        XCTAssertEqual(workbookActions, [.markDirty])
        XCTAssertEqual(
            controller.testingManualHaplotypeWorkbookDirtyMarkCount,
            dirtyMarksBefore + 1
        )

        let annotationURL = bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenance = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(
                fromSidecar: ProvenanceRecorder.fileSidecarURL(
                    for: annotationURL
                )
            )
        )
        XCTAssertEqual(
            provenance.options.resolvedDefaults["changedTargetCount"],
            .integer(2)
        )

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-DP"))
        XCTAssertEqual(evidence.h1Name, "M3DP")
        XCTAssertEqual(evidence.h2Name, "M5DP")
    }


    func testInspectorTwoSlotValidationFailurePublishesNothingAndDoesNotNotify() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeResultBatchValidation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try installCallOverrideManifest(in: bundleURL)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID:
                "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                .init(sample: "DW472", calls: [
                    .init(
                        locus: "MHC-DP",
                        sourceLocus: "Mafa-DP",
                        haplotype1: "M4DP",
                        haplotype2: "M7DP",
                        status: .tooManyHaplotypes,
                        matchedHaplotypes: [],
                        observedGenotypeCount: 3,
                        observedGenotypes: [
                            "15_M3_DPA1_01", "15_M7_DPB1_01",
                        ]
                    ),
                ]),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectCellEvidence(
            animalId: "DW472",
            locus: "MHC-DP"
        )
        let annotationURL = bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(
            for: annotationURL
        )
        let annotationBefore = try Data(contentsOf: annotationURL)
        let provenanceBefore = try Data(contentsOf: provenanceURL)
        let dirtyMarksBefore =
            controller.testingManualHaplotypeWorkbookDirtyMarkCount
        var annotationNotifications = 0
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
        controller.onAnnotationSidecarChanged = { _ in
            annotationNotifications += 1
        }
        controller.onCurrentWorkbookSyncRequested = {
            workbookActions.append($0.action)
        }

        let error = controller
            .testingApplyOverridesFromInspectorWithoutPresentingError([
                .init(slot: .h1, haplotypeName: "M3DP"),
                .init(slot: .h1, haplotypeName: "M5DP"),
            ])

        XCTAssertNotNil(error as? CallOverrideMutationError)
        XCTAssertEqual(try Data(contentsOf: annotationURL), annotationBefore)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), provenanceBefore)
        XCTAssertEqual(annotationNotifications, 0)
        XCTAssertTrue(workbookActions.isEmpty)
        XCTAssertEqual(
            controller.testingManualHaplotypeWorkbookDirtyMarkCount,
            dirtyMarksBefore
        )
        let evidence = try XCTUnwrap(
            controller.callEvidence(sample: "DW472", locus: "MHC-DP")
        )
        XCTAssertEqual(evidence.h1Name, "M4DP")
        XCTAssertEqual(evidence.h2Name, "M7DP")
    }


    func testSampleDetailSaveAfterAnalysisRevisionUsesActiveBaselineAndIdentity() throws {
        let fixture = try makeStaleSampleDetailOverrideFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let row = try XCTUnwrap(
            fixture.controller.testingSampleDetailRows(sample: "DW472")
                .first { $0.locus == "MHC-DP" && $0.slot == .h1 }
        )
        XCTAssertEqual(row.callName, "M4DP")
        XCTAssertEqual(row.source, .staleOverride)

        let error = fixture.controller
            .testingSaveSampleDetailOverrideWithoutPresentingSheet(
                sample: "DW472",
                row: row,
                target: "M3DP"
            )

        XCTAssertNil(error)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: fixture.bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            )
        ))
        let saved = try XCTUnwrap(sidecar.callOverrides.first)
        XCTAssertEqual(sidecar.callOverrides.count, 1)
        XCTAssertEqual(saved.originalCall, "M4DP")
        XCTAssertEqual(saved.overrideCall, "M3DP")
        XCTAssertEqual(
            saved.analysisIdentity,
            .init(
                assayID: fixture.analysis.assayID,
                analysisRevisionID: fixture.analysis.analysisRevisionID,
                definitionSetID: fixture.analysis.definitionSetID
            )
        )
        XCTAssertEqual(sidecar.auditLog.last?.before, "M4DP")
        XCTAssertEqual(sidecar.auditLog.last?.after, "M3DP")
    }


    func testSampleDetailClearAfterAnalysisRevisionAuditsActiveBaseline() throws {
        let fixture = try makeStaleSampleDetailOverrideFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let row = try XCTUnwrap(
            fixture.controller.testingSampleDetailRows(sample: "DW472")
                .first { $0.locus == "MHC-DP" && $0.slot == .h1 }
        )

        let error = fixture.controller
            .testingClearSampleDetailOverrideWithoutPresentingSheet(
                sample: "DW472",
                row: row
            )

        XCTAssertNil(error)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: fixture.bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            )
        ))
        XCTAssertTrue(sidecar.callOverrides.isEmpty)
        XCTAssertEqual(sidecar.auditLog.last?.action, "clearOverride")
        XCTAssertEqual(sidecar.auditLog.last?.before, "M4DP")
        XCTAssertEqual(sidecar.auditLog.last?.after, "M4DP")
        XCTAssertEqual(
            sidecar.auditLog.last?.callOverrideMutation?.analysisIdentity,
            .init(
                assayID: fixture.analysis.assayID,
                analysisRevisionID: fixture.analysis.analysisRevisionID,
                definitionSetID: fixture.analysis.definitionSetID
            )
        )
    }


    func testQuestionMarkOverrideRemainsUnresolvedInEvidenceAndOutline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultUnknownOverride-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try installCallOverrideManifest(in: bundleURL)
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


    func testRefinedManualCurationParityForONTAndMiSeqGenotypeOnlyResults()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RefinedManualCurationParity-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        for kind in [
            GenotypeResultWorkflowKind.fullLengthONTMHCGenotype,
            .miSeqAmpliconMHCGenotype,
        ] {
            let bundleURL = root.appendingPathComponent(
                "\(kind.rawValue).lungfishgenotype",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: bundleURL,
                withIntermediateDirectories: true
            )
            let manifest = ONTGenotypeResultBundleManifest(
                kind: kind.rawValue,
                workflowKind: kind,
                workflowMode: .genotypeOnly,
                outputName: kind.rawValue,
                analysisName: kind.rawValue,
                primaryWorkbookPath: "current.xlsx",
                longSummaryCSVPath: "calls.csv",
                sampleSummaryCSVPath: "samples.csv",
                statsJSONPath: "stats.json",
                provenancePath: "provenance.json"
            )
            try ONTGenotypeResultBundle.writeManifest(
                manifest,
                to: bundleURL
            )
            var sidecar = GenotypeAnnotationSidecar.empty(
                generatedAt: "2026-07-29T00:00:00Z"
            )
            sidecar.manualHaplotypeAssignments = [
                ManualHaplotypeAssignment(
                    sample: "Source",
                    locus: "MHC-A",
                    slot: .h1,
                    label: "Source haplotype with a deliberately wide label",
                    colorTokenIndex: 1,
                    diagnosticAlleles: [],
                    notes: ""
                ),
            ]
            try ONTGenotypeResultBundleData.writeAnnotationSidecar(
                sidecar,
                forBundleAt: bundleURL
            )
            let calls = [
                makeCall(
                    sample: "Target",
                    genotype: "12_Mafa_B_002_01",
                    reads: 18
                ),
                makeCall(
                    sample: "Target",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 42
                ),
                makeCall(
                    sample: "Source",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 31
                ),
            ]
            let controller = GenotypeResultViewController()
            controller.view.frame = NSRect(
                x: 0,
                y: 0,
                width: 1_200,
                height: 900
            )
            controller.configure(result: makeResult(
                bundleURL: bundleURL,
                samples: [],
                calls: calls,
                manifest: manifest
            ))
            var workbookActions:
                [GenotypeCurrentWorkbookUIRequest.Action] = []
            controller.onCurrentWorkbookSyncRequested = {
                workbookActions.append($0.action)
            }
            let matrix = controller.testingComparisonMatrix
            XCTAssertFalse(
                matrix.testingManualHaplotypeBandIsExpanded,
                kind.rawValue
            )
            let collapsedWidth = matrix.testingSampleColumnWidth(
                sample: "Source"
            )

            controller.testingSetManualHaplotypeBandDisclosureExpanded(true)

            XCTAssertTrue(
                matrix.testingManualHaplotypeBandIsExpanded,
                kind.rawValue
            )
            XCTAssertGreaterThan(
                matrix.testingSampleColumnWidth(sample: "Source"),
                collapsedWidth,
                kind.rawValue
            )
            controller.testingSelectMatrixColumn(sample: "Target")
            let evidenceOrder =
                controller.testingSupportedAllelesSnapshotRows.map(\.allele)
            XCTAssertFalse(evidenceOrder.isEmpty, kind.rawValue)
            controller.testingShowSampleComparison()
            controller.testingSelectSampleComparisonSource("Source")
            XCTAssertEqual(
                controller.testingSampleComparisonRows.map(\.allele),
                evidenceOrder,
                kind.rawValue
            )

            controller.testingSetSampleComparisonAssignmentSelected(
                true,
                locus: .a,
                slot: .h1
            )
            controller.testingRequestStageSelectedSampleAssignments()
            controller.testingConfirmStageSelectedSampleAssignments()
            XCTAssertTrue(
                controller.testingManualHaplotypeEditorIsDirty,
                kind.rawValue
            )
            XCTAssertEqual(
                controller.testingManualHaplotypeDraftLabel(
                    locus: .a,
                    slot: .h1
                ),
                "Source haplotype with a deliberately wide label",
                kind.rawValue
            )
            let stagedButUnsaved = try ONTGenotypeResultBundleData
                .loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
            XCTAssertTrue(
                stagedButUnsaved.manualHaplotypeAssignments
                    .filter { $0.sample == "Target" }
                    .isEmpty,
                kind.rawValue
            )
            XCTAssertFalse(
                controller.testingCurrentWorkbookNeedsRefresh,
                kind.rawValue
            )
            XCTAssertTrue(workbookActions.isEmpty, kind.rawValue)
            controller.testingSaveManualHaplotypeDraft()

            XCTAssertFalse(
                controller.testingManualHaplotypeEditorIsDirty,
                kind.rawValue
            )
            XCTAssertEqual(
                matrix.testingManualHaplotypeBandValues(
                    sample: "Target"
                ).first,
                "Source haplotype with a deliberately wide label · —",
                kind.rawValue
            )
            XCTAssertTrue(
                controller.testingCurrentWorkbookNeedsRefresh,
                kind.rawValue
            )
            XCTAssertEqual(workbookActions, [.markDirty], kind.rawValue)
            let persisted = try ONTGenotypeResultBundleData
                .loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
            XCTAssertEqual(
                persisted.manualHaplotypeAssignments
                    .filter { $0.sample == "Target" }
                    .map(\.label),
                ["Source haplotype with a deliberately wide label"],
                kind.rawValue
            )
        }
    }


    func testMiSeqProvisionalExonTwoEvidenceAndComparisonSurviveSaveAndRefresh()
        throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MiSeqProvisionalManualParity-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let genotype = "Mafa-A1*007:08:01:01_1nt_nov"
        let targetCall = makeCall(
            sample: "Target",
            genotype: genotype,
            reads: 11
        )
        let sourceCall = makeCall(
            sample: "Source",
            genotype: genotype,
            reads: 9
        )
        let provisional = ONTGenotypeProvisionalExon2Sequence(
            genotype: genotype,
            locus: targetCall.locusGroup,
            sequence: "AACCGGTT",
            sequenceSHA256: String(repeating: "a", count: 64),
            sampleSupport: [
                .init(
                    sample: "Target",
                    passedAlignments: 12,
                    passedUniqueReads: 11
                ),
                .init(
                    sample: "Source",
                    passedAlignments: 10,
                    passedUniqueReads: 9
                ),
            ]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-29T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "Source",
                locus: "MHC-A",
                slot: .h1,
                label: "Provisional source family",
                colorTokenIndex: 2,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundleURL
        )
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [targetCall, sourceCall],
            kind: GenotypeResultWorkflowKind
                .miSeqAmpliconMHCGenotype.rawValue,
            provisionalExon2SequencesByGenotype: [genotype: provisional]
        )
        try ONTGenotypeResultBundle.writeManifest(
            result.manifest,
            to: bundleURL
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectMatrixColumn(sample: "Target")
        XCTAssertEqual(
            controller.testingSupportedAllelesSnapshotRows.map(\.allele),
            [genotype]
        )
        controller.testingShowSampleComparison()
        controller.testingSelectSampleComparisonSource("Source")
        XCTAssertEqual(
            controller.testingSampleComparisonRows.map(\.allele),
            [genotype]
        )
        controller.testingSetSampleComparisonAssignmentSelected(
            true,
            locus: .a,
            slot: .h1
        )
        controller.testingRequestStageSelectedSampleAssignments()
        controller.testingConfirmStageSelectedSampleAssignments()
        controller.testingSaveManualHaplotypeDraft()
        controller.testingSelectMatrixCell(
            genotype: genotype,
            sample: "Target"
        )
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Designation", "Provisional exon 2")
        })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Resolved allele"
        })

        controller.configure(result: result)
        controller.testingSelectMatrixColumn(sample: "Target")

        XCTAssertEqual(
            controller.testingSupportedAllelesSnapshotRows.map(\.allele),
            [genotype]
        )
        XCTAssertEqual(
            controller.testingComparisonMatrix
                .testingManualHaplotypeBandValues(sample: "Target").first,
            "Provisional source family · —"
        )
    }


    func testHaplotypedMiSeqStillExcludesDisclosureEditorAndComparison()
        throws
    {
        try assertRefinedManualCurationIsAbsent(
            kind: .miSeqAmpliconMHCGenotype
        )
    }


    func testHaplotypedONTStillExcludesDisclosureEditorAndComparison()
        throws
    {
        try assertRefinedManualCurationIsAbsent(
            kind: .fullLengthONTMHCGenotype
        )
    }


    func testCompareSourceMayBeHiddenInBothEligibleGenotypeOnlyAssays()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HiddenComparisonParity-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in [
            GenotypeResultWorkflowKind.fullLengthONTMHCGenotype,
            .miSeqAmpliconMHCGenotype,
        ] {
            let bundleURL = root.appendingPathComponent(
                "\(kind.rawValue).lungfishgenotype",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: bundleURL,
                withIntermediateDirectories: true
            )
            try ONTGenotypeResultBundleData.writeAnnotationSidecar(
                .empty(generatedAt: "2026-07-29T00:00:00Z"),
                forBundleAt: bundleURL
            )
            let targetCall = makeCall(
                sample: "Target",
                genotype: "01_Mafa_A1_SHARED",
                reads: 42
            )
            let sourceCall = makeCall(
                sample: "Hidden Source",
                genotype: "01_Mafa_A1_SHARED",
                reads: 21
            )
            let manifest = ONTGenotypeResultBundleManifest(
                kind: kind.rawValue,
                workflowKind: kind,
                workflowMode: .genotypeOnly,
                outputName: kind.rawValue,
                analysisName: kind.rawValue,
                primaryWorkbookPath: "current.xlsx",
                longSummaryCSVPath: "calls.csv",
                sampleSummaryCSVPath: "samples.csv",
                statsJSONPath: "stats.json",
                provenancePath: "provenance.json"
            )
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: makeResult(
                bundleURL: bundleURL,
                samples: [],
                calls: [targetCall, sourceCall],
                manifest: manifest
            ))
            controller.testingComparisonMatrix.testingHideSamples(
                Set(["Hidden Source"])
            )
            XCTAssertFalse(
                controller.testingVisibleMatrixSamples.contains(
                    "Hidden Source"
                ),
                kind.rawValue
            )

            controller.testingSelectMatrixColumn(sample: "Target")
            controller.testingShowSampleComparison()
            XCTAssertTrue(
                controller.testingSampleComparisonCandidateSamples.contains(
                    "Hidden Source"
                ),
                kind.rawValue
            )
            controller.testingSelectSampleComparisonSource("Hidden Source")
            XCTAssertEqual(
                controller.testingSelectedSampleComparisonSource,
                "Hidden Source",
                kind.rawValue
            )

            XCTAssertEqual(
                controller.testingSampleComparisonRows.first?.relationship,
                .shared,
                kind.rawValue
            )
        }
    }


    func testHaplotypedMiSeqMatrixSelectionControlsVisibleCurationPane()
        throws
    {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        var state = GenotypeResultDisplayState()
        state.summaryViewMode = .matrix
        controller.testingApplyDisplayState(state)

        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertTrue(controller.testingCohortSummaryIsHidden)
        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)

        controller.testingComparisonMatrix.testingSelectMatrixTargets([
            .column(sample: "Sample-A"),
        ])

        XCTAssertTrue(controller.testingCohortSummaryIsHidden)
        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertEqual(controller.testingMountedSampleWorkbenchCount, 1)
        XCTAssertEqual(
            controller.testingEffectiveHaplotypeEditorSample,
            "Sample-A"
        )

        controller.testingComparisonMatrix.testingSelectMatrixTargets([])

        XCTAssertTrue(controller.testingCohortSummaryIsHidden)
        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertEqual(controller.testingMountedSampleWorkbenchCount, 0)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
    }


    func testHaplotypedMiSeqColumnSelectionUsesSharedAssignmentEditorAndAuditedOverrides()
        throws
    {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        var inspectorNotifications = 0
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
        controller.onAnnotationSidecarChanged = { _ in
            inspectorNotifications += 1
        }
        controller.onCurrentWorkbookSyncRequested = {
            workbookActions.append($0.action)
        }

        controller.testingShowMatrixTargetSelection([
            .column(sample: "Sample-A"),
        ])

        XCTAssertEqual(controller.testingEffectiveHaplotypeEditorSample, "Sample-A")
        XCTAssertEqual(
            controller.testingEffectiveHaplotypeEditorLoci,
            ["MHC-A", "MHC-B"]
        )
        XCTAssertEqual(
            controller.testingEffectiveHaplotypeEditorValue(
                locus: "MHC-A",
                slot: .h1
            ),
            "A1"
        )
        XCTAssertEqual(
            controller.testingEffectiveHaplotypeEditorValue(
                locus: "MHC-A",
                slot: .h2
            ),
            "A2"
        )
        XCTAssertNil(controller.testingManualHaplotypeEditorSample)

        controller.testingUpdateEffectiveHaplotypeLabel(
            "A1-review",
            locus: "MHC-A",
            slot: .h1
        )
        controller.testingUpdateEffectiveHaplotypeLabel(
            "A2-review",
            locus: "MHC-A",
            slot: .h2
        )
        XCTAssertTrue(controller.testingEffectiveHaplotypeEditorIsDirty)
        controller.testingSaveEffectiveHaplotypeDraft()

        XCTAssertFalse(controller.testingEffectiveHaplotypeEditorIsDirty)
        XCTAssertNil(controller.testingEffectiveHaplotypeEditorPersistenceError)
        XCTAssertEqual(inspectorNotifications, 1)
        XCTAssertEqual(workbookActions, [.markDirty])
        XCTAssertEqual(
            controller.testingComparisonMatrix.testingHaplotypeBandRenderedValue(
                sample: "Sample-A",
                locus: "MHC-A"
            ),
            "A1-review • A2-review"
        )
        XCTAssertEqual(
            controller.testingSampleDetailRows(sample: "Sample-A")
                .filter { $0.locus == "MHC-A" }
                .map(\.callName),
            ["A1-review", "A2-review"]
        )

        let sidecar = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: fixture.bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            ))
        )
        XCTAssertEqual(sidecar.callOverrides.count, 2)
        XCTAssertTrue(sidecar.manualHaplotypeAssignments.isEmpty)
        let overrideAudits = sidecar.auditLog.filter {
            $0.action == "override"
        }
        XCTAssertEqual(overrideAudits.count, 2)
        XCTAssertEqual(
            Set(overrideAudits.compactMap {
                $0.callOverrideMutation?.operationID
            }).count,
            1,
            "One Save must persist both slot edits as one audited operation."
        )
    }


    func testHaplotypedMiSeqExplicitNotCalledAndRestoreAffectOnlyOneSlot()
        throws
    {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        var inspectorNotifications = 0
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
        controller.onAnnotationSidecarChanged = { _ in
            inspectorNotifications += 1
        }
        controller.onCurrentWorkbookSyncRequested = {
            workbookActions.append($0.action)
        }
        controller.testingShowMatrixTargetSelection([
            .column(sample: "Sample-A"),
        ])

        controller.testingMarkEffectiveHaplotypeNotCalled(
            locus: "MHC-A",
            slot: .h1
        )

        XCTAssertEqual(
            controller.testingEffectiveHaplotypeEditorValue(
                locus: "MHC-A",
                slot: .h1
            ),
            ""
        )
        XCTAssertEqual(
            controller.testingEffectiveHaplotypeEditorValue(
                locus: "MHC-A",
                slot: .h2
            ),
            "A2"
        )
        XCTAssertTrue(
            controller.testingCanRestoreEffectiveWorkflowHaplotype(
                locus: "MHC-A",
                slot: .h1
            )
        )
        controller.testingSaveEffectiveHaplotypeDraft()

        XCTAssertEqual(inspectorNotifications, 1)
        XCTAssertEqual(workbookActions, [.markDirty])
        XCTAssertEqual(
            controller.testingComparisonMatrix.testingHaplotypeBandRenderedValue(
                sample: "Sample-A",
                locus: "MHC-A"
            ),
            "— • A2"
        )
        var sidecar = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: fixture.bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            ))
        )
        XCTAssertEqual(sidecar.callOverrides.count, 1)
        XCTAssertEqual(sidecar.callOverrides[0].slot, .h1)
        XCTAssertEqual(sidecar.callOverrides[0].overrideCall, "-")
        XCTAssertEqual(
            sidecar.auditLog.filter { $0.action == "override" }.count,
            1
        )

        controller.testingRestoreEffectiveWorkflowHaplotype(
            locus: "MHC-A",
            slot: .h1
        )
        controller.testingSaveEffectiveHaplotypeDraft()

        XCTAssertEqual(
            controller.testingEffectiveHaplotypeEditorValue(
                locus: "MHC-A",
                slot: .h1
            ),
            "A1"
        )
        XCTAssertEqual(
            controller.testingEffectiveHaplotypeEditorValue(
                locus: "MHC-A",
                slot: .h2
            ),
            "A2"
        )
        XCTAssertEqual(
            controller.testingComparisonMatrix.testingHaplotypeBandRenderedValue(
                sample: "Sample-A",
                locus: "MHC-A"
            ),
            "A1 • A2"
        )
        XCTAssertEqual(inspectorNotifications, 2)
        XCTAssertEqual(workbookActions, [.markDirty, .markDirty])
        sidecar = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: fixture.bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            ))
        )
        XCTAssertTrue(sidecar.callOverrides.isEmpty)
        XCTAssertEqual(
            sidecar.auditLog.filter {
                $0.action == "override" || $0.action == "clearOverride"
            }.count,
            2
        )
    }


    func testHaplotypedMiSeqEditorDraftUsesExistingNavigationSaveGuard()
        async throws
    {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        controller.testingShowMatrixTargetSelection([
            .column(sample: "Sample-A"),
        ])
        controller.testingUpdateEffectiveHaplotypeLabel(
            "A1-guarded",
            locus: "MHC-A",
            slot: .h1
        )
        XCTAssertTrue(controller.hasUnsavedManualHaplotypeDraft)
        controller.testingSetManualHaplotypeDraftDecisionProvider { _ in
            .save
        }

        let allowed = await controller.prepareForManualHaplotypeTransition(
            .selection
        )
        XCTAssertTrue(allowed)
        XCTAssertFalse(controller.hasUnsavedManualHaplotypeDraft)
        XCTAssertEqual(
            controller.testingComparisonMatrix.testingHaplotypeBandRenderedValue(
                sample: "Sample-A",
                locus: "MHC-A"
            ),
            "A1-guarded • A2"
        )
    }


    func testHaplotypedMiSeqEditsStaySynchronized() throws {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundleURL = fixture.bundleURL
        let result = fixture.result
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        var inspectorNotifications = 0
        var workbookRequests: [GenotypeCurrentWorkbookUIRequest] = []
        controller.onAnnotationSidecarChanged = { _ in
            inspectorNotifications += 1
        }
        controller.onCurrentWorkbookSyncRequested = {
            workbookRequests.append($0)
        }
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] {
            workbookRequests.map(\.action)
        }
        let matrix = try XCTUnwrap(
            controller.view.firstDescendant(
                ofType: GenotypeComparisonMatrixView.self
            )
        )
        XCTAssertEqual(
            matrix.testingProjectionPerformanceSnapshot.baseProjectionBuildCount,
            0
        )

        controller.testingSelectCellEvidence(
            animalId: "Sample-A",
            locus: "MHC-A"
        )
        controller.testingApplyOverridesFromInspector([
            .init(slot: .h1, haplotypeName: "A1-review"),
            .init(slot: .h2, haplotypeName: "A2-review"),
        ])
        XCTAssertEqual(inspectorNotifications, 1)
        XCTAssertEqual(workbookActions, [.markDirty])
        XCTAssertEqual(
            controller.testingLastEffectiveHaplotypeMutationChangedKeys,
            [
                .init(sample: "Sample-A", locus: "MHC-A", slot: .h1),
                .init(sample: "Sample-A", locus: "MHC-A", slot: .h2),
            ]
        )
        XCTAssertEqual(
            controller.testingLastEffectiveHaplotypeRefreshedKeys,
            controller.testingLastEffectiveHaplotypeMutationChangedKeys
        )
        XCTAssertEqual(
            controller.testingSampleDetailRows(sample: "Sample-A")
                .filter { $0.locus == "MHC-A" },
            [
                .init(
                    locus: "MHC-A", slot: .h1,
                    callName: "A1-review", status: .called,
                    source: .analystOverride,
                    observedGenotypeCount: 2
                ),
                .init(
                    locus: "MHC-A", slot: .h2,
                    callName: "A2-review", status: .called,
                    source: .analystOverride,
                    observedGenotypeCount: 2
                ),
            ]
        )

        var state = GenotypeResultDisplayState()
        state.summaryViewMode = .matrix
        state.manualHaplotypeBandExpanded = true
        controller.testingApplyDisplayState(state)

        XCTAssertEqual(matrix.testingHaplotypeBandMode, .effectiveMiSeqCalls)
        XCTAssertEqual(matrix.testingHaplotypeBandLoci, ["MHC-A", "MHC-B"])
        XCTAssertEqual(
            matrix.testingHaplotypeBandValue(
                sample: "Sample-A",
                locus: "MHC-A",
                slot: .h1
            ),
            .init(
                value: "A1-review",
                status: .called,
                source: .analystOverride,
                isEditable: true
            )
        )
        XCTAssertEqual(
            matrix.testingHaplotypeBandValue(
                sample: "Sample-B",
                locus: "MHC-B",
                slot: .h2
            ),
            .init(
                value: "D2",
                status: .called,
                source: .pipeline,
                isEditable: true
            )
        )

        matrix.testingResetManualHaplotypeBandInvalidations()
        let matrixTarget = GenotypeHaplotypeBandTarget(
            sample: "Sample-B",
            locus: "MHC-B",
            slot: .h1
        )
        let targetButton = try XCTUnwrap(
            matrix.testingHaplotypeBandHitTarget(matrixTarget)
        )
        let matrixWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        matrixWindow.contentViewController = controller
        XCTAssertTrue(matrixWindow.makeFirstResponder(targetButton))
        XCTAssertTrue(targetButton.accessibilityPerformPress())
        XCTAssertEqual(
            controller.testingSummaryViewMode,
            .matrix,
            "Activating a band call must keep Haplotype Calls hidden."
        )
        XCTAssertTrue(
            (targetButton.accessibilityLabel() ?? "").contains(
                "Sample Sample-B, MHC-B H1, D1, status called, source pipeline"
            )
        )
        let sampleBRow = try XCTUnwrap(
            controller.testingSampleDetailRows(sample: "Sample-B").first {
                $0.locus == "MHC-B" && $0.slot == .h1
            }
        )
        let inspectorBeforeMatrixSave = inspectorNotifications
        XCTAssertNil(
            controller.testingSaveSampleDetailOverrideWithoutPresentingSheet(
                sample: "Sample-B",
                row: sampleBRow,
                target: "D1-review"
            )
        )
        XCTAssertEqual(
            inspectorNotifications,
            inspectorBeforeMatrixSave + 1
        )
        XCTAssertEqual(workbookActions, [.markDirty, .markDirty])
        XCTAssertEqual(
            controller.testingLastEffectiveHaplotypeMutationChangedKeys,
            [.init(sample: "Sample-B", locus: "MHC-B", slot: .h1)]
        )
        XCTAssertEqual(
            controller.testingLastEffectiveHaplotypeRefreshedKeys,
            [.init(sample: "Sample-B", locus: "MHC-B", slot: .h1)]
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandInvalidatedSamples,
            ["Sample-B"]
        )
        XCTAssertTrue(
            matrixWindow.firstResponder === targetButton,
            "Refreshing one band target must retain keyboard focus."
        )
        XCTAssertEqual(
            matrix.testingHaplotypeBandValue(
                sample: "Sample-B", locus: "MHC-B", slot: .h1
            ),
            .init(
                value: "D1-review", status: .called,
                source: .analystOverride, isEditable: true
            )
        )
        XCTAssertEqual(
            matrix.testingHaplotypeBandValue(
                sample: "Sample-B", locus: "MHC-A", slot: .h1
            )?.value,
            "C1"
        )

        state.summaryViewMode = .outline
        controller.testingApplyDisplayState(state)
        XCTAssertEqual(
            controller.testingSampleDetailRows(sample: "Sample-B")
                .first { $0.locus == "MHC-B" && $0.slot == .h1 }?.callName,
            "D1-review"
        )
        XCTAssertEqual(
            controller.testingSampleDetailRows(sample: "Sample-A")
                .first { $0.locus == "MHC-B" && $0.slot == .h2 }?.source,
            .pipeline
        )

        let sampleAH1 = try XCTUnwrap(
            controller.testingSampleDetailRows(sample: "Sample-A").first {
                $0.locus == "MHC-A" && $0.slot == .h1
            }
        )
        let inspectorBeforeCallsRestore = inspectorNotifications
        XCTAssertNil(
            controller.testingClearSampleDetailOverrideWithoutPresentingSheet(
                sample: "Sample-A",
                row: sampleAH1
            )
        )
        XCTAssertEqual(
            inspectorNotifications,
            inspectorBeforeCallsRestore + 1
        )
        XCTAssertEqual(workbookActions, [.markDirty, .markDirty, .markDirty])
        XCTAssertEqual(
            controller.testingLastEffectiveHaplotypeMutationChangedKeys,
            [.init(sample: "Sample-A", locus: "MHC-A", slot: .h1)]
        )

        state.summaryViewMode = .matrix
        controller.testingApplyDisplayState(state)
        let sampleBH1 = try XCTUnwrap(
            controller.testingSampleDetailRows(sample: "Sample-B").first {
                $0.locus == "MHC-B" && $0.slot == .h1
            }
        )
        let inspectorBeforeMatrixRestore = inspectorNotifications
        XCTAssertNil(
            controller.testingClearSampleDetailOverrideWithoutPresentingSheet(
                sample: "Sample-B",
                row: sampleBH1
            )
        )
        XCTAssertEqual(
            inspectorNotifications,
            inspectorBeforeMatrixRestore + 1
        )
        XCTAssertEqual(
            workbookActions,
            [.markDirty, .markDirty, .markDirty, .markDirty]
        )

        let recreated = GenotypeResultViewController()
        _ = recreated.view
        recreated.configure(result: result)
        let finalRows = recreated.testingSampleDetailRows(sample: "Sample-A")
        XCTAssertEqual(
            finalRows.first { $0.locus == "MHC-A" && $0.slot == .h1 }?.callName,
            "A1"
        )
        XCTAssertEqual(
            finalRows.first { $0.locus == "MHC-A" && $0.slot == .h2 }?.callName,
            "A2-review"
        )
        XCTAssertEqual(
            recreated.testingSampleDetailRows(sample: "Sample-B")
                .first { $0.locus == "MHC-B" && $0.slot == .h1 }?.callName,
            "D1"
        )
        let persisted = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            ))
        )
        XCTAssertTrue(persisted.manualHaplotypeAssignments.isEmpty)
        XCTAssertEqual(persisted.callOverrides.count, 1)
        let nextPublication = try XCTUnwrap(workbookRequests.last?.snapshot)
        XCTAssertEqual(nextPublication.haplotypeProjectionMode, .haplotyped)
        XCTAssertEqual(nextPublication.includedLoci, ["MHC-A", "MHC-B"])
        XCTAssertEqual(
            nextPublication.annotationSidecarURL,
            bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            ).standardizedFileURL
        )
        XCTAssertEqual(
            try GenotypeAnnotationSidecar.decode(
                nextPublication.annotationSidecarData
            ),
            persisted
        )
        XCTAssertEqual(nextPublication.calls, [
            .init(
                sample: "Sample-A", locus: "MHC-A",
                haplotype1: "A1", haplotype2: "A2-review",
                status: "called", notes: ""
            ),
            .init(
                sample: "Sample-A", locus: "MHC-B",
                haplotype1: "B1", haplotype2: "B2",
                status: "called", notes: ""
            ),
            .init(
                sample: "Sample-B", locus: "MHC-A",
                haplotype1: "C1", haplotype2: "C2",
                status: "called", notes: ""
            ),
            .init(
                sample: "Sample-B", locus: "MHC-B",
                haplotype1: "D1", haplotype2: "D2",
                status: "called", notes: ""
            ),
        ])

        let tape = GenotypeHaplotypeTapeView(
            frame: NSRect(x: 0, y: 0, width: 160, height: 40)
        )
        tape.sampleAccessibilityLabel = "Sample-A"
        tape.configure(loci: ["MHC-A"], slots: [
            .init(
                locus: "MHC-A",
                h1: .reference(tokenIndex: 1, label: "A1"),
                h2: .manual(tokenIndex: 2, label: "A2-review")
            ),
        ])
        var tapeActivations: [(String, HaplotypeSlot)] = []
        tape.onTargetActivated = { locus, slot in
            tapeActivations.append((locus, slot))
        }
        let tapeH2 = try XCTUnwrap(
            tape.testingTargetButton(locus: "MHC-A", slot: .h2)
        )
        let tapeWindow = NSWindow(
            contentRect: tape.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        tapeWindow.contentView = tape
        XCTAssertTrue(tapeWindow.makeFirstResponder(tapeH2))
        XCTAssertTrue(tapeH2.accessibilityPerformPress())
        XCTAssertEqual(tapeActivations.count, 1)
        XCTAssertEqual(tapeActivations.first?.0, "MHC-A")
        XCTAssertEqual(tapeActivations.first?.1, .h2)
        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))
        tapeH2.keyDown(with: space)
        XCTAssertEqual(tapeActivations.count, 2)
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        tapeH2.keyDown(with: returnKey)
        XCTAssertEqual(tapeActivations.count, 3)
        tape.configure(loci: ["MHC-A"], slots: [
            .init(
                locus: "MHC-A",
                h1: .reference(tokenIndex: 1, label: "A1"),
                h2: .manual(tokenIndex: 2, label: "A2-review")
            ),
        ])
        XCTAssertTrue(tapeWindow.firstResponder === tapeH2)
        XCTAssertTrue(
            (tapeH2.accessibilityLabel() ?? "").contains(
                "Sample-A MHC-A H2 A2-review status called source analyst override"
            )
        )
    }


    func testHaplotypedMiSeqIncludedLociStaySynchronizedAcrossCallsBandAndWorkbook()
        throws {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)

        var state = GenotypeResultDisplayState()
        state.summaryViewMode = .matrix
        state.manualHaplotypeBandExpanded = true
        controller.testingApplyDisplayState(state)
        let matrix = controller.testingComparisonMatrix
        XCTAssertEqual(matrix.testingHaplotypeBandLoci, ["MHC-A", "MHC-B"])

        state.includedLoci = ["MHC-B"]
        controller.testingApplyDisplayState(state)

        XCTAssertEqual(
            controller.testingOutlineSlots(sample: "Sample-A").map(\.locus),
            ["MHC-B"]
        )
        XCTAssertEqual(matrix.testingHaplotypeBandLoci, ["MHC-B"])
        XCTAssertEqual(
            controller.testingCurrentWorkbookHaplotypeCalls().map(\.locus),
            ["MHC-B", "MHC-B"]
        )
        XCTAssertEqual(
            Set(controller.testingCurrentWorkbookHaplotypeCalls().map(\.locus)),
            ["MHC-B"]
        )
    }


    func testHaplotypedMiSeqOverrideReappliesSmartCohortAndQuickSearchToMatrix()
        throws {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        controller.testingApplySmartCohort(.init(
            name: "Reviewed D1",
            description: "",
            scope: "bundle",
            isStarred: false,
            predicate: .hasHaplotypeAt(
                locus: "MHC-B",
                slot: .h1,
                names: ["D1-review"]
            )
        ))
        controller.testingSetQuickFilterSearchText("D1-review")
        XCTAssertTrue(controller.testingVisibleOutlineSamples.isEmpty)
        controller.testingApplyDisplayState(
            GenotypeResultDisplayState(summaryViewMode: .matrix)
        )
        XCTAssertTrue(controller.testingVisibleMatrixSamples.isEmpty)

        let row = try XCTUnwrap(
            controller.testingSampleDetailRows(sample: "Sample-B").first {
                $0.locus == "MHC-B" && $0.slot == .h1
            }
        )
        controller.testingResetSynchronizedMiSeqPerformanceCounters()
        XCTAssertNil(
            controller.testingSaveSampleDetailOverrideWithoutPresentingSheet(
                sample: "Sample-B",
                row: row,
                target: "D1-review",
                rationale: "Enter active shared filters"
            )
        )

        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["Sample-B"])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["Sample-B"])
        XCTAssertEqual(
            controller.testingSynchronizedMiSeqPerformanceSnapshot
                .columnRebuildCount,
            1,
            "Matrix columns should rebuild when effective-call cohort membership changes."
        )

        controller.testingResetSynchronizedMiSeqPerformanceCounters()
        XCTAssertNil(
            controller.testingSaveSampleDetailOverrideWithoutPresentingSheet(
                sample: "Sample-B",
                row: row,
                target: "D1-review",
                rationale: "Metadata-only rationale correction"
            )
        )
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["Sample-B"])
        XCTAssertEqual(
            controller.testingSynchronizedMiSeqPerformanceSnapshot
                .columnRebuildCount,
            0,
            "Reapplying unchanged membership must not rebuild matrix columns."
        )
    }


    func testHaplotypedMiSeqBandSelectionCarriesH2IntoCallEvidence() throws {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        var state = GenotypeResultDisplayState(summaryViewMode: .matrix)
        state.manualHaplotypeBandExpanded = true
        controller.testingApplyDisplayState(state)
        let target = GenotypeHaplotypeBandTarget(
            sample: "Sample-B",
            locus: "MHC-B",
            slot: .h2
        )
        let button = try XCTUnwrap(
            controller.testingComparisonMatrix
                .testingHaplotypeBandHitTarget(target)
        )

        XCTAssertTrue(button.accessibilityPerformPress())

        XCTAssertEqual(
            controller.callEvidence(sample: "Sample-B", locus: "MHC-B")?.slot,
            .h2
        )
    }


    func testHaplotypedMiSeqNoOpPublishesNothing() throws {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        var inspectorNotifications = 0
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
        controller.onAnnotationSidecarChanged = { _ in
            inspectorNotifications += 1
        }
        controller.onCurrentWorkbookSyncRequested = {
            workbookActions.append($0.action)
        }
        let row = try XCTUnwrap(
            controller.testingSampleDetailRows(sample: "Sample-B").first {
                $0.locus == "MHC-A" && $0.slot == .h1
            }
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(
            for: annotationURL
        )
        let annotationBefore = try Data(contentsOf: annotationURL)
        let provenanceBefore = try Data(contentsOf: provenanceURL)

        XCTAssertNil(
            controller.testingClearSampleDetailOverrideWithoutPresentingSheet(
                sample: "Sample-B",
                row: row
            )
        )

        let detailPresentationsBefore =
            controller.testingSampleDetailSheetPresentationCount
        controller.testingClearSampleDetailOverrideThroughSheetPath(
            sample: "Sample-B",
            row: row
        )

        XCTAssertEqual(inspectorNotifications, 0)
        XCTAssertTrue(workbookActions.isEmpty)
        XCTAssertEqual(
            controller.testingSampleDetailSheetPresentationCount,
            detailPresentationsBefore,
            "A no-op Restore Pipeline Call must preserve the open sheet and its draft/focus."
        )
        XCTAssertTrue(
            controller.testingLastEffectiveHaplotypeMutationChangedKeys.isEmpty
        )
        XCTAssertTrue(
            controller.testingLastEffectiveHaplotypeRefreshedKeys.isEmpty
        )
        XCTAssertEqual(try Data(contentsOf: annotationURL), annotationBefore)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), provenanceBefore)
    }


    func testHaplotypedMiSeqMetadataOnlyMutationInvalidatesReturnedKey()
        throws {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        var state = GenotypeResultDisplayState()
        state.summaryViewMode = .matrix
        state.manualHaplotypeBandExpanded = true
        controller.testingApplyDisplayState(state)
        let matrix = controller.testingComparisonMatrix
        let row = try XCTUnwrap(
            controller.testingSampleDetailRows(sample: "Sample-B").first {
                $0.locus == "MHC-B" && $0.slot == .h1
            }
        )
        XCTAssertNil(
            controller.testingSaveSampleDetailOverrideWithoutPresentingSheet(
                sample: "Sample-B",
                row: row,
                target: "D1-review",
                rationale: "Initial review rationale"
            )
        )
        matrix.testingResetManualHaplotypeBandInvalidations()

        XCTAssertNil(
            controller.testingSaveSampleDetailOverrideWithoutPresentingSheet(
                sample: "Sample-B",
                row: row,
                target: "D1-review",
                rationale: "Corrected review rationale"
            )
        )

        let changedKey = GenotypeEffectiveHaplotypeKey(
            sample: "Sample-B", locus: "MHC-B", slot: .h1
        )
        XCTAssertEqual(
            controller.testingLastEffectiveHaplotypeMutationChangedKeys,
            [changedKey]
        )
        XCTAssertEqual(
            controller.testingLastEffectiveHaplotypeRefreshedKeys,
            [changedKey]
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandInvalidatedSamples,
            ["Sample-B"]
        )
    }


    func testHaplotypedMiSeqMissingStorePresentsOneError() throws {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        controller.testingSelectCellEvidence(
            animalId: "Sample-A",
            locus: "MHC-A"
        )
        var presentedErrors: [Error] = []
        controller.testingSetSheetAlertHandler {
            presentedErrors.append($0)
        }
        controller.testingRemoveEffectiveHaplotypeAnnotationStore()

        controller.testingApplyOverrideFromInspector(
            haplotype: "A1-review",
            slot: .h1
        )

        XCTAssertEqual(presentedErrors.count, 1)
        XCTAssertTrue(
            presentedErrors[0].localizedDescription
                .localizedCaseInsensitiveContains("store")
        )
    }


    func testHaplotypedMiSeqRenderedEvidenceRetainsPendingDraftAcrossNoOpAndFailures()
        throws {
        do {
            let fixture = try makeSynchronizedMiSeqFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: fixture.result)
            controller.testingSelectCellEvidence(
                animalId: "Sample-A",
                locus: "MHC-A"
            )
            let staleRenderedView =
                controller.testingCallEvidenceRootView(pendingRequests: [
                    .init(slot: .h1, haplotypeName: "A3"),
                ])
            controller.testingApplyOverrideFromInspector(
                haplotype: "A3",
                slot: .h1
            )

            try assertRenderedEvidenceSubmissionRetainsPendingDraft(
                staleRenderedView
            )

            XCTAssertTrue(
                controller
                    .testingLastEffectiveHaplotypeMutationChangedKeys
                    .isEmpty
            )
            XCTAssertTrue(
                controller.testingLastEffectiveHaplotypeRefreshedKeys.isEmpty
            )
        }

        do {
            let fixture = try makeSynchronizedMiSeqFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: fixture.result)
            controller.testingSelectCellEvidence(
                animalId: "Sample-A",
                locus: "MHC-A"
            )
            let faultingStore = try GenotypeAnnotationStore(
                bundleURL: fixture.bundleURL,
                author: "Faulting Analyst",
                seedBuiltInSmartCohorts: false,
                publicationFaultInjector: { point in
                    point == .beforeProvenancePublication
                        ? WorkbookSnapshotEncodingTestError.injected
                        : nil
                }
            )
            controller.testingInstallEffectiveHaplotypeAnnotationStore(
                faultingStore
            )
            var errors: [Error] = []
            controller.testingSetSheetAlertHandler { errors.append($0) }

            try assertRenderedEvidenceSubmissionRetainsPendingDraft(
                controller.testingCallEvidenceRootView(pendingRequests: [
                    .init(slot: .h1, haplotypeName: "A3"),
                ])
            )

            XCTAssertEqual(errors.count, 2)
        }

        do {
            let fixture = try makeSynchronizedMiSeqFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: fixture.result)
            controller.testingSelectCellEvidence(
                animalId: "Sample-A",
                locus: "MHC-A"
            )
            controller.testingRemoveEffectiveHaplotypeAnnotationStore()
            var errors: [Error] = []
            controller.testingSetSheetAlertHandler { errors.append($0) }

            try assertRenderedEvidenceSubmissionRetainsPendingDraft(
                controller.testingCallEvidenceRootView(pendingRequests: [
                    .init(slot: .h1, haplotypeName: "A3"),
                ])
            )

            XCTAssertEqual(errors.count, 2)
        }

        do {
            let fixture = try makeSynchronizedMiSeqFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: fixture.result)
            controller.testingSelectCellEvidence(
                animalId: "Sample-A",
                locus: "MHC-A"
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: fixture.bundleURL.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: fixture.bundleURL.path
                )
            }
            let readOnlyStore = try GenotypeAnnotationStore(
                bundleURL: fixture.bundleURL,
                author: "Read-only Analyst",
                seedBuiltInSmartCohorts: false
            )
            controller.testingInstallEffectiveHaplotypeAnnotationStore(
                readOnlyStore
            )
            var errors: [Error] = []
            controller.testingSetSheetAlertHandler { errors.append($0) }

            try assertRenderedEvidenceSubmissionRetainsPendingDraft(
                controller.testingCallEvidenceRootView(pendingRequests: [
                    .init(slot: .h1, haplotypeName: "A3"),
                ])
            )

            XCTAssertEqual(errors.count, 2)
        }
    }


    func testHaplotypedMiSeqRenderedSampleDetailRetainsDraftForNoOpAndFailure()
        throws {
        do {
            let fixture = try makeSynchronizedMiSeqFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: fixture.result)
            let row = try XCTUnwrap(
                controller.testingSampleDetailRows(sample: "Sample-A").first {
                    $0.locus == "MHC-A" && $0.slot == .h1
                }
            )
            XCTAssertNil(
                controller.testingSaveSampleDetailOverrideWithoutPresentingSheet(
                    sample: "Sample-A",
                    row: row,
                    target: "A3"
                )
            )
            let renderedView = try XCTUnwrap(
                controller.testingSampleDetailRootView(sample: "Sample-A")
            )

            try assertRenderedSampleDetailSaveRetainsDraft(
                renderedView,
                row: row
            )

            XCTAssertTrue(
                controller.testingLastEffectiveHaplotypeMutationChangedKeys
                    .isEmpty
            )
            XCTAssertTrue(
                controller.testingLastEffectiveHaplotypeRefreshedKeys.isEmpty
            )
        }

        do {
            let fixture = try makeSynchronizedMiSeqFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: fixture.result)
            let row = try XCTUnwrap(
                controller.testingSampleDetailRows(sample: "Sample-A").first {
                    $0.locus == "MHC-A" && $0.slot == .h1
                }
            )
            XCTAssertNil(
                controller.testingSaveSampleDetailOverrideWithoutPresentingSheet(
                    sample: "Sample-A",
                    row: row,
                    target: "A3"
                )
            )
            let staleRenderedView = try XCTUnwrap(
                controller.testingSampleDetailRootView(sample: "Sample-A")
            )
            XCTAssertNil(
                controller.testingSaveSampleDetailOverrideWithoutPresentingSheet(
                    sample: "Sample-A",
                    row: row,
                    target: "A4"
                )
            )
            let faultingStore = try GenotypeAnnotationStore(
                bundleURL: fixture.bundleURL,
                author: "Faulting Analyst",
                seedBuiltInSmartCohorts: false,
                publicationFaultInjector: { point in
                    point == .beforeProvenancePublication
                        ? WorkbookSnapshotEncodingTestError.injected
                        : nil
                }
            )
            controller.testingInstallEffectiveHaplotypeAnnotationStore(
                faultingStore
            )
            var errors: [Error] = []
            controller.testingSetSheetAlertHandler { errors.append($0) }

            try assertRenderedSampleDetailSaveRetainsDraft(
                staleRenderedView,
                row: row
            )

            XCTAssertEqual(errors.count, 2)
        }
    }


    func testHaplotypedMiSeqPublicationFaultPreservesSynchronizedState()
        throws {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        controller.testingSelectCellEvidence(
            animalId: "Sample-A",
            locus: "MHC-B"
        )
        var state = GenotypeResultDisplayState()
        state.summaryViewMode = .matrix
        state.manualHaplotypeBandExpanded = true
        controller.testingApplyDisplayState(state)
        let matrix = try XCTUnwrap(
            controller.view.firstDescendant(
                ofType: GenotypeComparisonMatrixView.self
            )
        )
        let focusedTarget = try XCTUnwrap(
            matrix.testingHaplotypeBandHitTarget(.init(
                sample: "Sample-A",
                locus: "MHC-B",
                slot: .h1
            ))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        XCTAssertTrue(window.makeFirstResponder(focusedTarget))
        let faultingStore = try GenotypeAnnotationStore(
            bundleURL: fixture.bundleURL,
            author: "Faulting Analyst",
            seedBuiltInSmartCohorts: false,
            publicationFaultInjector: { point in
                point == .beforeProvenancePublication
                    ? WorkbookSnapshotEncodingTestError.injected
                    : nil
            }
        )
        controller.testingInstallEffectiveHaplotypeAnnotationStore(
            faultingStore
        )
        var inspectorNotifications = 0
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
        controller.onAnnotationSidecarChanged = { _ in
            inspectorNotifications += 1
        }
        controller.onCurrentWorkbookSyncRequested = {
            workbookActions.append($0.action)
        }
        let row = try XCTUnwrap(
            controller.testingSampleDetailRows(sample: "Sample-A").first {
                $0.locus == "MHC-B" && $0.slot == .h1
            }
        )
        let rowsBefore = controller.testingSampleDetailRows(
            sample: "Sample-A"
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(
            for: annotationURL
        )
        let annotationBefore = try Data(contentsOf: annotationURL)
        let provenanceBefore = try Data(contentsOf: provenanceURL)

        XCTAssertNotNil(
            controller.testingSaveSampleDetailOverrideWithoutPresentingSheet(
                sample: "Sample-A",
                row: row,
                target: "B1-fault"
            )
        )

        XCTAssertEqual(
            controller.testingSampleDetailRows(sample: "Sample-A"),
            rowsBefore
        )
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingOutlineSelectedSample, "Sample-A")
        XCTAssertEqual(controller.testingOutlineSelectedLocus, "MHC-B")
        XCTAssertTrue(window.firstResponder === focusedTarget)
        XCTAssertEqual(inspectorNotifications, 0)
        XCTAssertTrue(workbookActions.isEmpty)
        XCTAssertTrue(
            controller.testingLastEffectiveHaplotypeMutationChangedKeys.isEmpty
        )
        XCTAssertTrue(
            controller.testingLastEffectiveHaplotypeRefreshedKeys.isEmpty
        )
        XCTAssertEqual(try Data(contentsOf: annotationURL), annotationBefore)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), provenanceBefore)
    }


    func testHaplotypedMiSeqReadOnlyEditPreservesSynchronizedState()
        throws {
        let fixture = try makeSynchronizedMiSeqFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        var state = GenotypeResultDisplayState()
        state.summaryViewMode = .matrix
        state.manualHaplotypeBandExpanded = true
        controller.testingApplyDisplayState(state)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: fixture.bundleURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.bundleURL.path
            )
        }
        let readOnlyStore = try GenotypeAnnotationStore(
            bundleURL: fixture.bundleURL,
            author: "Read-only Analyst",
            seedBuiltInSmartCohorts: false
        )
        XCTAssertTrue(readOnlyStore.isReadOnly)
        controller.testingInstallEffectiveHaplotypeAnnotationStore(
            readOnlyStore
        )
        var inspectorNotifications = 0
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
        controller.onAnnotationSidecarChanged = { _ in
            inspectorNotifications += 1
        }
        controller.onCurrentWorkbookSyncRequested = {
            workbookActions.append($0.action)
        }
        let matrix = try XCTUnwrap(
            controller.view.firstDescendant(
                ofType: GenotypeComparisonMatrixView.self
            )
        )
        XCTAssertEqual(
            matrix.testingHaplotypeBandValue(
                sample: "Sample-A", locus: "MHC-B", slot: .h1
            )?.isEditable,
            false
        )
        let row = try XCTUnwrap(
            controller.testingSampleDetailRows(sample: "Sample-A").first {
                $0.locus == "MHC-B" && $0.slot == .h1
            }
        )
        let rowsBefore = controller.testingSampleDetailRows(
            sample: "Sample-A"
        )
        let annotationURL = fixture.bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(
            for: annotationURL
        )
        let annotationBefore = try Data(contentsOf: annotationURL)
        let provenanceBefore = try Data(contentsOf: provenanceURL)

        XCTAssertEqual(
            controller.testingSaveSampleDetailOverrideWithoutPresentingSheet(
                sample: "Sample-A",
                row: row,
                target: "B1-read-only"
            ) as? CallOverrideMutationError,
            .readOnly
        )

        XCTAssertEqual(
            controller.testingSampleDetailRows(sample: "Sample-A"),
            rowsBefore
        )
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(inspectorNotifications, 0)
        XCTAssertTrue(workbookActions.isEmpty)
        XCTAssertTrue(
            controller.testingLastEffectiveHaplotypeMutationChangedKeys.isEmpty
        )
        XCTAssertTrue(
            controller.testingLastEffectiveHaplotypeRefreshedKeys.isEmpty
        )
        XCTAssertEqual(try Data(contentsOf: annotationURL), annotationBefore)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), provenanceBefore)
    }
}
