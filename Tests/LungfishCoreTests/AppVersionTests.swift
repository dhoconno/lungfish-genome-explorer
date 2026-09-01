import XCTest
@testable import LungfishCore

final class AppVersionTests: XCTestCase {
    func testCanonicalReleaseVersion() {
        XCTAssertEqual(LungfishAppVersion.short, "2026.9.1")
        XCTAssertEqual(LungfishAppVersion.cliToolVersion, "lungfish-cli 2026.9.1")
    }
}
