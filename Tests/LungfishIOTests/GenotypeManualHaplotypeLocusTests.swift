import XCTest
@testable import LungfishIO

final class GenotypeManualHaplotypeLocusTests: XCTestCase {
    func testCanonicalOrderMatchesWorkbookOrderExactly() {
        XCTAssertEqual(
            GenotypeManualHaplotypeLocus.allCases.map(\.rawValue),
            ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"]
        )
        XCTAssertEqual(
            GenotypeManualHaplotypeLocus.allCases.map(\.workbookLabel),
            ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"]
        )
    }

    func testNormalizesAcceptedResultAndSourceAliases() {
        let aliases: [(String, GenotypeManualHaplotypeLocus)] = [
            ("A", .a), ("MHC A", .a), ("Mafa-A1*001:01", .a),
            ("B", .b), ("mhc_b", .b), ("Mafa-B17*001:01", .b),
            ("DRB", .drb), ("MHC-DRB1", .drb), ("Mafa-DRB6*01:01", .drb),
            ("DQA", .dqa), ("MHC-DQA1", .dqa),
            ("DQB", .dqb), ("Mafa-DQB1*18:01", .dqb),
            ("DPA", .dpa), ("MHC-DPA1", .dpa),
            ("DPB", .dpb), ("Mafa-DPB2*05:01", .dpb),
        ]

        for (alias, expected) in aliases {
            XCTAssertEqual(GenotypeManualHaplotypeLocus(normalizing: alias), expected, alias)
        }
    }

    func testRejectsBroadOrUnsupportedLoci() {
        for value in ["", "MHC-DQ", "MHC-DP", "MHC-E", "MHC-AG", "not-a-locus"] {
            XCTAssertNil(GenotypeManualHaplotypeLocus(normalizing: value), value)
        }
    }
}
