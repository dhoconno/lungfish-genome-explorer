import XCTest
@testable import LungfishWorkflow

final class ViralReconReferenceAcquisitionTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vr-ref-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    func testUsesExistingBundleWithoutDownloading() throws {
        let expected = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        var downloadCalls = 0

        let outcome = try ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { _, _ in downloadCalls += 1 }
        )

        XCTAssertEqual(outcome, .alreadyPresent(expected))
        XCTAssertEqual(downloadCalls, 0)
    }

    func testDownloadsWhenAbsent() throws {
        let expected = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        var requested: [String] = []

        let outcome = try ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { accession, destination in
                requested.append(accession)
                try FileManager.default.createDirectory(
                    at: destination.appendingPathComponent(ViralReconReferenceCatalog.bundleFilename,
                                                          isDirectory: true),
                    withIntermediateDirectories: true)
            }
        )

        XCTAssertEqual(outcome, .downloaded(expected))
        XCTAssertEqual(requested, ["MN908947.3"])
    }

    // A project holding only the equivalent accession must still download the
    // canonical one. Substituting it would leave the primer BED unmatched.
    func testEquivalentAccessionBundleIsNotSubstituted() throws {
        let equivalent = projectURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("NC_045512.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: equivalent, withIntermediateDirectories: true)
        var downloadCalls = 0

        let outcome = try ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { _, destination in
                downloadCalls += 1
                try FileManager.default.createDirectory(
                    at: destination.appendingPathComponent(ViralReconReferenceCatalog.bundleFilename,
                                                          isDirectory: true),
                    withIntermediateDirectories: true)
            }
        )

        XCTAssertEqual(downloadCalls, 1)
        XCTAssertEqual(outcome, .downloaded(ViralReconReferenceCatalog.bundleURL(inProject: projectURL)))
    }

    func testDownloaderThatProducesNoBundleThrows() throws {
        XCTAssertThrowsError(
            try ViralReconReferenceAcquisition.acquire(
                projectURL: projectURL,
                downloader: { _, _ in }
            )
        ) { error in
            XCTAssertEqual(error as? ViralReconReferenceAcquisition.AcquisitionError,
                           .downloadProducedNoBundle(ViralReconReferenceCatalog.canonicalAccession))
        }
    }
}
