import XCTest
import AppKit
import SwiftUI
import LungfishIO
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeManualHaplotypingSectionTests: XCTestCase {
    func testRendersExportOnlyEmptyStateWithoutBulkCreator() {
        let view = GenotypeManualHaplotypingSection(
            manualAssignments: [],
            onExportDefinitions: {}
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        XCTAssertGreaterThan(host.frame.width, 0)
        XCTAssertTrue(view.exportIsDisabled)
    }

    func testRendersCanonicalAssignmentsAndKeepsExportAvailable() {
        let assignments = [
            ManualHaplotypeAssignment(
                sample: "S1", locus: "MHC-A", slot: .h1,
                label: "Custom-A1", colorTokenIndex: 2,
                diagnosticAlleles: ["01_X_0001"], notes: ""
            )
        ]
        let view = GenotypeManualHaplotypingSection(
            manualAssignments: assignments,
            onExportDefinitions: {}
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        XCTAssertGreaterThan(host.frame.width, 0)
        XCTAssertFalse(view.exportIsDisabled)
        XCTAssertEqual(view.assignmentSummary, "1 canonical assignment")
    }
}
