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

    func testUsesExistingBundleWithoutDownloading() async throws {
        let expected = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        var downloadCalls = 0

        let outcome = try await ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { _, _ in downloadCalls += 1 }
        )

        XCTAssertEqual(outcome, .alreadyPresent(expected))
        XCTAssertEqual(downloadCalls, 0)
    }

    func testDownloadsWhenAbsent() async throws {
        let expected = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        var requested: [String] = []

        let outcome = try await ViralReconReferenceAcquisition.acquire(
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
    func testEquivalentAccessionBundleIsNotSubstituted() async throws {
        let equivalent = projectURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("NC_045512.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: equivalent, withIntermediateDirectories: true)
        var downloadCalls = 0

        let outcome = try await ViralReconReferenceAcquisition.acquire(
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

    func testDownloaderThatProducesNoBundleThrows() async throws {
        await assertThrowsAsync(
            try await ViralReconReferenceAcquisition.acquire(
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
    func testDownloadedBundleCarryingTheEquivalentSequenceNameIsRejected() async throws {
        await assertThrowsAsync(
            try await ViralReconReferenceAcquisition.acquire(
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

    func testDownloadedBundleCarryingTheCanonicalSequenceNameIsAccepted() async throws {
        let outcome = try await ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { _, destination in
                try Self.writeBundle(at: destination.appendingPathComponent(
                    ViralReconReferenceCatalog.bundleFilename, isDirectory: true),
                    sequenceName: "MN908947.3")
            }
        )

        XCTAssertEqual(outcome, .downloaded(ViralReconReferenceCatalog.bundleURL(inProject: projectURL)))
    }

    // Found capturing on 9.58: a project that imported MN908947.3 into
    // Reference Sequences got a second copy downloaded into Downloads.
    func testReusesTheCanonicalBundleInReferenceSequences() async throws {
        let existing = referenceSequencesURL.appendingPathComponent(
            ViralReconReferenceCatalog.bundleFilename, isDirectory: true)
        try Self.writeBundle(at: existing, sequenceName: "MN908947.3")
        var downloadCalls = 0

        let outcome = try await ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { _, _ in downloadCalls += 1 }
        )

        XCTAssertEqual(outcome, .alreadyPresent(existing))
        XCTAssertEqual(downloadCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ViralReconReferenceCatalog.bundleURL(inProject: projectURL).path))
    }

    func testReusesARenamedReferenceSequencesBundleOnlyWhenItHoldsMN908947_3() async throws {
        let renamed = referenceSequencesURL.appendingPathComponent(
            "SARS-CoV-2 Wuhan-Hu-1.lungfishref", isDirectory: true)
        try Self.writeBundle(at: renamed, sequenceName: "MN908947.3")

        let outcome = try await ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL, downloader: { _, _ in XCTFail("must not download") })

        XCTAssertEqual(outcome, .alreadyPresent(renamed))
    }

    func testReferenceSequencesBundleHoldingTheEquivalentAccessionIsNotSubstituted() async throws {
        try Self.writeBundle(
            at: referenceSequencesURL.appendingPathComponent("NC_045512.2.lungfishref", isDirectory: true),
            sequenceName: "NC_045512.2")
        // Named for the canonical accession but indexed as the RefSeq record.
        try Self.writeBundle(
            at: referenceSequencesURL.appendingPathComponent(
                ViralReconReferenceCatalog.bundleFilename, isDirectory: true),
            sequenceName: "NC_045512.2")
        var downloadCalls = 0

        let outcome = try await ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { _, destination in
                downloadCalls += 1
                try Self.writeBundle(at: destination.appendingPathComponent(
                    ViralReconReferenceCatalog.bundleFilename, isDirectory: true),
                    sequenceName: "MN908947.3")
            }
        )

        XCTAssertEqual(outcome, .downloaded(ViralReconReferenceCatalog.bundleURL(inProject: projectURL)))
        XCTAssertEqual(downloadCalls, 1)
    }

    // Regression: a project whose Downloads bundle was fetched while `fetch
    // genome` still substituted NC_045512.2 kept that bundle forever. It was
    // reused without reading its index, so primer staging failed every BED
    // line and the wizard showed "StageError error 1".
    func testStaleDownloadedBundleHoldingTheEquivalentSequenceIsReplaced() async throws {
        let downloaded = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        try Self.writeBundle(at: downloaded, sequenceName: "NC_045512.2")
        XCTAssertNil(ViralReconReferenceCatalog.existingBundleURL(inProject: projectURL))
        var downloadCalls = 0

        let outcome = try await ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { _, destination in
                downloadCalls += 1
                try Self.writeBundle(at: destination.appendingPathComponent(
                    ViralReconReferenceCatalog.bundleFilename, isDirectory: true),
                    sequenceName: "MN908947.3")
            }
        )

        XCTAssertEqual(outcome, .downloaded(downloaded))
        XCTAssertEqual(downloadCalls, 1)
        XCTAssertEqual(
            ViralReconReferenceAcquisition.sequenceIdentifier(inBundleAt: downloaded), "MN908947.3")
    }

    /// XCTAssertThrowsError takes no async expression.
    private func assertThrowsAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected an error", file: file, line: line)
        } catch {
            check(error)
        }
    }

    private var referenceSequencesURL: URL {
        projectURL.appendingPathComponent("Reference Sequences", isDirectory: true)
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
