import XCTest
@testable import LungfishApp

@MainActor
final class PrimerAnalysisDisplayTests: XCTestCase {
  func testHiddenPrimerCannotBeInspectedAsAnotherVisiblePrimer() {
    let first = target("first")
    let source = context()
    var visibility = PrimerAnalysisVisibility()
    XCTAssertEqual(visibility.bindingPrimerIDs(in: [source], targets: [first]), ["first-left"])
    visibility.settings.hiddenPrimerIDs = ["first-left"]
    XCTAssertTrue(visibility.bindingPrimerIDs(in: [source], targets: [first]).isEmpty)
    let filtered = visibility.filtering(source, targets: [first])
    XCTAssertTrue(filtered.primers.isEmpty)
    XCTAssertEqual(filtered.rows.count, source.rows.count)
    XCTAssertEqual(filtered.alignedFASTA, source.alignedFASTA)
    let adopted = PrimerBindingInspectionView.bindingSelection(for: "first-left", contexts: [source])
    XCTAssertEqual(adopted?.primerID, "primer", "An explicit hidden request retains its original identity on entry")
    XCTAssertNil(PrimerBindingInspectionView.resolvePrimer(in: filtered, selectedID: adopted?.primerID))
    // An explicit ID absent from the displayed context must not fall back to its first primer.
    XCTAssertNil(PrimerBindingInspectionView.resolvePrimer(in: source, selectedID: "hidden-primer"))
    XCTAssertEqual(PrimerBindingInspectionView.resolvePrimer(in: source, selectedID: "primer")?.id, "primer")
  }

  func testVisibilityIsScopedBySchemeAndDoesNotRewriteMembership() {
    let first = target("first"), second = target("second")
    let session = PrimerAnalysisDisplaySession(targets: [first, second])
    XCTAssertEqual(session.visibleCount, 4)
    session.setPoolShown(1, resultID: "first", shown: false)
    XCTAssertFalse(session.isVisible(first.primers[0], in: first))
    XCTAssertTrue(session.isVisible(second.primers[0], in: second))
    session.settings.showReverse = false
    XCTAssertEqual(session.visibleCount, 1)
    XCTAssertEqual(first.intervals[0].primerIDs.count, 2)
    XCTAssertEqual(PrimerReviewClipboard.ampliconPrimers(first.intervals[0], in: first)?.count, 2)
    session.reset()
    XCTAssertEqual(session.visibleCount, 4)
  }

  func testCompatibilityDenominatorKeepsUnknownSeparateAndDoesNotSumVariants() throws {
    let context = context()
    let summaries = try PrimerMSACompatibilitySummary.compute(contexts: [context])
    let summary = try XCTUnwrap(summaries["first-left"])
    XCTAssertEqual(summary.matchingRows, 1)
    XCTAssertEqual(summary.assessableRows, 2)
    XCTAssertEqual(summary.totalRows, 4)
    XCTAssertEqual(summary.unknownRows, 2)
    XCTAssertEqual(summary.percent, 50)
    let visibility = PrimerAnalysisVisibility(settings: .init(filterByCompatibility: true,
      minimumCompatibilityPercent: 60), summaries: summaries, compatibilityReady: true)
    let first = target("first")
    XCTAssertFalse(visibility.isVisible(first.primers[0], in: first))
    // A missing measurement is retained by default, rather than treated as zero percent.
    XCTAssertTrue(visibility.isVisible(first.primers[1], in: first))
    XCTAssertEqual(visibility.visiblePrimers(in: first).count, 1)
  }

  func testUnknownOnlySitesHaveNoPercentageAndFiltersWaitForCompletedMeasurements() {
    let first = target("first")
    let unknown = PrimerMSACompatibilitySummary(matchingRows: 0, assessableRows: 0, totalRows: 3)
    XCTAssertNil(unknown.percent)
    var settings = PrimerAnalysisDisplaySettings(filterByCompatibility: true, minimumCompatibilityPercent: 100,
      showUnassessed: false)
    var visibility = PrimerAnalysisVisibility(settings: settings,
      summaries: [first.primers[0].id: unknown], compatibilityReady: false)
    XCTAssertTrue(visibility.isVisible(first.primers[0], in: first))
    visibility.compatibilityReady = true
    XCTAssertFalse(visibility.isVisible(first.primers[0], in: first))
    settings.showUnassessed = true
    visibility.settings = settings
    XCTAssertTrue(visibility.isVisible(first.primers[0], in: first))
  }

  func testCompatibilityComputationIsCancellable() async {
    let contexts = [context()]
    let work = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return try PrimerMSACompatibilitySummary.compute(contexts: contexts)
    }
    do { _ = try await work.value; XCTFail("Expected cancellation") }
    catch is CancellationError { }
    catch { XCTFail("Unexpected error: \(error)") }
  }

  private func target(_ id: String) -> PrimerTargetDesignReview {
    let span = id + "-span"
    let primers = [PrimerReviewPrimer(id: id + "-left", name: "fixture_1_LEFT_1", start: 0, end: 4,
      strand: "+", pool: 1, sequence: "ACGT", ampliconIDs: [span]),
      PrimerReviewPrimer(id: id + "-right", name: "fixture_1_RIGHT_1", start: 6, end: 10,
        strand: "-", pool: 1, sequence: "ACGT", ampliconIDs: [span])]
    return .init(id: id, label: id, referenceLength: 10, coverageLabel: "Saved span", coveredBases: 10,
      intervals: [.init(id: span, start: 0, end: 10, pool: 1, name: "fixture_1", primerIDs: primers.map(\.id))],
      primers: primers, notes: [], sourceResultID: id)
  }

  private func context() -> PrimerBindingInspectionContext {
    .init(id: "context", title: "Synthetic display fixture", alignedFASTA: "", annotations: [],
      primers: [.init(id: "primer", name: "fixture_1_LEFT_1", sequence: "ACGT", strand: "+",
        alignedStart: 0, alignedEnd: 4, contiguousReference: true, reviewPrimerID: "first-left")],
      unavailableReason: nil, rows: [
        .init(name: "match", sequence: Array("ACGT")),
        .init(name: "difference", sequence: Array("TCGT")),
        .init(name: "missing-end", sequence: Array("--GT")),
        .init(name: "ambiguous", sequence: Array("NCGT"))])
  }
}
