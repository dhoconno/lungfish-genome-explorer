import XCTest
@testable import LungfishWorkflow

final class ViralReconReferenceCatalogTests: XCTestCase {
    func testCanonicalAccessionIsMN908947_3() {
        XCTAssertEqual(ViralReconReferenceCatalog.canonicalAccession, "MN908947.3")
    }

    func testBundleFilenameMatchesAccession() {
        XCTAssertEqual(ViralReconReferenceCatalog.bundleFilename, "MN908947.3.lungfishref")
    }

    func testBundleURLIsInProjectDownloads() {
        let project = URL(fileURLWithPath: "/tmp/My Project.lungfish")
        let url = ViralReconReferenceCatalog.bundleURL(inProject: project)
        XCTAssertEqual(url.path, "/tmp/My Project.lungfish/Downloads/MN908947.3.lungfishref")
    }

    // NC_045512.2 is the same genome under a different accession. It is recorded
    // so callers can explain why it is refused, never so it can be substituted.
    func testEquivalentAccessionsAreRecordedButNotCanonical() {
        XCTAssertTrue(ViralReconReferenceCatalog.equivalentAccessions.contains("NC_045512.2"))
        XCTAssertFalse(ViralReconReferenceCatalog.equivalentAccessions.contains(
            ViralReconReferenceCatalog.canonicalAccession))
    }
}
