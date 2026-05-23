import XCTest
@testable import LungfishIO

final class GenotypeDropoutEvaluatorTests: XCTestCase {
    func testAbsoluteOnly() {
        let evaluator = GenotypeDropoutEvaluator(absolute: 50, sampleFraction: nil, locusFraction: nil)
        XCTAssertTrue(evaluator.isLowSupport(reads: 28, sampleTotal: 50000, locusTotal: 770))
        XCTAssertFalse(evaluator.isLowSupport(reads: 198, sampleTotal: 50000, locusTotal: 770))
    }

    func testLocusFractionOnly() {
        let evaluator = GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: 0.05)
        XCTAssertTrue(evaluator.isLowSupport(reads: 28, sampleTotal: 50000, locusTotal: 770))
        XCTAssertFalse(evaluator.isLowSupport(reads: 100, sampleTotal: 50000, locusTotal: 770))
    }

    func testSampleFractionOnly() {
        let evaluator = GenotypeDropoutEvaluator(absolute: nil, sampleFraction: 0.001, locusFraction: nil)
        XCTAssertTrue(evaluator.isLowSupport(reads: 28, sampleTotal: 50000, locusTotal: 770))
        XCTAssertFalse(evaluator.isLowSupport(reads: 100, sampleTotal: 50000, locusTotal: 770))
    }

    func testAllModesOrTogether() {
        let evaluator = GenotypeDropoutEvaluator(absolute: 200, sampleFraction: nil, locusFraction: 0.05)
        XCTAssertTrue(evaluator.isLowSupport(reads: 100, sampleTotal: 50000, locusTotal: 770))
        XCTAssertTrue(evaluator.isLowSupport(reads: 30, sampleTotal: 50000, locusTotal: 770))
    }

    func testAllNilNeverLowSupport() {
        let evaluator = GenotypeDropoutEvaluator(absolute: nil, sampleFraction: nil, locusFraction: nil)
        XCTAssertFalse(evaluator.isLowSupport(reads: 1, sampleTotal: 50000, locusTotal: 770))
    }
}
