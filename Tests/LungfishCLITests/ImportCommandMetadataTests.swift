import XCTest
import ArgumentParser
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO

final class ImportCommandMetadataTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportCommandMetadataTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testSampleMetadataSubcommandParsesArguments() throws {
        let command = try ImportCommand.SampleMetadataSubcommand.parse([
            "samples.csv",
            "--bundle",
            "/tmp/Test.lungfishref",
        ])

        XCTAssertEqual(command.inputPath, "samples.csv")
        XCTAssertEqual(command.bundlePath, "/tmp/Test.lungfishref")
    }

    func testSampleMetadataSubcommandImportsIntoVariantBundle() async throws {
        let bundleURL = try makeVariantBundle()
        let metadataURL = tempDir.appendingPathComponent("variant-metadata.csv")
        try """
        sample_name,lineage,status
        test,B.1.1.7,confirmed
        """.write(to: metadataURL, atomically: true, encoding: .utf8)

        let command = try ImportCommand.SampleMetadataSubcommand.parse([
            metadataURL.path,
            "--bundle",
            bundleURL.path,
            "--quiet",
        ])
        try await command.run()

        let dbURL = bundleURL.appendingPathComponent("variants.db")
        let database = try VariantDatabase(url: dbURL)
        let metadata = database.sampleMetadata(name: "test")
        XCTAssertEqual(metadata["lineage"], "B.1.1.7")
        XCTAssertEqual(metadata["status"], "confirmed")
    }

    func testVCFSubcommandRejectsVCFv3BeforeCopying() async throws {
        let vcfURL = tempDir.appendingPathComponent("legacy.vcf")
        try """
        ##fileformat=VCFv3.3
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\t.
        """.write(to: vcfURL, atomically: true, encoding: .utf8)

        let outputURL = tempDir.appendingPathComponent("output", isDirectory: true)
        let command = try ImportCommand.VCFSubcommand.parse([
            vcfURL.path,
            "--output-dir",
            outputURL.path,
            "--quiet",
        ])

        do {
            try await command.run()
            XCTFail("Expected VCFv3 import to fail")
        } catch let exitCode as ExitCode {
            XCTAssertEqual(exitCode, .failure)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputURL.appendingPathComponent("legacy.vcf").path),
            "Unsupported VCFv3 input must fail before copying into the output directory"
        )
    }

    private func makeVariantBundle() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("TestBundle.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let vcfURL = tempDir.appendingPathComponent("variants.vcf")
        try """
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\ttest
        chr1\t100\trs1\tA\tG\t30.0\tPASS\t.\tGT\t0/1
        """.write(to: vcfURL, atomically: true, encoding: .utf8)

        let variantDBURL = bundleURL.appendingPathComponent("variants.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: variantDBURL
        )

        let manifest = BundleManifest(
            name: "Test Bundle",
            identifier: "org.lungfish.tests.variant-bundle",
            source: SourceInfo(organism: "SARS-CoV-2", assembly: "MT192765.1"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 29_903,
                chromosomes: []
            ),
            variants: [
                VariantTrackInfo(
                    id: "variants",
                    name: "Variants",
                    path: "variants.bcf",
                    indexPath: "variants.bcf.csi",
                    databasePath: "variants.db"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
