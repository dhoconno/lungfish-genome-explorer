import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimerSchemeResolverTests: XCTestCase {
    func testCanonicalAccessionMatchReturnsOriginalBEDPath() throws {
        let bundleURL = testBundleURL()
        let bundle = try PrimerSchemeBundle.load(from: bundleURL)

        let resolved = try PrimerSchemeResolver.resolve(
            bundle: bundle,
            targetReferenceName: "MN908947.3"
        )

        XCTAssertEqual(resolved.bedURL, bundle.bedURL)
        XCTAssertFalse(resolved.isRewritten)
    }

    func testEquivalentAccessionMatchRewritesBEDColumnOne() throws {
        let bundleURL = testBundleURL()
        let bundle = try PrimerSchemeBundle.load(from: bundleURL)

        let resolved = try PrimerSchemeResolver.resolve(
            bundle: bundle,
            targetReferenceName: "NC_045512.2"
        )

        XCTAssertNotEqual(resolved.bedURL, bundle.bedURL)
        XCTAssertTrue(resolved.isRewritten)

        let content = try String(contentsOf: resolved.bedURL, encoding: .utf8)
        XCTAssertTrue(content.contains("NC_045512.2"))
        XCTAssertFalse(content.contains("MN908947.3"))

        // The rest of the BED record must be preserved verbatim.
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let cols = line.split(separator: "\t")
            XCTAssertEqual(cols.count, 6)
            XCTAssertEqual(String(cols[0]), "NC_045512.2")
        }
    }

    func testNoMatchThrowsUnknownAccession() throws {
        let bundleURL = testBundleURL()
        let bundle = try PrimerSchemeBundle.load(from: bundleURL)

        XCTAssertThrowsError(
            try PrimerSchemeResolver.resolve(
                bundle: bundle,
                targetReferenceName: "NOT_AN_ACCESSION"
            )
        ) { error in
            guard case PrimerSchemeResolver.ResolveError.unknownAccession = error else {
                XCTFail("wrong error: \(error)"); return
            }
        }
    }

    private func testBundleURL() -> URL {
        return Bundle.module.url(
            forResource: "primerschemes/valid-simple.lungfishprimers",
            withExtension: nil
        )!
    }
}
