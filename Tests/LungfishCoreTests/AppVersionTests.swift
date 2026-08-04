import XCTest
@testable import LungfishCore

final class AppVersionTests: XCTestCase {
    func testCanonicalVersionIsBeta17() {
        XCTAssertEqual(LungfishAppVersion.short, "0.5.0-beta20")
        XCTAssertEqual(LungfishAppVersion.cliToolVersion, "lungfish-cli 0.5.0-beta20")
    }
}
