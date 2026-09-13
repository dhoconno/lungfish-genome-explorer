import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp

@MainActor
final class PrimerReviewContextMenuTests: XCTestCase {
  func testInspectPrimerUsesRightClickedPrimerInsteadOfPreviousSelection() throws {
    let target = fixture()
    let clicked = target.primers[1]
    var selected: PrimerReviewSelection? = .selecting(primer: target.primers[0], in: target)
    let menu = PrimerReviewContextMenu(target: target, item: .primer(clicked),
      selection: Binding(get: { selected }, set: { selected = $0 }))
    try menu.inspect().find(button: "Inspect Primer").tap()
    XCTAssertEqual(selected?.targetID, target.id)
    XCTAssertEqual(selected?.primerID, clicked.id)
    XCTAssertEqual(selected?.ampliconID, "amplicon")
  }

  func testInspectAmpliconClearsPreviouslySelectedPrimer() throws {
    let target = fixture()
    var selected: PrimerReviewSelection? = .selecting(primer: target.primers[0], in: target)
    let menu = PrimerReviewContextMenu(target: target, item: .amplicon(target.intervals[0]),
      selection: Binding(get: { selected }, set: { selected = $0 }))
    try menu.inspect().find(button: "Inspect Amplicon").tap()
    XCTAssertEqual(selected?.ampliconID, "amplicon")
    XCTAssertNil(selected?.primerID)
  }

  func testProjectWritesAndUnavailableBindingAreDisabledWithoutProjectCallbacks() throws {
    let target = fixture()
    let menu = PrimerReviewContextMenu(target: target, item: .primer(target.primers[0]), selection: .constant(nil))
    let inspected = try menu.inspect()
    XCTAssertTrue(try inspected.find(button: "Save Primer FASTA Bundle in Project").isDisabled())
    XCTAssertTrue(try inspected.find(button: "Extract Reference Amplicon Bundle in Project").isDisabled())
    XCTAssertTrue(try inspected.find(button: "Inspect in Alignment").isDisabled())
  }

  private func fixture() -> PrimerTargetDesignReview {
    let primers = [
      PrimerReviewPrimer(id: "left", name: "scheme_1_LEFT_1", start: 5, end: 9, strand: "+", pool: 2,
        sequence: "AAGT", ampliconIDs: ["amplicon"]),
      PrimerReviewPrimer(id: "right", name: "scheme_1_RIGHT_1", start: 65, end: 69, strand: "-", pool: 2,
        sequence: "CCAT", ampliconIDs: ["amplicon"])
    ]
    return .init(id: "target", label: "Reference", referenceLength: 100, coverageLabel: "Reference span", coveredBases: 64,
      intervals: [.init(id: "amplicon", start: 5, end: 69, pool: 2, name: "scheme_1", primerIDs: primers.map(\.id))],
      primers: primers, notes: [], sourceResultID: "scheme", referenceID: "reference")
  }
}
