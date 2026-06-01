import XCTest
import LungfishIO
@testable import LungfishTwelveSUI

final class TwelveSDetailPayloadTests: XCTestCase {

    func testDetailPayloadFromTargetRow() {
        let row = TwelveSScientificNameCountRow(
            scientificName: "Homo sapiens", targetIDs: ["t1", "t2"],
            sampleCounts: ["s1": 40, "s2": 10], sampleExactReadTotals: ["s1": 100, "s2": 50],
            potentialMatches: ["Homo heidelbergensis"], taxids: ["9606"])
        let payload = TwelveSDetailPayload(targetRow: row, sampleDisplayNames: ["s1": "Sample One"])
        guard case let .target(detail) = payload.kind else { return XCTFail("expected target") }
        XCTAssertEqual(detail.scientificName, "Homo sapiens")
        XCTAssertEqual(detail.totalExactReads, 50)
        XCTAssertEqual(detail.referenceTargetCount, 2)
        // sorted descending by reads → s1 (40) first
        XCTAssertEqual(detail.sampleEvidence.first?.displayName, "Sample One")
        XCTAssertEqual(detail.sampleEvidence.first?.exactReads, 40)
        XCTAssertEqual(detail.alternateTexts, ["Homo heidelbergensis"])
    }

    func testDetailPayloadFromUnresolvedRow() {
        let row = TwelveSUnresolvedSequence(
            sequenceID: "cluster-1", sequence: "ACGTACGT", readCount: 21,
            sampleCounts: ["s1": 15, "s2": 6], chimeraStatus: .candidate)
        let payload = TwelveSDetailPayload(unresolvedRow: row, sampleDisplayNames: ["s1": "Sample One"])
        guard case let .unresolved(detail) = payload.kind else { return XCTFail("expected unresolved") }
        XCTAssertEqual(detail.sequenceID, "cluster-1")
        XCTAssertEqual(detail.readCount, 21)
        XCTAssertEqual(detail.sequence, "ACGTACGT")
        XCTAssertEqual(detail.chimeraStatusName, "Candidate")
        XCTAssertEqual(detail.sampleEvidence.first?.exactReads, 15)
    }
}
