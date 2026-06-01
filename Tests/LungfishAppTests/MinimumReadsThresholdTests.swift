import XCTest
@testable import LungfishApp
import LungfishAppKit

final class MinimumReadsThresholdTests: XCTestCase {
    func testActiveThresholdIsZeroWhenDisabled() {
        XCTAssertEqual(MinimumReadsThreshold(value: 5_000, isEnabled: false).active, 0)
        XCTAssertEqual(MinimumReadsThreshold(value: 5_000, isEnabled: true).active, 5_000)
        XCTAssertEqual(MinimumReadsThreshold(value: -5).active, 0)
    }

    func testIncludesReadsRespectsActiveThreshold() {
        let threshold = MinimumReadsThreshold(value: 5_000)
        XCTAssertTrue(threshold.includes(reads: 5_000))
        XCTAssertTrue(threshold.includes(reads: 6_000))
        XCTAssertFalse(threshold.includes(reads: 4_999))

        let disabled = MinimumReadsThreshold(value: 5_000, isEnabled: false)
        XCTAssertTrue(disabled.includes(reads: 0))
    }
}
