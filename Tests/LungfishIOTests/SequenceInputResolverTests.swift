import XCTest
@testable import LungfishCore
@testable import LungfishIO

final class SequenceInputResolverTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SequenceInputResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testReferenceBundleResolverRejectsManifestTraversalPath() throws {
        let outsideURL = tempDirectory.appendingPathComponent("outside.fa")
        try Data(">chr1\nACGT\n".utf8).write(to: outsideURL)

        let bundleURL = try makeReferenceBundle(genomePath: "../outside.fa")

        XCTAssertNil(SequenceInputResolver.resolvePrimarySequenceURL(for: bundleURL))
        XCTAssertNil(SequenceInputResolver.inputSequenceFormat(for: bundleURL))
    }

    func testReferenceBundleResolverRejectsSymlinkEscape() throws {
        let outsideURL = tempDirectory.appendingPathComponent("outside.fa")
        try Data(">chr1\nACGT\n".utf8).write(to: outsideURL)

        let bundleURL = try makeReferenceBundle(genomePath: "genome/sequence.fa")
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: genomeDirectory.appendingPathComponent("sequence.fa"),
            withDestinationURL: outsideURL
        )

        XCTAssertNil(SequenceInputResolver.resolvePrimarySequenceURL(for: bundleURL))
        XCTAssertNil(SequenceInputResolver.inputSequenceFormat(for: bundleURL))
    }

    private func makeReferenceBundle(genomePath: String) throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("test.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = BundleManifest(
            name: "Test Reference",
            identifier: "org.lungfish.test",
            source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
            genome: GenomeInfo(
                path: genomePath,
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 80, lineWidth: 81)
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
