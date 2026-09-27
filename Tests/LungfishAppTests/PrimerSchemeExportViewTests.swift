import LungfishWorkflow
import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp

@MainActor
final class PrimerSchemeExportViewTests: XCTestCase {
    private func candidate(_ label: String, refusal: String? = nil) -> PrimerSchemeFromAnalysisCandidate {
        .init(resultID: UUID(), label: label, engine: "PrimalScheme3", referenceID: "Mamu-A1_001",
              referenceStatement: "Coordinates are on the first row of the alignment.", primerCount: 4,
              ampliconCount: 2, poolCount: 2, notes: ["Numbered variants are trimmed together."], refusalReason: refusal)
    }

    func testSheetNamesTheSchemeStatesTheReferenceAndRefusesUnsavableResults() throws {
        let saved = candidate("Mamu-A1")
        let refused = candidate("Combined panel", refusal: "This result places primers on 11 references.")
        let model = PrimerSchemeExportViewModel(candidates: [refused, saved], analysisName: "Primer analysis")
        XCTAssertEqual(model.selectedResultID, saved.resultID, "The first exportable result is chosen")
        XCTAssertEqual(model.name, "Primer analysis Mamu-A1 scheme")
        XCTAssertNil(model.validationMessage)

        var received: (PrimerSchemeFromAnalysisCandidate, String)?
        let view = PrimerSchemeExportView(model: model, onCancel: {}, onSave: { received = ($0, $1) })
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(viewWithAccessibilityIdentifier: "primerSchemeExport.result"))
        XCTAssertNoThrow(try inspected.find(text: "Mamu-A1_001"))
        XCTAssertNoThrow(try inspected.find(text: "Coordinates are on the first row of the alignment."))
        XCTAssertNoThrow(try inspected.find(text: "PrimalScheme3 · 4 primers · 2 amplicons · 2 pools"))
        try inspected.find(button: "Save").tap()
        XCTAssertEqual(received?.0.resultID, saved.resultID)
        XCTAssertEqual(received?.1, "Primer analysis Mamu-A1 scheme")

        model.select(refused.resultID)
        XCTAssertEqual(model.name, "Primer analysis Combined panel scheme", "An untouched default follows the result")
        XCTAssertEqual(model.validationMessage, refused.refusalReason)
        XCTAssertTrue(try view.inspect().find(button: "Save").isDisabled())

        model.select(saved.resultID)
        model.name = "bad/name"
        XCTAssertEqual(model.validationMessage, "Enter a name without path separators.")
        model.name = "   "
        XCTAssertEqual(model.validationMessage, "Enter a name for the primer scheme.")
    }

    func testSchemeSessionExposesSaveActionAndRefusalReason() throws {
        let session = PrimerAnalysisDisplaySession(targets: [
            .init(id: "t", label: "Scheme", referenceLength: 10, coverageLabel: "", coveredBases: nil, intervals: [],
                  primers: [.init(id: "p", name: "x_1_LEFT_1", start: 0, end: 2, strand: "+", pool: 1, sequence: "AC")],
                  notes: [], sourceResultID: "r", referenceID: "ref"),
        ])
        XCTAssertEqual(session.schemeExportUnavailableReason, "Wait for a verified saved analysis.")
        let inspected = try PrimerAnalysisDisplaySection(session: session).inspect()
        XCTAssertTrue(try inspected.find(viewWithAccessibilityIdentifier: "primerAnalysisDisplay.saveScheme").button().isDisabled())
    }
}
