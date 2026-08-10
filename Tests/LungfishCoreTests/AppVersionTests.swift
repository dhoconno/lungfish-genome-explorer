import XCTest
@testable import LungfishCore

final class AppVersionTests: XCTestCase {
    func testCanonicalReleaseVersion() {
        XCTAssertEqual(LungfishAppVersion.short, "0.5.0-beta26")
        XCTAssertEqual(LungfishAppVersion.cliToolVersion, "lungfish-cli 0.5.0-beta26")
    }
}
