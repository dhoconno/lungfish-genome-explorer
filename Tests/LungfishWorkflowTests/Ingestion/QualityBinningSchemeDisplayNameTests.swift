import XCTest
@testable import LungfishWorkflow

final class QualityBinningSchemeDisplayNameTests: XCTestCase {
    func testPersistedRawValuesShowTheirLevelCounts() {
        XCTAssertEqual(QualityBinningScheme.displayName(forRawValue: "illumina4"), "Illumina (7-level)")
        XCTAssertEqual(QualityBinningScheme.displayName(forRawValue: "eightLevel"), "Fine (~21-level)")
        XCTAssertEqual(QualityBinningScheme.displayName(forRawValue: "none"), "None (preserve original)")
    }

    func testUnknownRawValueIsShownAsIs() {
        XCTAssertEqual(QualityBinningScheme.displayName(forRawValue: "futureScheme"), "futureScheme")
    }
}
