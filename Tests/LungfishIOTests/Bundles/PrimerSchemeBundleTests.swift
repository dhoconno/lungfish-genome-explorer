import XCTest
@testable import LungfishIO

final class PrimerSchemeBundleTests: XCTestCase {
    func testLoadValidBundleReturnsManifestWithCanonicalAndEquivalentAccessions() throws {
        let bundleURL = Bundle.module.url(
            forResource: "primerschemes/valid-simple.lungfishprimers",
            withExtension: nil
        )!

        let bundle = try PrimerSchemeBundle.load(from: bundleURL)

        XCTAssertEqual(bundle.manifest.name, "test-simple")
        XCTAssertEqual(bundle.manifest.displayName, "Test Simple Primer Set")
        XCTAssertEqual(bundle.manifest.canonicalAccession, "MN908947.3")
        XCTAssertEqual(bundle.manifest.equivalentAccessions, ["NC_045512.2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.bedURL.path))
    }

    func testLoadBundleMissingManifestThrows() {
        let tmp = try! TestWorkspace.makeEmptyBundle(name: "no-manifest.lungfishprimers")
        XCTAssertThrowsError(try PrimerSchemeBundle.load(from: tmp)) { error in
            guard case PrimerSchemeBundle.LoadError.missingManifest = error else {
                XCTFail("wrong error: \(error)"); return
            }
        }
    }

    func testLoadBundleMissingBEDThrows() {
        let tmp = try! TestWorkspace.makeBundleWithOnlyManifest()
        XCTAssertThrowsError(try PrimerSchemeBundle.load(from: tmp)) { error in
            guard case PrimerSchemeBundle.LoadError.missingBED = error else {
                XCTFail("wrong error: \(error)"); return
            }
        }
    }

    func testLoadBundleWithMalformedManifestThrows() {
        let tmp = try! TestWorkspace.makeBundleWithMalformedManifest()
        XCTAssertThrowsError(try PrimerSchemeBundle.load(from: tmp)) { error in
            guard case PrimerSchemeBundle.LoadError.invalidManifest = error else {
                XCTFail("wrong error: \(error)"); return
            }
        }
    }
}
