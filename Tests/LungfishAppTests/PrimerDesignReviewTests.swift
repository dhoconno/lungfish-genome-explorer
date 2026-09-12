import Foundation
import XCTest
import LungfishWorkflow
@testable import LungfishApp

final class PrimerDesignReviewTests: XCTestCase {
  func testPrimer3CandidatesRemainSeparateAndUseFullTemplateDenominator() {
    func pair(_ start: Int, _ end: Int) -> Primer3Pair {
      .init(id: UUID(), left: .init(id: UUID(), start: start, end: start + 2, orientation: .forward,
        sequence: "AC", meltingTemperature: 60, gcPercent: 50),
        right: .init(id: UUID(), start: end - 2, end: end, orientation: .reverse,
        sequence: "GT", meltingTemperature: 60, gcPercent: 50), internalOligo: nil, productSize: end - start)
    }
    let result = Primer3TemplateResult(resultID: UUID(), inputID: UUID(), title: "Template", sourceKind: "fasta",
      sourceIndex: 0, sourceRecordID: "template", templateSequence: "ACGTACGTAC", alignmentToTemplate: nil,
      excludedRegions: [], pairs: [pair(0, 6), pair(2, 10)], error: nil, explanation: nil)
    let reviews = PrimerDesignReview.primer3(.init(analysisID: UUID(), runID: UUID(), results: [result]))
    XCTAssertEqual(reviews.count, 2)
    XCTAssertEqual(reviews.map(\.coveragePercent), [60, 80])
    XCTAssertEqual(reviews.map { $0.intervals.count }, [1, 1])
  }

  func testCoverageUnionsAmpliconsAndRetainsUncoveredReferences() throws {
    let reviews = try PrimerDesignReview.primalScheme(id: "run", label: "Scheme",
      reference: Data(">a\nAAAAAAAAAA\n>b\nACGT\n".utf8),
      amplicons: Data("a\t1\t5\tA\t1\na\t3\t8\tB\t2\n".utf8), primers: [], labels: [:])
    XCTAssertEqual(reviews.count, 2)
    XCTAssertEqual(reviews[0].coveredBases, 7)
    XCTAssertEqual(reviews[0].coveragePercent, 70)
    XCTAssertEqual(reviews[1].coveredBases, 0)
    XCTAssertEqual(reviews[1].coveragePercent, 0)
  }

  func testAbsentAmpliconFileIsUnknownNotZeroOrPrimerFootprintCoverage() throws {
    let reviews = try PrimerDesignReview.primalScheme(id: "run", label: "Scheme",
      reference: Data(">a\nAAAA\n".utf8), amplicons: nil, primers: [], labels: [:])
    XCTAssertNil(reviews.first?.coveredBases)
    XCTAssertNil(reviews.first?.coveragePercent)
  }

  func testMalformedOrOutOfReferenceAmpliconsAreRejected() {
    for bed in ["a\t0\t5\tA\t1", "missing\t0\t2\tA\t1", "a\t2\t1\tA\t1", "a\t0\t2\tA\t0"] {
      XCTAssertThrowsError(try PrimerDesignReview.primalScheme(id: "run", label: "Scheme",
        reference: Data(">a\nAAAA\n".utf8), amplicons: Data(bed.utf8), primers: [], labels: [:]))
    }
  }
}
