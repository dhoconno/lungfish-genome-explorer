import XCTest
@testable import LungfishIO

final class PhylogeneticTreeInferenceSummaryReplicateTests: XCTestCase {
    func testSummaryWithoutReplicateKeysStillDecodesAndRoundTripsCounts() throws {
        let legacy = Data("""
        {"program":"IQ-TREE","programVersion":"3.1.3","requestedModel":"MFP","sequenceType":"DNA",
         "selectedRowCount":4,"totalRowCount":5,"alignedLength":9}
        """.utf8)
        let decoded = try JSONDecoder().decode(PhylogeneticTreeInferenceSummary.self, from: legacy)
        XCTAssertNil(decoded.ufBootReplicates)
        XCTAssertNil(decoded.shALRTReplicates)

        let withCounts = PhylogeneticTreeInferenceSummary(
            program: "IQ-TREE", programVersion: "3.1.3", requestedModel: "MFP",
            ufBootReplicates: 1500, shALRTReplicates: 1000, sequenceType: "DNA",
            selectedRowCount: 4, totalRowCount: 5, alignedLength: 9
        )
        let again = try JSONDecoder().decode(PhylogeneticTreeInferenceSummary.self, from: JSONEncoder().encode(withCounts))
        XCTAssertEqual(again, withCounts)
    }
}
