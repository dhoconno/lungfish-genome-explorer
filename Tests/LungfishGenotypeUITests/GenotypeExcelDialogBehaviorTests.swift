import AppKit
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeExcelDialogBehaviorTests: GenotypeResultViewportTestCase {
    func testControllerUsesCanonicalCallCapabilityWhenManualCallsAreFilteredOut() throws {
        let root = try TestTempDirectory.make(prefix: "ExcelManualCapability")
        defer { TestTempDirectory.cleanup(root) }
        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype, workflowMode: .genotypeOnly,
            outputName: "manual", analysisName: "Manual", primaryWorkbookPath: "manual.xlsx",
            longSummaryCSVPath: "calls.csv", sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json", provenancePath: "provenance.json"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [makeCall(sample: "AnimalA", genotype: "FIRST", reads: 9)], manifest: manifest))
        var state = controller.testingDisplayState
        state.matrixMinimumReads = 100
        controller.testingApplyDisplayStateImmediately(state)
        XCTAssertEqual(controller.testingCurrentExportSnapshot()?.rows.count, 0)
        var description = ""
        controller.excelChoicePresenter = { alert, _, completion in
            description = alert.informativeText
            completion(.alertSecondButtonReturn)
        }
        controller.presentExcelExportDialog(expectedDisplayState: state)
        XCTAssertTrue(description.contains("H1/H2 calls are read-only"))
        XCTAssertTrue(description.contains("matrix reviews and comments remain supported"))
    }

    func testControllerKeepsCapturedSnapshotThroughChoiceAndSavePanelDelays() async throws {
        let root = try TestTempDirectory.make(prefix: "ExcelPanelCapture")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "FIRST", reads: 9),
            makeCall(sample: "AnimalB", genotype: "SECOND", reads: 5),
        ]))
        var state = controller.testingDisplayState
        state.matrixMinimumReads = 7
        controller.testingApplyDisplayStateImmediately(state)
        var choose: ((NSApplication.ModalResponse) -> Void)?
        var save: ((URL?) -> Void)?
        var presentedScope = ""
        controller.excelChoicePresenter = { alert, _, completion in
            presentedScope = alert.informativeText
            choose = completion
        }
        controller.excelSavePanelPresenter = { panel, _, completion in
            XCTAssertEqual(panel.prompt, "Export")
            XCTAssertTrue(panel.nameFieldStringValue.hasSuffix("-filtered-pivot.xlsx"))
            save = completion
        }
        let exported = expectation(description: "production controller finished export")
        let output = root.appendingPathComponent("filtered.xlsx")
        var events: [String] = []
        controller.onFilteredWorkbookExportEvent = { event in
            switch event {
            case .started: events.append("started")
            case .succeeded(let url):
                XCTAssertEqual(url, output)
                events.append("succeeded")
                exported.fulfill()
            case .failed(let error): XCTFail(error)
            }
        }
        controller.viewportExportRunner = { snapshot, format, url in
            XCTAssertEqual(format, .pivotExcel)
            XCTAssertEqual(url, output)
            XCTAssertEqual(snapshot.filters["matrixMinimumReads"], "7")
            XCTAssertEqual(snapshot.rows.map(\.genotype), ["FIRST"])
            try Data("captured reads=7".utf8).write(to: url)
        }
        controller.presentExcelExportDialog(expectedDisplayState: state)
        XCTAssertTrue(presentedScope.contains("7"))
        state.matrixMinimumReads = 0
        controller.testingApplyDisplayStateImmediately(state)
        try XCTUnwrap(choose)(.alertFirstButtonReturn)
        state.matrixMinimumReads = 100
        controller.testingApplyDisplayStateImmediately(state)
        XCTAssertTrue(events.isEmpty)
        try XCTUnwrap(save)(output)
        await fulfillment(of: [exported], timeout: 2)
        XCTAssertEqual(events, ["started", "succeeded"])
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "captured reads=7")
    }

    func testControllerCancelsBothDialogsWithoutExportAndEditableChoiceEmitsOpenRequest() throws {
        let root = try TestTempDirectory.make(prefix: "ExcelPanelCancel")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [makeCall(sample: "AnimalA", genotype: "FIRST", reads: 9)]))
        var choose: ((NSApplication.ModalResponse) -> Void)?
        var alert: NSAlert?
        var save: ((URL?) -> Void)?
        var saveCount = 0
        var exportCount = 0
        var requests: [GenotypeCurrentWorkbookUIRequest] = []
        controller.onCurrentWorkbookSyncRequested = { requests.append($0) }
        controller.viewportExportRunner = { _, _, _ in exportCount += 1 }
        controller.excelChoicePresenter = { shown, _, completion in alert = shown; choose = completion }
        controller.excelSavePanelPresenter = { _, _, completion in saveCount += 1; save = completion }
        controller.presentExcelExportDialog(expectedDisplayState: controller.testingDisplayState)
        try XCTUnwrap(choose)(.alertSecondButtonReturn)
        XCTAssertEqual(saveCount, 0)
        controller.presentExcelExportDialog(expectedDisplayState: controller.testingDisplayState)
        try XCTUnwrap(choose)(.alertFirstButtonReturn)
        try XCTUnwrap(save)(nil)
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(exportCount, 0)
        XCTAssertTrue(requests.isEmpty)
        controller.presentExcelExportDialog(expectedDisplayState: controller.testingDisplayState)
        let buttons = try XCTUnwrap(alert?.accessoryView as? NSStackView).arrangedSubviews.compactMap { $0 as? NSButton }
        buttons[1].performClick(nil)
        try XCTUnwrap(choose)(.alertFirstButtonReturn)
        XCTAssertEqual(requests.map(\.action), [.openEditable])
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(exportCount, 0)
    }

    private func snapshot(reads: String) -> GenotypeViewportExportSnapshot {
        GenotypeViewportExportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/a.lungfish"), analysisName: "A", lens: "matrix",
            filters: ["matrixMinimumReads": reads], sampleNames: [], rows: []
        )
    }

    func testActualAccessoryDefaultsFilteredAndRoutesBothEnabledRoles() throws {
        var roles: [GenotypeExcelExportRole] = []
        let accessory = GenotypeExcelExportAccessoryController(
            allowsEditableWorkbook: true,
            onRoleChange: { roles.append($0) }
        )
        accessory.loadView()
        let buttons = try XCTUnwrap((accessory.view as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton })
        XCTAssertEqual(accessory.role, .filteredView)
        XCTAssertEqual(buttons.map(\.keyEquivalent), ["", ""])
        XCTAssertTrue(buttons.allSatisfy(\.isEnabled))
        buttons[1].performClick(nil)
        buttons[0].performClick(nil)
        XCTAssertEqual(roles, [.editableWorkbook, .filteredView])
    }

    func testProductionAlertAssignsReturnAndEscapeAndDefaultsToFilteredRole() throws {
        let presentation = GenotypeExcelExportDialogPresenter.makeAlert(
            scope: "Captured scope", capability: "Supported", allowsEditableWorkbook: true,
            onRoleChange: { _ in }
        )
        XCTAssertEqual(presentation.alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(presentation.alert.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertEqual(presentation.accessory.role, .filteredView)
        XCTAssertEqual(presentation.alert.buttons[0].title, "Export…")
    }

    func testCapturedScopeIsBoundedHumanReadableAndUsesCanonicalWorkbookCapability() {
        let call = GenotypeViewProjectionHaplotypeCall(
            sample: "S1", locus: "A", haplotype1: "new", haplotype2: "old",
            haplotype1Status: "manual", haplotype2Status: "called",
            haplotype1Source: "pipeline", haplotype2Source: "pipeline",
            baselineHaplotype1: "", baselineHaplotype2: "old"
        )
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/a.lungfish"), analysisName: "A", lens: "matrix",
            filters: [
                "matrixMinimumReads": "9", "matrixMinimumPercent": "12.5",
                "matrixPercentDenominator": "Viewed Locus", "searchText": "needle",
                "hideLowSupport": "true",
                "internalEncodedPredicate": String(repeating: "x", count: 2_000),
            ], sampleNames: ["matrix-axis"], rows: [], haplotypeCalls: [call],
            haplotypeSampleScope: (1...100).map { "S\($0)" }, haplotypeLocusScope: ["A"]
        )
        let presentation = GenotypeExcelCapturedScope(snapshot: snapshot, callEditingSupported: true)
        XCTAssertTrue(presentation.summary.contains("Samples (100): S1"))
        XCTAssertTrue(presentation.summary.contains("Loci (1): A"))
        XCTAssertTrue(presentation.summary.contains("Percent basis: Viewed Locus"))
        XCTAssertTrue(presentation.summary.contains("Search: needle"))
        XCTAssertTrue(presentation.summary.contains("Low-support rows: hidden"))
        XCTAssertFalse(presentation.summary.contains("internalEncodedPredicate"))
        XCTAssertLessThan(presentation.summary.count, 1_000)
        XCTAssertTrue(presentation.capability.contains("H1/H2 call edits"))
    }

    func testOnlyFilteredWorkflowPublishesLatestFilteredEvents() {
        let controller = GenotypeResultViewController()
        var events = 0
        controller.onFilteredWorkbookExportEvent = { _ in events += 1 }
        controller.publishFilteredWorkbookExportEvent(.started, filteredWorkflow: false)
        XCTAssertEqual(events, 0)
        controller.publishFilteredWorkbookExportEvent(.started, filteredWorkflow: true)
        XCTAssertEqual(events, 1)
    }

    func testProductionDialogRouteCancelsWithoutEffectsAndReusesCapturedSnapshotForBothRoles() {
        let captured = snapshot(reads: "7")
        var filtered: [GenotypeViewportExportSnapshot] = []
        var opens = 0
        let route: (NSApplication.ModalResponse, GenotypeExcelExportRole?) -> Void = { response, role in
            GenotypeExcelExportDialogRoute.complete(
                response: response, role: role, snapshot: captured,
                exportFiltered: { filtered.append($0) }, openEditable: { opens += 1 }
            )
        }
        route(.alertSecondButtonReturn, .filteredView)
        XCTAssertTrue(filtered.isEmpty)
        XCTAssertEqual(opens, 0)
        route(.alertFirstButtonReturn, .filteredView)
        route(.alertFirstButtonReturn, .editableWorkbook)
        XCTAssertEqual(filtered, [captured])
        XCTAssertEqual(opens, 1)
    }
}
