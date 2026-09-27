import XCTest
import ArgumentParser
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// `lungfish-cli convert` and `import vcf` publish through provenance
/// receipts. Run from a working directory reached through a symlink (`/tmp`
/// on macOS) or given physical `/private/...` paths, they used to fail with
/// "no longer matches the transaction generation" because the receipt and
/// the mutation named the same file through different aliases.
final class SymlinkedPathPublicationTests: XCTestCase {
    private var root: URL!
    private var real: URL!
    private var link: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SymlinkedPathPublicationTests-\(UUID().uuidString)", isDirectory: true)
        real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func physical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.canonicalFilePath)
    }

    private func writeFASTA(at url: URL) throws {
        try ">seq1 test\nACGTACGTACGTACGTACGT\n".write(to: url, atomically: true, encoding: .utf8)
    }

    func testConvertSucceedsWithPhysicalPrivatePaths() async throws {
        let input = physical(real.appendingPathComponent("in.fa"))
        XCTAssertTrue(input.path.hasPrefix("/private/"), input.path)
        try writeFASTA(at: input)
        let output = physical(real.appendingPathComponent("out.gb"))

        let command = try ConvertCommand.parse([input.path, "--to", output.path, "--to-format", "genbank", "--quiet"])
        try await command.run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path))

        // A second run replacing the now-existing output takes the other branch
        // of Foundation's /private handling and must succeed as well.
        let again = try ConvertCommand.parse([input.path, "--to", output.path, "--to-format", "genbank", "--force", "--quiet"])
        try await again.run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testConvertSucceedsThroughSymlinkedDirectory() async throws {
        let input = link.appendingPathComponent("in.fa")
        try writeFASTA(at: input)
        let output = link.appendingPathComponent("out.fasta")

        let command = try ConvertCommand.parse([input.path, "--to", output.path, "--to-format", "fasta", "--quiet"])
        try await command.run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("out.fasta").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ProvenanceRecorder.fileSidecarURL(for: real.appendingPathComponent("out.fasta")).path))
    }

    func testImportVCFSucceedsThroughSymlinkedBundlePath() async throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2/test.vcf")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("sarscov2 fixture VCF missing at \(source.path)")
        }
        let vcfURL = link.appendingPathComponent("test.vcf")
        try FileManager.default.copyItem(at: source, to: vcfURL)

        let bundleURL = physical(real.appendingPathComponent("Ref Bundle.lungfishref", isDirectory: true))
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifest = BundleManifest(
            name: "SARS-CoV-2",
            identifier: "org.lungfish.tests.symlinked-vcf-attach",
            source: SourceInfo(organism: "SARS-CoV-2", assembly: "MT192765.1"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 29_829,
                chromosomes: [
                    ChromosomeInfo(name: "MT192765.1", length: 29_829, offset: 0, lineBases: 70, lineWidth: 71, aliases: [])
                ]
            )
        )
        try manifest.save(to: bundleURL)

        let viaLink = link.appendingPathComponent("Ref Bundle.lungfishref", isDirectory: true)
        let command = try ImportCommand.VCFSubcommand.parse([
            vcfURL.path, "--output-dir", viaLink.path, "--import-profile", "fast", "--quiet",
        ])
        try await command.run()

        let loaded = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(loaded.variants.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("variants/test.lungfish-provenance.json").path))
    }
}
