import XCTest
@testable import LungfishCore

final class AppVersionTests: XCTestCase {
    func testCanonicalReleaseVersion() {
        XCTAssertEqual(LungfishAppVersion.short, "0.5.0-beta22")
        XCTAssertEqual(LungfishAppVersion.cliToolVersion, "lungfish-cli 0.5.0-beta22")
    }
}
