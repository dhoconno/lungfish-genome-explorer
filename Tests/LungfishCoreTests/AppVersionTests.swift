import XCTest
@testable import LungfishCore

final class AppVersionTests: XCTestCase {
    func testCanonicalVersionIsBeta10() {
        XCTAssertEqual(LungfishAppVersion.short, "0.5.0-beta10")
        XCTAssertEqual(LungfishAppVersion.cliToolVersion, "lungfish-cli 0.5.0-beta10")
    }
}
