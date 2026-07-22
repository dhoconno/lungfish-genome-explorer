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
        let names = ["   ", "not-an-allele", "", "Mamu-K*001", "Mamu-A1*001"]

        XCTAssertEqual(names.sorted(by: MHCAlleleDisplayOrder.lessThan), [
            "Mamu-A1*001",
            "Mamu-K*001",
            "not-an-allele",
            "",
            "   ",
        ])
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
}
