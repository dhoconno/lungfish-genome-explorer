import XCTest
import LungfishTestSupport
@testable import LungfishIO

final class GenotypeMatrixReviewEligibilityTests: XCTestCase {
    private typealias CatalogRow = GenotypeReviewableRowCatalog.Row

    private static let production = "03_Mafa_A1_PROD"
    private static let other = "04_Mafa_A1_OTHER"

    /// Calls PROD (S3 at 4) and OTHER (S1 at 2), both at MHC-A, over a
    /// three-animal catalog roster.
    private func makeCatalogResult(rows: [CatalogRow]) -> ONTGenotypeResultBundleData {
        let result = GenotypeTestFixtures.makeResult(
            calls: [
                GenotypeTestFixtures.makeCall(sample: "S3", genotype: Self.production, reads: 4),
                GenotypeTestFixtures.makeCall(sample: "S1", genotype: Self.other, reads: 2),
            ],
            reviewableRowCatalog: GenotypeReviewableRowCatalog(samples: ["S1", "S2", "S3"], rows: rows)
        )
        XCTAssertEqual(result.calls.map(\.locusGroup), ["MHC-A", "MHC-A"])
        return result
    }

    private func referenceRow(callID: String, displayName: String, locus: String = "MHC-A",
                              support: [String: Int]) -> CatalogRow {
        .init(kind: .reference, callID: callID, displayName: displayName, locus: locus,
              stableID: nil, section: "reference", sortKey: callID, supportBySample: support)
    }

    // MARK: Catalog-attested zeros (Phase 2.3 finding S1)

    /// The real publisher writes `reference:<locus>:<allele>` call IDs. The
    /// row's zeros are attested under the native identity its display name
    /// names, the identity the matrix and the workbook key cells by.
    func testRawSupportAttestsProductionShapeCatalogZerosUnderTheNativeIdentity() {
        let result = makeCatalogResult(rows: [
            referenceRow(callID: "reference:MHC-A:\(Self.production)", displayName: Self.production,
                         support: ["S1": 0, "S2": 0, "S3": 4]),
        ])
        let support = GenotypeMatrixReviewEligibility.rawSupport(in: result)
        XCTAssertEqual(support[.cell(locus: "MHC-A", genotype: Self.production, sample: "S1")], 0)
        XCTAssertEqual(support[.cell(locus: "MHC-A", genotype: Self.production, sample: "S2")], 0)
        XCTAssertEqual(support[.cell(locus: "MHC-A", genotype: Self.production, sample: "S3")], 4)
        XCTAssertEqual(support[.cell(locus: "MHC-A", genotype: Self.other, sample: "S1")], 2)
        XCTAssertEqual(support.count, 4, "no cell is keyed by the transport call ID")
        XCTAssertTrue(GenotypeMatrixReviewEligibility.permits(
            .falseNegative, rawSupport: support[.cell(locus: "MHC-A", genotype: Self.production, sample: "S1")]))
    }

    /// A row that names no native row stands alone under its own locus and
    /// display name, the row the workbook appends to its All sheet.
    func testRawSupportKeysAnUnmatchedCatalogRowByItsDisplayNameLikeTheWorkbook() {
        let result = makeCatalogResult(rows: [
            referenceRow(callID: "reference:MHC-B:Mafa-B*099:01", displayName: "Mafa-B*099:01", locus: "MHC-B",
                         support: ["S1": 0, "S2": 0, "S3": 0]),
        ])
        let support = GenotypeMatrixReviewEligibility.rawSupport(in: result)
        for sample in ["S1", "S2", "S3"] {
            XCTAssertEqual(support[.cell(locus: "MHC-B", genotype: "Mafa-B*099:01", sample: sample)], 0, sample)
        }
        XCTAssertEqual(support.count, 5)
    }

    /// The workbook refuses a catalog that names two native rows or disagrees
    /// with an observation, so no catalog cell is reviewable there. The matrix
    /// then attests the native observations alone.
    func testRawSupportKeepsNativeObservationsAloneWhenTheCatalogRefuses() {
        let native = GenotypeMatrixReviewEligibility.rawSupport(in: makeCatalogResult(rows: []))
        XCTAssertEqual(native.count, 2)
        // The row names PROD by its call ID and OTHER by its display name.
        let ambiguous = makeCatalogResult(rows: [
            referenceRow(callID: Self.production, displayName: Self.other, support: ["S1": 0, "S2": 0, "S3": 4]),
        ])
        XCTAssertEqual(GenotypeMatrixReviewEligibility.rawSupport(in: ambiguous), native)
        // The catalog records 5 reads where the call observed 4.
        let disagreeing = makeCatalogResult(rows: [
            referenceRow(callID: "reference:MHC-A:\(Self.production)", displayName: Self.production,
                         support: ["S1": 0, "S2": 0, "S3": 5]),
        ])
        XCTAssertEqual(GenotypeMatrixReviewEligibility.rawSupport(in: disagreeing), native)
    }

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
