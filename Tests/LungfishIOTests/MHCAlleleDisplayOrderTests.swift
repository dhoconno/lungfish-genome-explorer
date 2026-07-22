import Foundation
import XCTest
@testable import LungfishIO

final class MHCAlleleDisplayOrderTests: XCTestCase {
    func testSortsCompleteMamuDisplayOrder() {
        let names = [
            "",
            "Mamu-DRB*001",
            "Mamu-K*001",
            "Mamu-J*001",
            "Mamu-AG*001",
            "Mamu-G*001",
            "Mamu-F*001",
            "Mamu-I*001",
            "Mamu-B16*001",
            "Mamu-B02ps*001",
            "Mamu-B*010",
            "Mamu-B*002",
            "Mamu-A10*001",
            "Mamu-A2*001",
            "Mamu-A1*001",
        ]

        XCTAssertEqual(names.sorted(by: MHCAlleleDisplayOrder.lessThan), [
            "Mamu-A1*001",
            "Mamu-A2*001",
            "Mamu-A10*001",
            "Mamu-B*002",
            "Mamu-B*010",
            "Mamu-B02ps*001",
            "Mamu-B16*001",
            "Mamu-I*001",
            "Mamu-F*001",
            "Mamu-G*001",
            "Mamu-AG*001",
            "Mamu-J*001",
            "Mamu-K*001",
            "Mamu-DRB*001",
            "",
        ])
    }

    func testSortsMafaLociByTheSameBiologicalOrder() {
        let names = [
            "Mafa-B14*001",
            "Mafa-A10*001",
            "Mafa-B*001",
            "Mafa-A2*001",
            "Mafa-A1*001",
        ]

        XCTAssertEqual(names.sorted(by: MHCAlleleDisplayOrder.lessThan), [
            "Mafa-A1*001",
            "Mafa-A2*001",
            "Mafa-A10*001",
            "Mafa-B*001",
            "Mafa-B14*001",
        ])
    }

    func testLocusPrecedesSpeciesPrefixForMixedSpecies() {
        let names = ["Mafa-A2*001", "Mamu-A1*001"]

        XCTAssertEqual(names.sorted(by: MHCAlleleDisplayOrder.lessThan), [
            "Mamu-A1*001",
            "Mafa-A2*001",
        ])
    }

    func testExactBPrecedesNumberedAndSuffixedBLoci() {
        let names = ["Mamu-B02ps*001", "Mamu-B16*001", "Mamu-B*001"]

        XCTAssertEqual(names.sorted(by: MHCAlleleDisplayOrder.lessThan), [
            "Mamu-B*001",
            "Mamu-B02ps*001",
            "Mamu-B16*001",
        ])
    }

    func testAllelesUseNaturalNumericOrder() {
        let names = ["Mamu-B*010", "Mamu-B*002", "Mamu-B*100"]

        XCTAssertEqual(names.sorted(by: MHCAlleleDisplayOrder.lessThan), [
            "Mamu-B*002",
            "Mamu-B*010",
            "Mamu-B*100",
        ])
    }

    func testMalformedNamesPrecedeBlankNamesButFollowBiologicalLoci() {
        let names = ["not-an-allele", "", "Mamu-K*001", "Mamu-A1*001"]

        XCTAssertEqual(names.sorted(by: MHCAlleleDisplayOrder.lessThan), [
            "Mamu-A1*001",
            "Mamu-K*001",
            "not-an-allele",
            "",
        ])
    }

    func testBlankNamesNormalizeCompleteNameBeforeStableIDComparison() {
        XCTAssertEqual(
            MHCAlleleDisplayOrder.compare(
                "   ",
                "",
                lhsStableID: "cluster-z",
                rhsStableID: "cluster-a"
            ),
            .orderedDescending
        )
        XCTAssertEqual(
            MHCAlleleDisplayOrder.compare(
                "   ",
                "",
                lhsStableID: "cluster-a",
                rhsStableID: "cluster-z"
            ),
            .orderedAscending
        )
    }

    func testSameDisplayNameUsesStableIDAsFinalTieBreaker() {
        let displayName = "Mamu-A1*001"

        XCTAssertEqual(
            MHCAlleleDisplayOrder.compare(
                displayName,
                displayName,
                lhsStableID: "record-2",
                rhsStableID: "record-10"
            ),
            .orderedAscending
        )
        XCTAssertEqual(
            MHCAlleleDisplayOrder.compare(
                displayName,
                displayName,
                lhsStableID: "record-2",
                rhsStableID: "record-2"
            ),
            .orderedSame
        )
    }

    func testStableIDNaturalTiesUseExactDeterministicFallback() {
        let displayName = "Mamu-A1*001"

        for (lhsStableID, rhsStableID) in [
            ("record-2", "record-02"),
            ("record-a", "record-A"),
        ] {
            XCTAssertEqual(
                MHCAlleleDisplayOrder.compare(
                    displayName,
                    displayName,
                    lhsStableID: lhsStableID,
                    rhsStableID: rhsStableID
                ),
                .orderedDescending
            )
            XCTAssertEqual(
                MHCAlleleDisplayOrder.compare(
                    displayName,
                    displayName,
                    lhsStableID: rhsStableID,
                    rhsStableID: lhsStableID
                ),
                .orderedAscending
            )
        }
    }

    func testFullNameNaturalTiesUseExactDeterministicFallback() {
        for (lhs, rhs) in [
            ("Mamu-A1*2", "Mamu-A1*02"),
            ("Mamu-A1*abc", "Mamu-A1*ABC"),
        ] {
            XCTAssertEqual(
                MHCAlleleDisplayOrder.compare(
                    lhs,
                    rhs,
                    lhsStableID: "record-1",
                    rhsStableID: "record-1"
                ),
                .orderedDescending
            )
            XCTAssertEqual(
                MHCAlleleDisplayOrder.compare(
                    rhs,
                    lhs,
                    lhsStableID: "record-1",
                    rhsStableID: "record-1"
                ),
                .orderedAscending
            )
        }
    }

    func testStableIDNaturalOrderPrecedesExactFullNameFallback() {
        XCTAssertEqual(
            MHCAlleleDisplayOrder.compare(
                "Mamu-A1*2",
                "Mamu-A1*02",
                lhsStableID: "record-1",
                rhsStableID: "record-2"
            ),
            .orderedAscending
        )
    }

    func testCompareDefaultsStableIDsToEmptyStrings() {
        XCTAssertEqual(
            MHCAlleleDisplayOrder.compare("Mamu-A1*001", "Mamu-A2*001"),
            .orderedAscending
        )
    }
}
