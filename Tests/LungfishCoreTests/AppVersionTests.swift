import XCTest
@testable import LungfishCore

final class AppVersionTests: XCTestCase {
    func testCanonicalVersionIsBeta9() {
        XCTAssertEqual(LungfishAppVersion.short, "0.5.0-beta9")
        XCTAssertEqual(LungfishAppVersion.cliToolVersion, "lungfish-cli 0.5.0-beta9")
    }
}
