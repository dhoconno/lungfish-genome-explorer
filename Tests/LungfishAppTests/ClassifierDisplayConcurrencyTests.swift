import XCTest
import LungfishTestSupport

final class ClassifierDisplayConcurrencyTests: XCTestCase {
    func testNaoMgsDisplayDoesNotRewriteBundleDuringViewing() throws {
        let source = combinedMainSplitViewControllerSource()
        let methodStart = try XCTUnwrap(source.range(of: "func displayNaoMgsResultFromSidebar("))
        let methodEnd = try XCTUnwrap(source[methodStart.upperBound...].range(of: "/// Displays an NVD result"))
        let methodBody = String(source[methodStart.lowerBound..<methodEnd.lowerBound])

        let decodeRange = try XCTUnwrap(methodBody.range(of: "let manifest = try decoder.decode(NaoMgsManifest.self, from: manifestData)"))
        let guardRange = try XCTUnwrap(methodBody.range(of: "guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }"))
        let cachedRowsRange = try XCTUnwrap(methodBody.range(of: "// If manifest has cached taxon rows, show them immediately."))

        XCTAssertLessThan(decodeRange.upperBound, guardRange.lowerBound)
        XCTAssertLessThan(
            guardRange.upperBound,
            cachedRowsRange.lowerBound,
            "The post-manifest guard must be unconditional, before the cached-row branch."
        )
        XCTAssertTrue(methodBody.contains("naomgsBundleNeedsUpgrade(dbURL: dbURL)"))
        XCTAssertTrue(methodBody.contains("Viewing no longer rewrites scientific bundle data automatically."))
        XCTAssertFalse(methodBody.contains("upgradeNaoMgsBundleIfNeeded"))
        XCTAssertFalse(source.contains("func upgradeNaoMgsBundleIfNeeded"))
        XCTAssertFalse(source.contains("deleteVirusHitsAndVacuum"))
        XCTAssertFalse(
            source.contains("removeItem(at: dbURL)"),
            "Viewing a NAO-MGS result must not delete or replace hits.sqlite."
        )
    }
}
