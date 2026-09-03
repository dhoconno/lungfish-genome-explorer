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
    // Regression: `fetch genome` resolves accessions through the NCBI assembly
    // database, where MN908947.3 has no record of its own, so the search lands
    // on the linked RefSeq assembly and returns NC_045512.2 under the requested
    // name. The bundle exists and is named correctly, so an existence check
    // passes while every primer BED line fails to match. Verified against NCBI
    // on 2026-09-02.
    func testDownloadedBundleCarryingTheEquivalentSequenceNameIsRejected() throws {
        XCTAssertThrowsError(
            try ViralReconReferenceAcquisition.acquire(
                projectURL: projectURL,
                downloader: { _, destination in
                    try Self.writeBundle(at: destination.appendingPathComponent(
                        ViralReconReferenceCatalog.bundleFilename, isDirectory: true),
                        sequenceName: "NC_045512.2")
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? ViralReconReferenceAcquisition.AcquisitionError,
                .sequenceIdentifierMismatch(expected: "MN908947.3", found: "NC_045512.2"))
        }
    }

    func testDownloadedBundleCarryingTheCanonicalSequenceNameIsAccepted() throws {
        let outcome = try ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { _, destination in
                try Self.writeBundle(at: destination.appendingPathComponent(
                    ViralReconReferenceCatalog.bundleFilename, isDirectory: true),
                    sequenceName: "MN908947.3")
            }
        )

        XCTAssertEqual(outcome, .downloaded(ViralReconReferenceCatalog.bundleURL(inProject: projectURL)))
    }

    /// Writes the `.fai` a real bundle carries, which names the sequence.
    private static func writeBundle(at bundleURL: URL, sequenceName: String) throws {
        let genome = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        try "\(sequenceName)\t29903\t97\t80\t81\n"
            .write(to: genome.appendingPathComponent("sequence.fa.gz.fai"),
                   atomically: true, encoding: .utf8)
    }
}
