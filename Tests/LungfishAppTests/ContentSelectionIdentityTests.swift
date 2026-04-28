import XCTest
@testable import LungfishApp

final class ContentSelectionIdentityTests: XCTestCase {
    func testStandardizedURLsMatchForEquivalentPaths() {
        let base = URL(fileURLWithPath: "/tmp/project/../project/results", isDirectory: true)
        let equivalent = URL(fileURLWithPath: "/tmp/project/results", isDirectory: true)

        let first = ContentSelectionIdentity(url: base, kind: "nvd", sampleID: "S1", resultID: "R1")
        let second = ContentSelectionIdentity(url: equivalent, kind: "nvd", sampleID: "S1", resultID: "R1")

        XCTAssertEqual(first, second)
    }

    func testDifferentSamplesDoNotMatchEvenWithSameURLAndResult() {
        let url = URL(fileURLWithPath: "/tmp/results", isDirectory: true)

        let sampleA = ContentSelectionIdentity(url: url, kind: "taxon", sampleID: "A", resultID: "9606")
        let sampleB = ContentSelectionIdentity(url: url, kind: "taxon", sampleID: "B", resultID: "9606")

        XCTAssertNotEqual(sampleA, sampleB)
    }

    func testWindowScopesAreUniqueUnlessExplicitlyReused() {
        let first = WindowStateScope()
        let second = WindowStateScope()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, first)
    }
}
