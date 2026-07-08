import XCTest
@testable import LungfishCore

final class AppVersionTests: XCTestCase {
    func testCanonicalVersionIsBeta4() {
        XCTAssertEqual(LungfishAppVersion.short, "0.5.0-beta4")
        XCTAssertEqual(LungfishAppVersion.cliToolVersion, "lungfish-cli 0.5.0-beta4")
    }
}
