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
    for (review, pair) in zip(reviews, result.pairs) {
      XCTAssertEqual(review.presentation, .primer3Template)
      XCTAssertEqual(review.sourceResultID, result.resultID.uuidString)
      XCTAssertEqual(review.intervals[0].primerIDs, [pair.left.id.uuidString, pair.right.id.uuidString])
      XCTAssertEqual(review.intervals[0].length, pair.productSize)
      XCTAssertEqual(review.intervals[0].sizeLabel, "Product size on saved template")
      XCTAssertTrue(review.primers.allSatisfy { $0.ampliconIDs == [pair.id.uuidString] && !$0.sequence.isEmpty })
      XCTAssertNil(review.intervals[0].pool)
    }
  }

  func testCoverageUnionsAmpliconsAndRetainsUncoveredReferences() throws {
    let reviews = try PrimerDesignReview.primalScheme(id: "run", label: "Scheme",
      reference: Data(">a\nAAAAAAAAAA\n>b\nACGT\n".utf8),
      amplicons: Data("a\t1\t5\tA\t1\na\t3\t8\tB\t2\n".utf8), primers: [], labels: [:])
    XCTAssertEqual(reviews.count, 2)
    XCTAssertEqual(reviews[0].coveredBases, 7)
    XCTAssertEqual(reviews[0].presentation, .schemeReference)
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

  func testNativeAmpliconIdentityRetainsIndependentAlternativesAndReferenceSpan() throws {
    let review = try nativeReview()
    XCTAssertEqual(review.sourceResultID, "run")
    XCTAssertEqual(review.referenceID, "a")
    XCTAssertEqual(review.intervals[0].name, "abc_1")
    XCTAssertEqual(review.intervals[0].length, 90)
    XCTAssertEqual(review.intervals[0].pool, 2)
    XCTAssertEqual(review.intervals[0].primerIDs, ["run-primer-0", "run-primer-1", "run-primer-2", "run-primer-3"])
    XCTAssertTrue(review.primers.allSatisfy { $0.ampliconIDs == ["run-span-0"] })
    // Both independent clouds remain present, including variants with different mapped spans.
    XCTAssertEqual(review.primers.map(\.sequence), ["ACGT", "ACGT", "ACGT", "ACGT"])
    XCTAssertEqual(review.primers.map { $0.end - $0.start }, [4, 5, 4, 3])
  }

  func testPrimer3ProbeBelongsToExplicitCandidateWithoutChangingProductBounds() throws {
    let left = Primer3Oligo(id: UUID(), start: 0, end: 2, orientation: .forward,
      sequence: "AC", meltingTemperature: 60, gcPercent: 50)
    let right = Primer3Oligo(id: UUID(), start: 8, end: 10, orientation: .reverse,
      sequence: "GT", meltingTemperature: 60, gcPercent: 50)
    let probe = Primer3Oligo(id: UUID(), start: 4, end: 6, orientation: .forward,
      sequence: "AC", meltingTemperature: 68, gcPercent: 50)
    let pair = Primer3Pair(id: UUID(), left: left, right: right, internalOligo: probe, productSize: 10)
    let result = Primer3TemplateResult(resultID: UUID(), inputID: UUID(), title: "Template", sourceKind: "fasta",
      sourceIndex: 0, sourceRecordID: "template", templateSequence: "ACGTACGTAC", alignmentToTemplate: nil,
      excludedRegions: [], pairs: [pair], error: nil, explanation: nil)
    let review = try XCTUnwrap(PrimerDesignReview.primer3(.init(analysisID: UUID(), runID: UUID(), results: [result])).first)
    XCTAssertEqual(review.intervals[0].primerIDs, [left.id.uuidString, right.id.uuidString, probe.id.uuidString])
    XCTAssertEqual(review.intervals[0].length, 10)
    XCTAssertEqual(review.primers.last?.name, "Internal probe")
    XCTAssertEqual(review.primers.last?.ampliconIDs, [pair.id.uuidString])
    XCTAssertNil(review.primers.last?.pool)
  }

  func testCorrespondenceIsUnavailableForMissingSidesWrongPoolsStrandsOrDuplicateAmplicons() throws {
    let cases: [(String, String)] = [
      (nativeBED.components(separatedBy: "\n").prefix(2).joined(separator: "\n"), nativeAmplicon),
      (nativeBED.replacingOccurrences(of: "abc_1_RIGHT_2\t2", with: "abc_1_RIGHT_2\t1"), nativeAmplicon),
      (nativeBED.replacingOccurrences(of: "abc_1_RIGHT_2\t2\t-", with: "abc_1_RIGHT_2\t2\t+"), nativeAmplicon),
      (nativeBED, nativeAmplicon + nativeAmplicon),
      (nativeBED, nativeAmplicon.replacingOccurrences(of: "\t5\t95", with: "\t4\t95")),
      (nativeBED.replacingOccurrences(of: "abc_1", with: "unrelated_2"), nativeAmplicon)
    ]
    for (bed, amplicon) in cases {
      let review = try nativeReview(bed: bed, amplicon: amplicon)
      XCTAssertTrue(review.intervals.allSatisfy { $0.primerIDs.isEmpty }, bed)
      XCTAssertTrue(review.primers.allSatisfy { $0.ampliconIDs.isEmpty }, bed)
      XCTAssertFalse(review.primers.isEmpty, "Standalone primer inspection must remain available")
    }
  }

  func testAmpliconAssociationIsScopedToReferenceAndNativeResult() throws {
    let ref = Data((">a\n" + String(repeating: "A", count: 100) + "\n>b\n" + String(repeating: "C", count: 100) + "\n").utf8)
    let bed = nativeBED + nativeBED.replacingOccurrences(of: "a\t", with: "b\t")
    let parsed = try PrimalSchemeDisplayResult.parse(id: "run", title: "Scheme", bed: Data(bed.utf8), reference: ref)
    let reviews = try PrimerDesignReview.primalScheme(id: "run", label: "Scheme", reference: ref,
      amplicons: Data((nativeAmplicon + nativeAmplicon.replacingOccurrences(of: "a\t", with: "b\t")).utf8),
      primers: parsed.primers, labels: [:])
    XCTAssertEqual(reviews[0].intervals[0].primerIDs, ["run-primer-0", "run-primer-1", "run-primer-2", "run-primer-3"])
    XCTAssertEqual(reviews[1].intervals[0].primerIDs, ["run-primer-4", "run-primer-5", "run-primer-6", "run-primer-7"])
  }

  private var nativeBED: String {
    "a\t5\t9\tabc_1_LEFT_1\t2\t+\tACGT\n" +
    "a\t6\t11\tabc_1_LEFT_2\t2\t+\tACGT\n" +
    "a\t91\t95\tabc_1_RIGHT_1\t2\t-\tACGT\n" +
    "a\t91\t94\tabc_1_RIGHT_2\t2\t-\tACGT\n"
  }
  private var nativeAmplicon: String { "a\t5\t95\tabc_1\t2\n" }
  private func nativeReview(bed: String? = nil, amplicon: String? = nil) throws -> PrimerTargetDesignReview {
    let ref = Data((">a\n" + String(repeating: "A", count: 100) + "\n").utf8)
    let parsed = try PrimalSchemeDisplayResult.parse(id: "run", title: "Scheme", bed: Data((bed ?? nativeBED).utf8), reference: ref)
    return try XCTUnwrap(PrimerDesignReview.primalScheme(id: "run", label: "Scheme", reference: ref,
      amplicons: Data((amplicon ?? nativeAmplicon).utf8), primers: parsed.primers, labels: [:]).first)
  }
}
