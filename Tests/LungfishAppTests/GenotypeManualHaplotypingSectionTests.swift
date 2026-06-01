import XCTest
import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeManualHaplotypingSectionTests: XCTestCase {
    func testRendersWithoutCrashWithEmptyState() {
        let bindings = TestBindings()
        let view = GenotypeManualHaplotypingSection(
            rows: [],
            manualAssignments: [],
            selectedGenotypeIds: bindings.selectionBinding,
            draftLabel: bindings.labelBinding,
            draftColorTokenIndex: bindings.tokenBinding,
            onCreateHaplotype: {},
            onDeleteAssignment: { _ in },
            onExportDefinitions: {}
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        XCTAssertGreaterThan(host.frame.width, 0)
    }

    func testRendersGenotypeRowsAndAssignments() {
        let bindings = TestBindings()
        bindings.selection = ["MHC-A::01_X_0001"]
        let rows = [
            GenotypeManualHaplotypingSection.GenotypeRow(
                locus: "MHC-A", genotype: "01_X_0001",
                sampleCount: 12, totalReads: 4500
            ),
            GenotypeManualHaplotypingSection.GenotypeRow(
                locus: "MHC-A", genotype: "01_X_0002",
                sampleCount: 7, totalReads: 2300
            ),
            GenotypeManualHaplotypingSection.GenotypeRow(
                locus: "MHC-B", genotype: "12_Y_0099",
                sampleCount: 5, totalReads: 1100
            ),
        ]
        let assignments = [
            ManualHaplotypeAssignment(
                sample: "S1", locus: "MHC-A", slot: .h1,
                label: "Custom-A1", colorTokenIndex: 2,
                diagnosticAlleles: ["01_X_0001"], notes: ""
            )
        ]
        let view = GenotypeManualHaplotypingSection(
            rows: rows,
            manualAssignments: assignments,
            selectedGenotypeIds: bindings.selectionBinding,
            draftLabel: bindings.labelBinding,
            draftColorTokenIndex: bindings.tokenBinding,
            onCreateHaplotype: {},
            onDeleteAssignment: { _ in },
            onExportDefinitions: {}
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        XCTAssertGreaterThan(host.frame.width, 0)
    }

    @MainActor
    private final class TestBindings {
        var selection: Set<String> = []
        var label: String = ""
        var token: Int = 1

        var selectionBinding: Binding<Set<String>> {
            .init(get: { self.selection }, set: { self.selection = $0 })
        }
        var labelBinding: Binding<String> {
            .init(get: { self.label }, set: { self.label = $0 })
        }
        var tokenBinding: Binding<Int> {
            .init(get: { self.token }, set: { self.token = $0 })
        }
    }
}
