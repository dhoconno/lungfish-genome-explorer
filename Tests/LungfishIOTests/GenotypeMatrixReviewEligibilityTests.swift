import XCTest
@testable import LungfishIO

final class GenotypeMatrixReviewEligibilityTests: XCTestCase {
    func testExactIdentitySeparatesStableClustersAndPlainCallsWithoutMutatingSource() {
        let targets = [nil, "cluster-a", "cluster-b"].map {
            GenotypeAnnotationSidecar.MatrixTarget.cell(locus: "MHC-A", genotype: "same", sample: "S1", stableClusterID: $0)
        }
        let records = targets.map { GenotypeAnnotationSidecar.MatrixReviewAnnotation(target: $0, disposition: .falsePositive, author: "A", timestamp: "now") }
        let reviews = records + [records[1]]
        let support = Dictionary(uniqueKeysWithValues: targets.map { ($0, 7) })
        let eligible = GenotypeMatrixReviewEligibility.eligibleReviews(reviews) { support[$0] }
        XCTAssertEqual(Set(eligible.keys), [targets[0], targets[2]])
        XCTAssertEqual(reviews.count, 4)
        XCTAssertEqual(reviews[1], reviews[3])
        XCTAssertEqual(support[targets[1]], 7)
    }

    func testEligibilityRequiresAttestedSupportAndCellScope() {
        for support in [nil, -1, 0, 1] as [Int?] {
            XCTAssertEqual(GenotypeMatrixReviewEligibility.permits(.falsePositive, rawSupport: support), support == 1)
            XCTAssertEqual(GenotypeMatrixReviewEligibility.permits(.falseNegative, rawSupport: support), support == 0)
        }
        let row = GenotypeAnnotationSidecar.MatrixReviewAnnotation(target: .row(locus: "MHC-A", genotype: "G"), disposition: .falsePositive, author: "A", timestamp: "now")
        XCTAssertTrue(GenotypeMatrixReviewEligibility.eligibleReviews([row]) { _ in 8 }.isEmpty)
    }
}
