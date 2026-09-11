import AppKit
import XCTest
import LungfishIO
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeExcelDialogBehaviorTests: XCTestCase {
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

    func testCapturedScopeIncludesDenominatorSearchVisibilityAndLegacyCapability() {
        let call = GenotypeViewProjectionHaplotypeCall(
            sample: "S1", locus: "A", haplotype1: "new", haplotype2: "old",
            haplotype1Status: "manual", haplotype2Status: "called",
            haplotype1Source: "manual override", haplotype2Source: "raw",
            baselineHaplotype1: "", baselineHaplotype2: "old"
        )
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/a.lungfish"), analysisName: "A", lens: "matrix",
            filters: [
                "matrixMinimumReads": "9", "matrixMinimumPercent": "12.5",
                "matrixPercentDenominator": "Viewed Locus", "searchText": "needle",
                "hideLowSupport": "true",
            ], sampleNames: ["matrix-axis"], rows: [], haplotypeCalls: [call],
            haplotypeSampleScope: ["S1"], haplotypeLocusScope: ["A"]
        )
        let presentation = GenotypeExcelCapturedScope(snapshot: snapshot)
        XCTAssertTrue(presentation.summary.contains("Samples (1): S1"))
        XCTAssertTrue(presentation.summary.contains("Loci (1): A"))
        XCTAssertTrue(presentation.summary.contains("matrixPercentDenominator=Viewed Locus"))
        XCTAssertTrue(presentation.summary.contains("searchText=needle"))
        XCTAssertTrue(presentation.summary.contains("hideLowSupport=true"))
        XCTAssertTrue(presentation.capability.contains("read-only"))
        XCTAssertTrue(presentation.capability.contains("matrix reviews and comments remain supported"))
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
