import XCTest
@testable import LungfishCore

final class AppVersionTests: XCTestCase {
    func testCanonicalVersionIsBeta14() {
        XCTAssertEqual(LungfishAppVersion.short, "0.5.0-beta14")
        XCTAssertEqual(LungfishAppVersion.cliToolVersion, "lungfish-cli 0.5.0-beta14")
    }
}
