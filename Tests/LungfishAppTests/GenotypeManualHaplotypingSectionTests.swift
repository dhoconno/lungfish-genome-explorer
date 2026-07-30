import XCTest
import AppKit
import SwiftUI
import LungfishIO
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeManualHaplotypingSectionTests: XCTestCase {
    func testGenotypeOnlySectionRendersEmptyStateWithoutExport() {
        let view = GenotypeManualHaplotypingSection(
            manualAssignments: []
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.frame.width, 0)
        XCTAssertFalse(
            descendants(of: host)
                .compactMap { $0 as? NSButton }
                .contains {
                    $0.accessibilityIdentifier()
                        == "manual-haplotype-export-definitions"
                }
        )
    }

    func testRendersCanonicalAssignmentsWithoutGenotypeOnlyExport() {
        let assignments = [
            ManualHaplotypeAssignment(
                sample: "S1", locus: "MHC-A", slot: .h1,
                label: "Custom-A1", colorTokenIndex: 2,
                diagnosticAlleles: ["01_X_0001"], notes: ""
            )
        ]
        let view = GenotypeManualHaplotypingSection(
            manualAssignments: assignments
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.frame.width, 0)
        XCTAssertEqual(view.assignmentSummary, "1 canonical assignment")
        XCTAssertFalse(
            descendants(of: host)
                .compactMap { $0 as? NSButton }
                .contains {
                    $0.accessibilityIdentifier()
                        == "manual-haplotype-export-definitions"
                }
        )
    }

    func testLegacyHaplotypingSectionKeepsExport() {
        let assignments = [
            ManualHaplotypeAssignment(
                sample: "S1", locus: "MHC-A", slot: .h1,
                label: "Legacy-A1", colorTokenIndex: 2,
                diagnosticAlleles: ["01_X_0001"], notes: ""
            )
        ]
        let view = GenotypeLegacyManualHaplotypingSection(
            rows: [],
            manualAssignments: assignments,
            selectedGenotypeIds: .constant([]),
            draftLabel: .constant(""),
            draftColorTokenIndex: .constant(0),
            onCreateHaplotype: {},
            onDeleteAssignment: { _ in },
            onExportDefinitions: {}
        )
        XCTAssertFalse(view.exportIsDisabled)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
