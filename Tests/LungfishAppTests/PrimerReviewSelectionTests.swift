import XCTest
@testable import LungfishApp

final class PrimerReviewSelectionTests: XCTestCase {
  func testSelectingAlternativePrimerKeepsPrimerAndExactAmpliconIdentity() {
    let primer = PrimerReviewPrimer(id: "left-alt-2", name: "scheme_1_LEFT_2", start: 12, end: 32, strand: "+", pool: 2,
      sequence: "ACGT", ampliconIDs: ["span-1"])
    let interval = PrimerReviewInterval(id: "span-1", start: 10, end: 410, pool: 2,
      primerIDs: [primer.id, "other-left", "right"])
    let selection = PrimerReviewSelection.selecting(primer: primer, in: target(primers: [primer], intervals: [interval]))
    XCTAssertEqual(selection.targetID, "second-reference")
    XCTAssertEqual(selection.primerID, primer.id)
    XCTAssertEqual(selection.ampliconID, "span-1")
  }

  func testMissingOrAmbiguousMembershipDoesNotInferAnAmpliconFromPoolOrPosition() {
    let primer = PrimerReviewPrimer(id: "primer", name: "unknown", start: 12, end: 32, strand: "+", pool: 2)
    let interval = PrimerReviewInterval(id: "span", start: 10, end: 410, pool: 2)
    XCTAssertNil(PrimerReviewSelection.selecting(primer: primer, in: target(primers: [primer], intervals: [interval])).ampliconID)
    var ambiguous = primer
    ambiguous.ampliconIDs = ["one", "two"]
    let intervals = ["one", "two"].map {
      PrimerReviewInterval(id: $0, start: 10, end: 410, pool: 2, primerIDs: [primer.id])
    }
    XCTAssertNil(PrimerReviewSelection.selecting(primer: ambiguous, in: target(primers: [ambiguous], intervals: intervals)).ampliconID)
  }

  func testPrimerSelectionRequiresReciprocalSavedMembership() {
    let primer = PrimerReviewPrimer(id: "primer", name: "unknown", start: 12, end: 32, strand: "+", pool: 2, ampliconIDs: ["span"])
    let interval = PrimerReviewInterval(id: "span", start: 10, end: 410, pool: 2, primerIDs: ["different-primer"])
    XCTAssertNil(PrimerReviewSelection.selecting(primer: primer, in: target(primers: [primer], intervals: [interval])).ampliconID)
  }

  @MainActor
  func testViewportContainsOnlyScientificReviewSections() {
    XCTAssertEqual(PrimerAnalysisViewerView.Section.allCases.map(\.rawValue), ["Overview", "Results", "Binding inspection"])
  }

  private func target(primers: [PrimerReviewPrimer], intervals: [PrimerReviewInterval]) -> PrimerTargetDesignReview {
    .init(id: "second-reference", label: "Second reference", referenceLength: 1000,
      coverageLabel: "Reference spanned by amplicons", coveredBases: 400, intervals: intervals,
      primers: primers, notes: [], sourceResultID: "combined-scheme", referenceID: "reference-2")
  }
}
