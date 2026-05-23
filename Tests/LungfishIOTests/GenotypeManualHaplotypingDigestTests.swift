import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeManualHaplotypingDigestTests: XCTestCase {
    private func call(sample: String, genotype: String, reads: Int) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    func testGroupsByLocusAndGenotype() {
        let digest = GenotypeManualHaplotypingDigest.build(from: [
            call(sample: "S1", genotype: "05_M1M2M3_A1_063g", reads: 100),
            call(sample: "S2", genotype: "05_M1M2M3_A1_063g", reads: 80),
            call(sample: "S2", genotype: "07_M3_70_156bp", reads: 60),
            call(sample: "S3", genotype: "07_M3_70_156bp", reads: 70),
        ])
        let a1 = digest.observations.first(where: { $0.genotype == "05_M1M2M3_A1_063g" })
        let m3 = digest.observations.first(where: { $0.genotype == "07_M3_70_156bp" })
        XCTAssertNotNil(a1)
        XCTAssertEqual(a1?.sampleCount, 2)
        XCTAssertEqual(a1?.totalReads, 180)
        XCTAssertEqual(a1?.sampleIds, ["S1", "S2"])
        XCTAssertEqual(m3?.sampleCount, 2)
        XCTAssertEqual(m3?.totalReads, 130)
    }

    func testCustomLocusFunctionTakesPrecedence() {
        let digest = GenotypeManualHaplotypingDigest.build(
            from: [
                call(sample: "S1", genotype: "01_X_001", reads: 20),
                call(sample: "S2", genotype: "01_X_001", reads: 30),
            ],
            locusFor: { _ in "Custom" }
        )
        XCTAssertEqual(digest.observations.count, 1)
        XCTAssertEqual(digest.observations[0].locus, "Custom")
        XCTAssertEqual(digest.observations[0].totalReads, 50)
    }

    func testEmptyInputProducesEmptyDigest() {
        let digest = GenotypeManualHaplotypingDigest.build(from: [])
        XCTAssertTrue(digest.observations.isEmpty)
    }

    func testObservationsSortedByLocusThenReadsDescending() {
        let digest = GenotypeManualHaplotypingDigest.build(from: [
            call(sample: "S1", genotype: "01_X_low", reads: 10),
            call(sample: "S1", genotype: "01_X_high", reads: 500),
            call(sample: "S1", genotype: "02_Y_mid", reads: 200),
        ])
        XCTAssertEqual(digest.observations.map(\.genotype),
                       ["01_X_high", "01_X_low", "02_Y_mid"])
    }
}
