import XCTest

final class ClassifierDisplayConcurrencyTests: XCTestCase {
    func testNaoMgsDisplayRechecksSelectionBeforeBundleUpgrade() throws {
        let source = combinedMainSplitViewControllerSource()
        let methodStart = try XCTUnwrap(source.range(of: "func displayNaoMgsResultFromSidebar("))
        let methodEnd = try XCTUnwrap(source[methodStart.upperBound...].range(of: "func upgradeNaoMgsBundleIfNeeded("))
        let methodBody = String(source[methodStart.lowerBound..<methodEnd.lowerBound])

        let decodeRange = try XCTUnwrap(methodBody.range(of: "let manifest = try decoder.decode(NaoMgsManifest.self, from: manifestData)"))
        let guardRange = try XCTUnwrap(methodBody.range(of: "guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }"))
        let cachedRowsRange = try XCTUnwrap(methodBody.range(of: "// If manifest has cached taxon rows, show them immediately."))
        let upgradeRange = try XCTUnwrap(methodBody.range(of: "try await upgradeNaoMgsBundleIfNeeded(bundleURL: bundleURL, manifest: manifest)"))

        XCTAssertLessThan(decodeRange.upperBound, guardRange.lowerBound)
        XCTAssertLessThan(
            guardRange.upperBound,
            cachedRowsRange.lowerBound,
            "The post-manifest guard must be unconditional, before the cached-row branch."
        )
        XCTAssertLessThan(
            guardRange.upperBound,
            upgradeRange.lowerBound,
            "NAO-MGS display must re-check the display generation after the awaited manifest read and before any DB upgrade side effect."
        )
    }
}
