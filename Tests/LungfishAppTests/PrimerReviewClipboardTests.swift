import XCTest
@testable import LungfishApp

final class PrimerReviewClipboardTests: XCTestCase {
  func testPrimerFASTAUsesClickedRecordAndStoredReverseOligoOrientation() throws {
    let left = primer(id: "left", name: "scheme_1_LEFT_1", sequence: "AAGT", strand: "+")
    let right = primer(id: "right", name: "scheme_1_RIGHT_1", sequence: "CCAT", strand: "-")
    let target = target(primers: [left, right])
    let fasta = try XCTUnwrap(PrimerReviewClipboard.primerFASTA(right, in: target))
    XCTAssertTrue(fasta.contains("scheme_1_RIGHT_1"))
    XCTAssertTrue(fasta.contains("strand=-"))
    XCTAssertTrue(fasta.contains("pool=2"))
    XCTAssertTrue(fasta.hasSuffix("\nCCAT\n"))
    XCTAssertFalse(fasta.contains("AAGT"))
    XCTAssertFalse(fasta.contains("ATGG"))
  }

  func testAmpliconCopiesEveryReciprocalAlternativeWithoutInventingPairs() throws {
    let primers = [primer(id: "left1", sequence: "AAGT"), primer(id: "left2", sequence: "ARGT"),
      primer(id: "right", sequence: "CCAT", strand: "-")]
    let interval = PrimerReviewInterval(id: "span", start: 2, end: 18, pool: 2, primerIDs: primers.map(\.id))
    let review = target(primers: primers, intervals: [interval])
    let records = try XCTUnwrap(PrimerReviewClipboard.ampliconPrimers(interval, in: review))
    XCTAssertEqual(records.map(\.id), ["left1", "left2", "right"])
    let fasta = try XCTUnwrap(PrimerReviewClipboard.ampliconFASTA(interval, in: review))
    XCTAssertEqual(fasta.split(separator: ">", omittingEmptySubsequences: true).count, 3)
    XCTAssertTrue(fasta.contains("ARGT"))

    var incomplete = interval
    incomplete.primerIDs.append("missing")
    XCTAssertNil(PrimerReviewClipboard.ampliconFASTA(incomplete, in: review))
    let unrelated = primer(id: "other", sequence: "ACGT", amplicons: [])
    let unmatched = PrimerReviewInterval(id: "span", start: 2, end: 18, pool: 2, primerIDs: [unrelated.id])
    XCTAssertNil(PrimerReviewClipboard.ampliconFASTA(unmatched, in: target(primers: [unrelated], intervals: [unmatched])))
  }

  func testWholePoolIncludesOtherTargetsInSameSchemeButNotOtherSchemes() throws {
    let first = target(id: "a", primers: [primer(id: "a1", sequence: "AAGT")])
    let second = target(id: "b", primers: [primer(id: "b1", sequence: "CCAT")])
    let other = target(id: "c", source: "other-scheme", primers: [primer(id: "c1", sequence: "GGGG")])
    let fasta = try XCTUnwrap(PrimerReviewClipboard.poolFASTA(sourceResultID: "scheme", pool: 2, targets: [first, second, other]))
    XCTAssertTrue(fasta.contains("AAGT"))
    XCTAssertTrue(fasta.contains("CCAT"))
    XCTAssertFalse(fasta.contains("GGGG"))
    XCTAssertEqual(fasta.split(separator: ">", omittingEmptySubsequences: true).count, 2)
  }

  func testUnsafeHeadersCannotCreateAdditionalFASTARecordsAndMalformedSequencesAreUnavailable() throws {
    let oligo = primer(id: "primer", name: "name\n>injected\tidentifier", sequence: "aRgt")
    let fasta = try XCTUnwrap(PrimerReviewClipboard.primerFASTA(oligo, in: target(primers: [oligo])))
    XCTAssertEqual(fasta.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(">") }.count, 1)
    XCTAssertTrue(fasta.hasSuffix("\nARGT\n"))
    for invalid in ["", "AC GT", "AC\nGT", "AC-GT", "ACGT!"] {
      let bad = primer(id: "bad", sequence: invalid)
      XCTAssertNil(PrimerReviewClipboard.primerFASTA(bad, in: target(primers: [bad])))
    }
  }

  func testPoolFASTAHasUniqueIdentifiersForDuplicateNamesAcrossReferences() throws {
    let first = target(id: "a", primers: [primer(id: "first", name: "shared_LEFT_1", sequence: "AAGT")])
    let second = target(id: "b", primers: [primer(id: "second", name: "shared_LEFT_1", sequence: "CCAT")])
    let fasta = try XCTUnwrap(PrimerReviewClipboard.poolFASTA(sourceResultID: "scheme", pool: 2, targets: [first, second]))
    let headers = fasta.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(">") }
    let identifiers = headers.compactMap { $0.split(separator: " ").first.map(String.init) }
    XCTAssertEqual(Set(identifiers).count, 2)
    XCTAssertTrue(headers.allSatisfy { $0.contains("name=shared_LEFT_1") && $0.contains("source_result=scheme") })
    XCTAssertTrue(fasta.contains("oligo_id=first"))
    XCTAssertTrue(fasta.contains("oligo_id=second"))
  }

  private func primer(id: String, name: String? = nil, sequence: String, strand: String = "+", amplicons: [String] = ["span"]) -> PrimerReviewPrimer {
    .init(id: id, name: name ?? id, start: strand == "+" ? 2 : 14, end: strand == "+" ? 6 : 18,
      strand: strand, pool: 2, sequence: sequence, ampliconIDs: amplicons)
  }

  private func target(id: String = "target", source: String = "scheme", primers: [PrimerReviewPrimer], intervals: [PrimerReviewInterval] = []) -> PrimerTargetDesignReview {
    .init(id: id, label: "Reference \(id)", referenceLength: 20, coverageLabel: "Reference span", coveredBases: nil,
      intervals: intervals, primers: primers, notes: [], sourceResultID: source, referenceID: id)
  }
}
