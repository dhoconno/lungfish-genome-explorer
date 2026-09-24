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

  func testUnpooledAlternativeDoesNotOfferPoolActionsOrClaimSelectedStatus() throws {
    let assayID = "alternative-assay"
    let primer = PrimerReviewPrimer(id: "probe", name: "custom probe", start: 20, end: 24,
      strand: "-", pool: 7, role: .probe, candidateStatus: .alternative, rank: 2,
      nativePool: nil, sequence: "ACGT", ampliconIDs: [assayID])
    let interval = PrimerReviewInterval(id: assayID, start: 5, end: 69, pool: 7,
      nativePool: nil, candidateStatus: .alternative, rank: 2, name: "Alternative assay 2",
      primerIDs: [primer.id])
    let target = PrimerTargetDesignReview(id: "target", label: "Reference", referenceLength: 100,
      coverageLabel: "Reported assay spans", coveredBases: 64, intervals: [interval], primers: [primer],
      notes: [], sourceResultID: "scheme", referenceID: "reference")
    let actions = PrimerReviewContextActions(targets: [target], onExportRequested: { _, _ in })

    let primerMenu = try PrimerReviewContextMenu(target: target, item: .primer(primer), selection: .constant(nil))
      .environment(\.primerReviewActions, actions).inspect()
    XCTAssertNoThrow(try primerMenu.find(button: "Alternative assay oligo · rank 2"))
    XCTAssertThrowsError(try primerMenu.find(button: "Copy All Pool 7 Oligos as FASTA"))
    XCTAssertThrowsError(try primerMenu.find(button: "Save Pool 7 Primer FASTA Bundle in Project"))

    let ampliconMenu = try PrimerReviewContextMenu(target: target, item: .amplicon(interval), selection: .constant(nil))
      .environment(\.primerReviewActions, actions).inspect()
    XCTAssertNoThrow(try ampliconMenu.find(button: "1 oligo in alternative assay · rank 2"))
    XCTAssertThrowsError(try ampliconMenu.find(button: "Save Pool 7 Primer FASTA Bundle in Project"))
  }

  private func fixture() -> PrimerTargetDesignReview {
    let primers = [
      PrimerReviewPrimer(id: "left", name: "scheme_1_LEFT_1", start: 5, end: 9, strand: "+", pool: 2,
        nativePool: "2", sequence: "AAGT", ampliconIDs: ["amplicon"]),
      PrimerReviewPrimer(id: "right", name: "scheme_1_RIGHT_1", start: 65, end: 69, strand: "-", pool: 2,
        nativePool: "2", sequence: "CCAT", ampliconIDs: ["amplicon"])
    ]
    return .init(id: "target", label: "Reference", referenceLength: 100, coverageLabel: "Reference span", coveredBases: 64,
      intervals: [.init(id: "amplicon", start: 5, end: 69, pool: 2, nativePool: "2", name: "scheme_1", primerIDs: primers.map(\.id))],
      primers: primers, notes: [], sourceResultID: "scheme", referenceID: "reference")
  }
}
