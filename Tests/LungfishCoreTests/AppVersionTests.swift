import XCTest
@testable import LungfishCore

final class AppVersionTests: XCTestCase {
    func testUnstampedProcessReportsTheDevelopmentBaseline() {
        // xctest carries no stamped Lungfish bundle.
        XCTAssertEqual(LungfishAppVersion.short, LungfishAppVersion.developmentBaseline)
        XCTAssertEqual(LungfishAppVersion.cliToolVersion, "lungfish-cli \(LungfishAppVersion.developmentBaseline)")
        XCTAssertTrue(LungfishAppVersion.isReleaseVersion(LungfishAppVersion.developmentBaseline))
    }

    func testStampedAppInfoNamesTheVersion() {
        let app: [String: Any] = ["LungfishReleaseChannel": "preview", "CFBundleShortVersionString": "2026.11.3"]
        XCTAssertEqual(RuntimeAppIdentityResolver.resolveVersion(mainAppInfo: app), "2026.11.3")
    }

    func testBundledCommandLineToolReadsItsEnclosingApp() {
        // The packaged CLI's own section carries identity but no version.
        let embedded: [String: Any] = ["LungfishReleaseChannel": "stable"]
        let enclosing: [String: Any] = ["LungfishReleaseChannel": "stable", "CFBundleShortVersionString": "2026.11.3"]
        XCTAssertEqual(
            RuntimeAppIdentityResolver.resolveVersion(embeddedExecutableInfo: embedded, enclosingAppInfo: enclosing),
            "2026.11.3"
        )
        XCTAssertNil(RuntimeAppIdentityResolver.resolveVersion(embeddedExecutableInfo: embedded))
    }

    func testTheRunningAppNeverBorrowsAVersion() {
        XCTAssertNil(RuntimeAppIdentityResolver.resolveVersion(
            mainAppInfo: ["LungfishReleaseChannel": "preview"],
            enclosingAppInfo: ["LungfishReleaseChannel": "preview", "CFBundleShortVersionString": "2026.11.3"]
        ))
    }

    func testForeignAndMalformedVersionsAreIgnored() {
        // A host such as xctest or Xcode has its own version and no Lungfish channel.
        XCTAssertNil(RuntimeAppIdentityResolver.resolveVersion(mainAppInfo: ["CFBundleShortVersionString": "26.4"]))
        for value in ["2026.08.1", "2026.13.1", "2026.10.0", "2026.10.1-beta1", "$(MARKETING_VERSION)", ""] {
            XCTAssertFalse(LungfishAppVersion.isReleaseVersion(value), value)
            XCTAssertNil(RuntimeAppIdentityResolver.resolveVersion(
                mainAppInfo: ["LungfishReleaseChannel": "preview", "CFBundleShortVersionString": value]
            ), value)
        }
    }
}
