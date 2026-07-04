import XCTest
import ArgumentParser
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

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

        let dbURL = bundleURL.appendingPathComponent("variants.db")
        let preImportChecksum = try XCTUnwrap(ProvenanceRecorder.sha256(of: dbURL))
        let command = try ImportCommand.SampleMetadataSubcommand.parse([
            metadataURL.path,
            "--bundle",
            bundleURL.path,
            "--quiet",
        ])
        try await command.run()

        let database = try VariantDatabase(url: dbURL)
        let metadata = database.sampleMetadata(name: "test")
        XCTAssertEqual(metadata["lineage"], "B.1.1.7")
        XCTAssertEqual(metadata["status"], "confirmed")

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let provenance = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(provenance.workflowName, "lungfish import sample-metadata")
        XCTAssertTrue(provenance.argv.contains("sample-metadata"))
        XCTAssertTrue(provenance.argv.contains("--quiet"))
        XCTAssertEqual(provenance.options.explicit["inputFile"], .file(metadataURL))
        XCTAssertEqual(provenance.options.explicit["bundle"], .file(bundleURL))
        XCTAssertEqual(provenance.options.explicit["metadataFormat"], .string("csv"))
        XCTAssertEqual(provenance.options.resolvedDefaults["metadataFormat"], .string("csv"))
        XCTAssertEqual(provenance.options.resolvedDefaults["tracksUpdated"], .integer(1))
        XCTAssertEqual(provenance.options.resolvedDefaults["sampleRowsUpdated"], .integer(1))
        XCTAssertEqual(provenance.options.resolvedDefaults["variantDatabaseCount"], .integer(1))
        XCTAssertTrue(provenance.files.contains {
            $0.path == metadataURL.path && $0.role == .input && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertTrue(provenance.files.contains {
            $0.path == bundleURL.appendingPathComponent(BundleManifest.filename).path
                && $0.role == .input
                && $0.checksumSHA256 != nil
                && $0.fileSize != nil
        })

        let importStep = try XCTUnwrap(provenance.steps.first)
        let databaseInput = try XCTUnwrap(importStep.inputs.first {
            $0.path == dbURL.path && $0.role == .input
        })
        XCTAssertEqual(databaseInput.checksumSHA256, preImportChecksum)

        let databaseOutput = try XCTUnwrap(provenance.outputs.first {
            $0.path == dbURL.path && $0.role == .output
        })
        XCTAssertNotNil(databaseOutput.checksumSHA256)
        XCTAssertNotEqual(databaseOutput.checksumSHA256, preImportChecksum)

        let bundleSidecarURL = try XCTUnwrap(ProvenanceWriter.bundleOutputSidecarURL(for: dbURL, inBundle: bundleURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleSidecarURL.path))
        let focusedSidecar = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: bundleSidecarURL)
        )
        XCTAssertEqual(focusedSidecar.output?.path, dbURL.path)
    }

    func testSampleMetadataSubcommandRollsBackWhenProvenanceLayoutFails() async throws {
        let bundleURL = try makeVariantBundle()
        let dbURL = bundleURL.appendingPathComponent("variants.db")
        let preImportChecksum = try XCTUnwrap(ProvenanceRecorder.sha256(of: dbURL))
        let blockedProvenanceURL = bundleURL.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName)
        try "blocked".write(to: blockedProvenanceURL, atomically: true, encoding: .utf8)

        let metadataURL = tempDir.appendingPathComponent("rollback-metadata.csv")
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

        do {
            try await command.run()
            XCTFail("Expected provenance layout failure")
        } catch {
            // Expected: the regular provenance path blocks bundle layout creation.
        }

        XCTAssertEqual(ProvenanceRecorder.sha256(of: dbURL), preImportChecksum)
        let database = try VariantDatabase(url: dbURL)
        let metadata = database.sampleMetadata(name: "test")
        XCTAssertNil(metadata["lineage"])
        XCTAssertNil(metadata["status"])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename).path
            )
        )
        XCTAssertEqual(try String(contentsOf: blockedProvenanceURL, encoding: .utf8), "blocked")
    }

    func testMetadataSubcommandImportsIntoTwelveSBundleAndWritesProvenance() throws {
        let bundleURL = try makeTwelveSBundle()
        let metadataURL = tempDir.appendingPathComponent("twelve-s-metadata.csv")
        try """
        sample,site,cohort
        SampleA,Hilo,batch-1
        """.write(to: metadataURL, atomically: true, encoding: .utf8)

        let command = try MetadataSubcommand.parse([
            metadataURL.path,
            "--bundle",
            bundleURL.path,
            "--quiet",
        ])
        try command.run()

        let store = SampleMetadataStore.load(from: bundleURL, knownSampleIds: Set(["SampleA"]))
        XCTAssertEqual(store?.records["SampleA"]?["site"], "Hilo")
        XCTAssertEqual(store?.records["SampleA"]?["cohort"], "batch-1")

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let provenance = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(provenance.workflowName, "Sample metadata import")
        XCTAssertTrue(provenance.argv.contains("--quiet"))
        XCTAssertTrue(provenance.files.contains { $0.path == metadataURL.path && $0.role == .input })
        XCTAssertTrue(provenance.files.contains {
            $0.path == bundleURL.appendingPathComponent(TwelveSAmpliconResultBundleManifest.filename).path
                && $0.role == .input
        })
        XCTAssertTrue(provenance.outputs.contains {
            $0.path == bundleURL.appendingPathComponent("metadata/sample_metadata.tsv").path && $0.role == .output
        })
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
            XCTAssertEqual(exitCode, CLIExitCode.formatError.exitCode)
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

    private func makeTwelveSBundle() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("Run.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = TwelveSAmpliconResultBundleManifest(
            outputName: "Run",
            analysisName: "Run",
            referencePath: "reference.fa",
            targetTablePath: "targets.tsv",
            countMatrixPath: "sample-target-counts.tsv",
            sampleTablePath: "samples.tsv",
            readFatePath: "read-fate.json",
            provenancePath: ProvenanceWriter.provenanceFilename
        )
        try TwelveSAmpliconResultBundle.writeManifest(manifest, to: bundleURL)
        try """
        sample\tsample_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent
        SampleA\tSample A\t10\t8\t2\t0\t0\t80.0\t20.0
        """.write(to: bundleURL.appendingPathComponent("samples.tsv"), atomically: true, encoding: .utf8)
        return bundleURL
    }
}
