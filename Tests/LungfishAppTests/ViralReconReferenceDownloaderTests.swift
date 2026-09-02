import XCTest
@testable import LungfishApp

final class ViralReconReferenceDownloaderTests: XCTestCase {
    // `lungfish-cli fetch genome` takes the accession as a positional argument,
    // not as `--accession`. Verified against the built binary's help output.
    func testArgumentsInvokeFetchGenomeWithAccessionAndOutputDirectory() {
        let destination = URL(fileURLWithPath: "/tmp/My Project.lungfish/Downloads")

        let args = ViralReconReferenceDownloader.arguments(
            accession: "MN908947.3",
            destinationDirectory: destination)

        XCTAssertEqual(Array(args.prefix(3)), ["fetch", "genome", "MN908947.3"])
        XCTAssertFalse(args.contains("--accession"))
        XCTAssertTrue(args.contains("--output-dir"))
        XCTAssertTrue(args.contains(destination.path))
    }

    func testArgumentsNameTheBundleAfterTheAccession() {
        // The acquisition step looks for `MN908947.3.lungfishref`, and the CLI
        // derives the bundle directory name from `--name`, so without this the
        // bundle lands under an organism-derived name and is never found.
        let args = ViralReconReferenceDownloader.arguments(
            accession: "MN908947.3",
            destinationDirectory: URL(fileURLWithPath: "/tmp/d"))

        let nameIndex = try? XCTUnwrap(args.firstIndex(of: "--name"))
        XCTAssertNotNil(nameIndex)
        if let nameIndex {
            XCTAssertEqual(args[args.index(after: nameIndex)], "MN908947.3")
        }
    }

    func testArgumentsDoNotSuppressBundleCreation() {
        let args = ViralReconReferenceDownloader.arguments(
            accession: "MN908947.3",
            destinationDirectory: URL(fileURLWithPath: "/tmp/d"))

        // The bundle is the whole point of the download.
        XCTAssertFalse(args.contains("--no-bundle"))
        XCTAssertFalse(args.contains("--fasta-only"))
    }
}
