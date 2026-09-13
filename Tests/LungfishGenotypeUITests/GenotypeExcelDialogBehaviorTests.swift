import AppKit
import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeExcelDialogBehaviorTests: GenotypeResultViewportTestCase {
    private var openpyxlPython: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_OPENPYXL_PYTHON"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
    }

    func testExportFreezesAllAndPositiveDisplayedVisibleEvidenceBeforeSavePanel() async throws {
        let root = try TestTempDirectory.make(prefix: "ExcelUnifiedCapture")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "Mafa-A1*001:01", reads: 9),
            makeCall(sample: "AnimalA", genotype: "Mafa-A1*002:01", reads: 1),
            makeCall(sample: "AnimalB", genotype: "Mafa-A1*003:01", reads: 8),
        ]))
        var state = controller.testingDisplayState
        state.matrixMinimumReads = 5
        state.matrixSampleFilterText = "AnimalA"
        controller.testingApplyDisplayStateImmediately(state)
        var save: ((URL?) -> Void)?
        controller.excelSavePanelPresenter = { _, _, completion in save = completion }
        let exported = expectation(description: "frozen scientific capture delivered")
        controller.viewportExportRunner = { snapshot, format, _ in
            defer { exported.fulfill() }
            XCTAssertEqual(format, .excel)
            let bytes = try XCTUnwrap(snapshot.excelSnapshotData)
            let capture = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self, from: bytes)
            XCTAssertEqual(capture.allMatrix.samples.map(\.name), ["AnimalA", "AnimalB"])
            XCTAssertEqual(capture.allMatrix.rows.count, 3)
            XCTAssertEqual(capture.filteredMatrix.samples.map(\.name), ["AnimalA"])
            XCTAssertEqual(capture.filteredMatrix.rows.count, 1)
            XCTAssertEqual(capture.filteredMatrix.rows.first?.cells.first?.displayValue, 9)
        }
        controller.presentExcelExportPanel(expectedDisplayState: state)
        state.matrixMinimumReads = 100
        controller.testingApplyDisplayStateImmediately(state)
        try XCTUnwrap(save)(root.appendingPathComponent("captured.xlsx"))
        await fulfillment(of: [exported], timeout: 2)
    }

    func testExportCapturesLocusSearchSampleAndManualVisibilityWithoutTruncatingAll() throws {
        let root = try TestTempDirectory.make(prefix: "ExcelVisibilityCapture")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_KEEP", reads: 9),
            makeCall(sample: "AnimalA", genotype: "02_Mafa_A1_HIDE", reads: 8),
            makeCall(sample: "AnimalB", genotype: "03_Mafa_A1_OTHER", reads: 7),
            makeCall(sample: "AnimalA", genotype: "04_Mafa_B1_OTHER", reads: 6),
        ]))
        controller.testingShowMatrixTargetSelection([.row(locus: "MHC-A", genotype: "02_Mafa_A1_HIDE")])
        controller.testingHideSelectedMatrixRows()
        var state = controller.testingDisplayState
        state.matrixMinimumReads = 5
        state.matrixSampleFilterText = "AnimalA"
        state.matrixRowFilterText = "Mafa_A1"
        controller.testingApplyDisplayStateImmediately(state)
        controller.testingComparisonMatrix.testingSetLocusFilter("MHC-A")
        controller.testingSetComparisonFilter("KEEP")
        let captured = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(controller.captureExcelExportSnapshot().excelSnapshotData))
        XCTAssertEqual(captured.allMatrix.rows.count, 4)
        XCTAssertEqual(captured.allMatrix.samples.map(\.name), ["AnimalA", "AnimalB"])
        XCTAssertEqual(captured.filteredMatrix.rows.map(\.target.genotype), ["01_Mafa_A1_KEEP"])
        XCTAssertEqual(captured.filteredMatrix.samples.map(\.name), ["AnimalA"])
        XCTAssertEqual(captured.filteredMatrix.rows[0].cells[0].displayValue, 9)
    }

    func testDuplicateOccurrencesCaptureNativeSelectionAndRenderLiteralWorkbooks() async throws {
        let root = try TestTempDirectory.make(prefix: "ExcelDuplicateOccurrences")
        defer { TestTempDirectory.cleanup(root) }
        let genotype = "Mafa-A*001"
        let result = makeResult(bundleURL: root, samples: [], calls: [
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: genotype, reads: 4, retainedReads: 40),
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: genotype, reads: 16, retainedReads: 1000),
        ])
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        var state = controller.testingDisplayState
        state.matrixMinimumPercent = 5
        state.matrixPercentDenominator = .sampleRetained
        controller.testingApplyDisplayStateImmediately(state)
        let thresholdNative = try XCTUnwrap(
            controller.testingComparisonMatrix.testingSemanticCellState(genotype: genotype, sample: "S1")
        )
        XCTAssertEqual(thresholdNative.text.value, "4")
        XCTAssertEqual(thresholdNative.evidenceReads, 4)
        let thresholdCapture = try controller.captureExcelExportSnapshot()
        let thresholdSnapshot = try JSONDecoder().decode(
            GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(thresholdCapture.excelSnapshotData)
        )
        let thresholdAll = try XCTUnwrap(thresholdSnapshot.allMatrix.rows.first?.cells.first)
        let thresholdFiltered = try XCTUnwrap(thresholdSnapshot.filteredMatrix.rows.first?.cells.first)
        XCTAssertEqual(thresholdAll.displayValue, 16)
        XCTAssertEqual(thresholdAll.rawSupport, 16)
        XCTAssertEqual(thresholdFiltered.displayValue, 4)
        XCTAssertEqual(thresholdFiltered.rawSupport, 16)
        let capturedResult = try JSONDecoder().decode(
            ONTGenotypeResultBundleData.self,
            from: XCTUnwrap(thresholdSnapshot.capturedScientificInputs?["result.json"])
        )
        XCTAssertEqual(capturedResult.calls.map(\.passedUniqueReads), [4, 16])
        XCTAssertEqual(capturedResult.calls.map(\.sampleUniqueRetainedReads), [40, 1000])

        let thresholdOutput = root.appendingPathComponent("threshold.xlsx")
        _ = try await GenotypeExcelExportService(pythonExecutableURL: openpyxlPython).export(
            snapshot: thresholdSnapshot,
            outputURL: thresholdOutput,
            provenance: .init(toolVersion: "test", argv: ["Lungfish", "genotype.export.excel"])
        )
        XCTAssertEqual(try workbookLiteral(thresholdOutput, sheet: "Genotype Matrix - All", genotype: genotype), 16)
        XCTAssertEqual(try workbookLiteral(thresholdOutput, sheet: "Genotype Matrix - Filtered", genotype: genotype), 4)

        state.matrixMinimumPercent = 0
        controller.testingApplyDisplayStateImmediately(state)
        let unfilteredNative = try XCTUnwrap(
            controller.testingComparisonMatrix.testingSemanticCellState(genotype: genotype, sample: "S1")
        )
        XCTAssertEqual(unfilteredNative.text.value, "16")
        XCTAssertEqual(unfilteredNative.evidenceReads, 16)
        let unfilteredCapture = try controller.captureExcelExportSnapshot()
        let unfilteredSnapshot = try JSONDecoder().decode(
            GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(unfilteredCapture.excelSnapshotData)
        )
        XCTAssertEqual(unfilteredSnapshot.allMatrix.rows.first?.cells.first?.displayValue, 16)
        XCTAssertEqual(unfilteredSnapshot.filteredMatrix.rows.first?.cells.first?.displayValue, 16)
        let unfilteredOutput = root.appendingPathComponent("unfiltered.xlsx")
        _ = try await GenotypeExcelExportService(pythonExecutableURL: openpyxlPython).export(
            snapshot: unfilteredSnapshot,
            outputURL: unfilteredOutput,
            provenance: .init(toolVersion: "test", argv: ["Lungfish", "genotype.export.excel"])
        )
        XCTAssertEqual(try workbookLiteral(unfilteredOutput, sheet: "Genotype Matrix - All", genotype: genotype), 16)
        XCTAssertEqual(try workbookLiteral(unfilteredOutput, sheet: "Genotype Matrix - Filtered", genotype: genotype), 16)
    }

    func testExportActionPresentsOneSavePanelWithoutRoleChoice() throws {
        let root = try TestTempDirectory.make(prefix: "ExcelOneAction")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "FIRST", reads: 9)
        ]))
        var panels = 0
        controller.excelSavePanelPresenter = { panel, _, completion in
            panels += 1
            XCTAssertEqual(panel.allowedContentTypes.first?.preferredFilenameExtension, "xlsx")
            completion(nil)
        }
        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        XCTAssertEqual(panels, 1)
    }

    func testSavePanelFromPreviousBundleCannotLaunchExport() async throws {
        let root = try TestTempDirectory.make(prefix: "ExcelPanelOrigin")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "FIRST", reads: 9)
        ]))
        var save: ((URL?) -> Void)?
        var exports = 0
        var events = 0
        controller.excelSavePanelPresenter = { _, _, completion in save = completion }
        controller.viewportExportRunner = { _, _, _ in exports += 1 }
        controller.onExcelExportEvent = { _ in events += 1 }
        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        let next = root.appendingPathComponent("next", isDirectory: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        controller.configure(result: makeResult(bundleURL: next, samples: [], calls: [
            makeCall(sample: "AnimalB", genotype: "SECOND", reads: 5)
        ]))
        try XCTUnwrap(save)(root.appendingPathComponent("obsolete.xlsx"))
        await Task.yield()
        XCTAssertEqual(exports, 0)
        XCTAssertEqual(events, 0)
    }

    func testCancelledSavePanelDoesNotExportOrChangeSuccessStatus() throws {
        let root = try TestTempDirectory.make(prefix: "ExcelCancel")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "FIRST", reads: 9)
        ]))
        var panels = 0
        controller.excelSavePanelPresenter = { _, _, completion in panels += 1; completion(nil) }
        controller.viewportExportRunner = { _, _, _ in XCTFail("Cancellation launched export") }
        controller.onExcelExportEvent = { _ in XCTFail("Cancellation changed export state") }
        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        XCTAssertEqual(panels, 1)
    }

    func testNativeAnnotationDoesNotRequestBackgroundWorkbookRegeneration() throws {
        let root = try TestTempDirectory.make(prefix: "ExcelNoSync")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "FIRST", reads: 9)
        ]))
        var requests = 0
        controller.editMatrixComment(.init(targets: [.column(sample: "AnimalA")], intent: .upsert(body: "Native review")))
        let saved = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: root)
        XCTAssertEqual(saved.resolvedMatrixComments[.column(sample: "AnimalA")]?.body, "Native review")
    }
    func testExportResolvesManualDraftSaveDiscardCancelAndFailedSave() async throws {
        for decision in [GenotypeManualHaplotypeDraftDecision.save, .discard, .cancel] {
            for invalid in (decision == .save ? [false, true] : [false]) {
                let root = try TestTempDirectory.make(prefix: "ExcelManualDraft")
                defer { TestTempDirectory.cleanup(root) }
                let controller = GenotypeResultViewController()
                _ = controller.view
                let result = makeResult(bundleURL: root, samples: [], calls: [
                    makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42)
                ])
                try ONTGenotypeResultBundle.writeManifest(result.manifest, to: root)
                try GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z").encoded().write(to: root.appendingPathComponent(GenotypeAnnotationSidecar.filename))
                controller.configure(result: result)
                controller.testingSelectMatrixColumn(sample: "AnimalA")
                controller.testingUpdateManualHaplotypeLabel(invalid ? String(repeating: "x", count: 129) : "Analyst-H1")
                XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
                var transitions: [String] = []
                controller.testingSetManualHaplotypeDraftDecisionProvider { transition in transitions.append(transition.rawValue); return decision }
                var panels = 0
                controller.excelSavePanelPresenter = { _, _, completion in panels += 1; completion(nil) }
                controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
                await controller.testingWaitForManualHaplotypeTransitions()
                XCTAssertEqual(transitions, ["export"])
                if decision == .save && !invalid { XCTAssertNil(controller.testingManualHaplotypeEditorPersistenceError) }
                XCTAssertEqual(panels, decision == .cancel || invalid ? 0 : 1)
                let assignments = controller.testingManualHaplotypeAssignments
                XCTAssertEqual(assignments.map(\.label), decision == .save && !invalid ? ["Analyst-H1"] : [])
                XCTAssertEqual(controller.testingManualHaplotypeEditorIsDirty, decision == .cancel || invalid)
            }
        }
    }

    func testExportResolvesEffectiveDraftSaveDiscardCancelAndFailedSave() async throws {
        for decision in [GenotypeManualHaplotypeDraftDecision.save, .discard, .cancel] {
            for invalid in (decision == .save ? [false, true] : [false]) {
                let root = try TestTempDirectory.make(prefix: "ExcelEffectiveDraft")
                defer { TestTempDirectory.cleanup(root) }
                let controller = GenotypeResultViewController()
                _ = controller.view
                let result = makeResult(bundleURL: root, samples: [], calls: [
                    makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42)
                ], haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis())
                try ONTGenotypeResultBundle.writeManifest(result.manifest, to: root)
                try GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z").encoded().write(to: root.appendingPathComponent(GenotypeAnnotationSidecar.filename))
                controller.configure(result: result)
                controller.testingShowMatrixTargetSelection([.column(sample: "AnimalA")])
                controller.testingUpdateEffectiveHaplotypeLabel(invalid ? "bad\nlabel" : "Analyst-H1", locus: "MHC-A", slot: .h1)
                XCTAssertTrue(controller.testingEffectiveHaplotypeEditorIsDirty)
                var transitions: [String] = []
                controller.testingSetManualHaplotypeDraftDecisionProvider { transition in transitions.append(transition.rawValue); return decision }
                var panels = 0
                controller.excelSavePanelPresenter = { _, _, completion in panels += 1; completion(nil) }
                controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
                await controller.testingWaitForManualHaplotypeTransitions()
                XCTAssertEqual(transitions, ["export"])
                XCTAssertEqual(panels, decision == .cancel || invalid ? 0 : 1)
                let captured = try controller.captureExcelExportSnapshot()
                let scientific = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self, from: XCTUnwrap(captured.excelSnapshotData))
                XCTAssertEqual(scientific.calls.first?.h1.effective, decision == .save && !invalid ? "Analyst-H1" : "M1A")
                XCTAssertEqual(controller.testingEffectiveHaplotypeEditorIsDirty, decision == .cancel || invalid)
            }
        }
    }

    func testExportCannotStartAfterOriginControllerIsSuperseded() throws {
        let root = try TestTempDirectory.make(prefix: "ExcelStaleController")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "FIRST", reads: 9)
        ]))
        var save: ((URL?) -> Void)?
        var active = true
        controller.excelSavePanelPresenter = { _, _, completion in save = completion }
        controller.viewportExportRunner = { _, _, _ in XCTFail("Obsolete controller launched export") }
        controller.onExcelExportEvent = { _ in XCTFail("Obsolete controller changed Inspector state") }
        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState, originStillCurrent: { active })
        active = false
        try XCTUnwrap(save)(root.appendingPathComponent("obsolete.xlsx"))
        save = nil
        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState, originStillCurrent: { active })
        XCTAssertNil(save)
    }

    func testAllCaptureIncludesCatalogOnlyEvidenceAndSamples() throws {
        let root = try TestTempDirectory.make(prefix: "ExcelCatalogComplete")
        defer { TestTempDirectory.cleanup(root) }
        let catalog = GenotypeReviewableRowCatalog(samples: ["AnimalA", "AnimalB"], rows: [
            .init(kind: .reference, callID: "Mafa-A1*002:01", displayName: "Mafa-A1*002:01", locus: "MHC-A",
                  stableID: nil, section: "reference", sortKey: "2", supportBySample: ["AnimalA": 0, "AnimalB": 0])
        ])
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "Mafa-A1*001:01", reads: 9)
        ], reviewableRowCatalog: catalog))
        let snapshot = try controller.captureExcelExportSnapshot()
        let scientific = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self, from: XCTUnwrap(snapshot.excelSnapshotData))
        XCTAssertEqual(scientific.allMatrix.samples.map(\.name), ["AnimalA", "AnimalB"])
        XCTAssertEqual(scientific.allMatrix.rows.map(\.target.genotype), ["Mafa-A1*001:01", "Mafa-A1*002:01"])
        XCTAssertEqual(scientific.allMatrix.rows.last?.cells.last?.rawSupport, 0)
        XCTAssertEqual(scientific.filteredMatrix.rows.count, 1)
    }

    func testAllCaptureMergesOverlappingCatalogCellsWithoutInventingUnknownEvidence() throws {
        let root = try TestTempDirectory.make(prefix: "ExcelCatalogOverlap")
        defer { TestTempDirectory.cleanup(root) }
        let first = "Mafa-A1*001:01"
        let second = "Mafa-A1*002:01"
        let catalog = GenotypeReviewableRowCatalog(samples: ["AnimalC", "AnimalB", "AnimalA"], rows: [
            .init(kind: .reference, callID: first, displayName: first, locus: "MHC-A",
                  stableID: nil, section: "reference", sortKey: "1",
                  supportBySample: ["AnimalA": 9, "AnimalB": 0, "AnimalC": 0])
        ])
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z")
        sidecar.matrixStyles = [
            .init(target: .row(locus: "MHC-A", genotype: first),
                  style: .init(isBold: true), author: "Analyst", timestamp: "2026-09-12T00:00:00Z"),
            .init(target: .cell(locus: "MHC-A", genotype: first, sample: "AnimalB"),
                  style: .init(isItalic: true), author: "Analyst", timestamp: "2026-09-12T00:00:00Z")
        ]
        try sidecar.encoded().write(to: root.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: first, reads: 9),
            makeCall(sample: "AnimalB", genotype: second, reads: 7)
        ], reviewableRowCatalog: catalog))
        var state = controller.testingDisplayState
        state.matrixSampleFilterText = "AnimalB"
        state.matrixMinimumReads = 5
        controller.testingApplyDisplayStateImmediately(state)
        let snapshot: GenotypeViewportExportSnapshot
        do { snapshot = try controller.captureExcelExportSnapshot() }
        catch { XCTFail("Valid overlapping catalog evidence must be exportable: \(error)"); return }
        let scientific = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(snapshot.excelSnapshotData))
        XCTAssertEqual(scientific.allMatrix.samples.map(\.name), ["AnimalA", "AnimalB", "AnimalC"])
        XCTAssertEqual(scientific.allMatrix.rows.map(\.target.genotype), [first, second])
        let overlap = scientific.allMatrix.rows[0]
        XCTAssertEqual(overlap.cells.map(\.displayValue), [9, 0, 0])
        XCTAssertEqual(overlap.cells.map(\.rawSupport), [9, 0, 0])
        XCTAssertTrue(overlap.cells.allSatisfy(\.reviewEligible))
        XCTAssertEqual(overlap.style?.isBold, true)
        XCTAssertEqual(overlap.cells[1].style?.isItalic, true)
        let sparse = scientific.allMatrix.rows[1]
        XCTAssertEqual(sparse.cells.map(\.displayValue), [nil, 7, nil])
        XCTAssertEqual(sparse.cells.map(\.rawSupport), [nil, 7, nil])
        XCTAssertEqual(sparse.cells.map(\.reviewEligible), [false, true, false])
        XCTAssertEqual(scientific.filteredMatrix.samples.map(\.name), ["AnimalB"])
        XCTAssertEqual(scientific.filteredMatrix.rows.map(\.target.genotype), [second])
        XCTAssertEqual(scientific.filteredMatrix.rows[0].cells[0].displayValue, 7)
    }

    func testImmediateExportSettlesPendingSharedSearch() throws {
        let root = try TestTempDirectory.make(prefix: "ExcelSharedSearch")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "Mafa-A1*001:01", reads: 9),
            makeCall(sample: "AnimalA", genotype: "Mafa-B1*001:01", reads: 7)
        ]))
        controller.testingTypeQuickSearchDebounced("Mafa-A1")
        let snapshot = try controller.captureExcelExportSnapshot()
        let scientific = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self, from: XCTUnwrap(snapshot.excelSnapshotData))
        XCTAssertEqual(scientific.filteredMatrix.rows.map(\.target.genotype), ["Mafa-A1*001:01"])
        XCTAssertEqual(scientific.allMatrix.rows.count, 2)
        XCTAssertEqual(snapshot.filters["quickFilterSearchText"], "Mafa-A1")
    }

    func testMountedManualFieldLastKeystrokeIsSavedBeforeCapture() async throws {
        let root = try TestTempDirectory.make(prefix: "ExcelNativeManual")
        defer { TestTempDirectory.cleanup(root) }
        let result = makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42)
        ])
        try ONTGenotypeResultBundle.writeManifest(result.manifest, to: root)
        try GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z").encoded().write(to: root.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: controller.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.orderOut(nil) }
        controller.configure(result: result)
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        let combo = try XCTUnwrap(controller.testingFirstManualHaplotypeComboBox)
        XCTAssertTrue(window.makeFirstResponder(combo))
        let editor = try XCTUnwrap(combo.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Native H1", replacementRange: editor.selectedRange())
        controller.testingSetManualHaplotypeDraftDecisionProvider { _ in .save }
        controller.excelSavePanelPresenter = { _, _, completion in completion(root.appendingPathComponent("snapshot.xlsx")) }
        let exported = expectation(description: "native final keystroke exported")
        controller.viewportExportRunner = { snapshot, _, _ in
            defer { exported.fulfill() }
            let scientific = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self, from: XCTUnwrap(snapshot.excelSnapshotData))
            XCTAssertEqual(scientific.calls.first?.h1.effective, "Native H1")
        }
        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        await fulfillment(of: [exported], timeout: 3)
        XCTAssertEqual(controller.testingManualHaplotypeAssignments.map(\.label), ["Native H1"])
    }

    private func workbookLiteral(_ workbook: URL, sheet: String, genotype: String) throws -> Int {
        let process = Process()
        process.executableURL = openpyxlPython
        process.arguments = ["-c", #"""
import json, openpyxl, sys
workbook = openpyxl.load_workbook(sys.argv[1], data_only=False)
sheet = workbook[sys.argv[2]]
matches = [row[3].value for row in sheet.iter_rows() if row[2].value == sys.argv[3]]
print(json.dumps(matches))
"""#, workbook.path, sheet, genotype]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Int])
        return try XCTUnwrap(values.count == 1 ? values.first : nil)
    }

}
