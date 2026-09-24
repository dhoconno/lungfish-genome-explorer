import XCTest
import ArgumentParser
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// FEA-12: `lungfish-cli import vcf <vcf> --output-dir <bundle.lungfishref>`
/// attaches the variants to the bundle's variant database through
/// `VCFBundleVariantImport`, the core the GUI Import Center helper path uses.
final class ImportVCFBundleAttachTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportVCFBundleAttachTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testAttachAddsVariantTrackDatabaseAndProvenanceToBundle() async throws {
        let vcfURL = try fixtureVCF()
        let bundleURL = try makeReferenceBundle()

        let command = try ImportCommand.VCFSubcommand.parse([
            vcfURL.path,
            "--output-dir", bundleURL.path,
            "--name", "Sample calls",
            "--import-profile", "fast",
            "--quiet",
        ])
        try await command.run()

        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.variants.count, 1)
        let track = try XCTUnwrap(manifest.variants.first)
        XCTAssertEqual(track.id, "test")
        XCTAssertEqual(track.name, "Sample calls")
        XCTAssertEqual(track.databasePath, "variants/test.db")
        XCTAssertEqual(track.variantCount, 9)
        XCTAssertEqual(track.source, "VCF Import")

        let dbURL = bundleURL.appendingPathComponent("variants/test.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        let database = try VariantDatabase(url: dbURL)
        XCTAssertEqual(database.totalCount(), 9)
        XCTAssertEqual(database.allChromosomes(), ["MT192765.1"])
        XCTAssertEqual(VariantDatabase.importState(at: dbURL), "complete")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "import_profile"), "fast")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "source_vcf_name"), "test.vcf")
        XCTAssertEqual(
            VariantDatabase.metadataValue(at: dbURL, key: "workflow_provenance_path"),
            "variants/test.lungfish-provenance.json"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("variants/test.lungfish-provenance.json").path))

        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: bundleURL.appendingPathComponent("variants").path
        ).filter { $0.hasPrefix(".import-") }
        XCTAssertEqual(leftovers, [], "private staging must be removed after a committed import")
    }

    /// The CLI database must match what the shared core builds for the GUI
    /// helper (`VCFBundleVariantImport.createDatabase` plus the phase-2
    /// index build), and the manifest track must be the core's track.
    func testAttachMatchesSharedHelperCoreOutput() async throws {
        let vcfURL = try fixtureVCF()
        let bundleURL = try makeReferenceBundle()

        let command = try ImportCommand.VCFSubcommand.parse([
            vcfURL.path, "--output-dir", bundleURL.path, "--quiet",
        ])
        try await command.run()

        let helperDBURL = tempDir.appendingPathComponent("helper.db")
        var helperCount = try VCFBundleVariantImport.createDatabase(
            vcfURL: vcfURL,
            outputDBURL: helperDBURL,
            sourceFile: vcfURL.lastPathComponent,
            importProfile: .auto
        )
        if VariantDatabase.importState(at: helperDBURL) == "indexing" {
            helperCount = try VariantDatabase.resumeImport(existingDBURL: helperDBURL)
        }

        let cliDB = try VariantDatabase(url: bundleURL.appendingPathComponent("variants/test.db"))
        let helperDB = try VariantDatabase(url: helperDBURL)
        XCTAssertEqual(cliDB.totalCount(), helperCount)
        XCTAssertEqual(cliDB.allChromosomes(), helperDB.allChromosomes())
        XCTAssertEqual(
            cliDB.query(chromosome: "MT192765.1", start: 0, end: 30_000).map(\.position),
            helperDB.query(chromosome: "MT192765.1", start: 0, end: 30_000).map(\.position)
        )

        let track = try XCTUnwrap(try BundleManifest.load(from: bundleURL).variants.first)
        XCTAssertEqual(
            track,
            VCFBundleVariantImport.makeTrackInfo(trackID: "test", vcfURL: vcfURL, variantCount: helperCount)
        )
    }

    func testReattachReplacesTrackInsteadOfDuplicating() async throws {
        let vcfURL = try fixtureVCF()
        let bundleURL = try makeReferenceBundle()
        for _ in 0..<2 {
            let command = try ImportCommand.VCFSubcommand.parse([
                vcfURL.path, "--output-dir", bundleURL.path, "--quiet",
            ])
            try await command.run()
        }
        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.variants.map(\.id), ["test"])
        XCTAssertEqual(try VariantDatabase(url: bundleURL.appendingPathComponent("variants/test.db")).totalCount(), 9)
    }

    func testMissingBundleIsAnInputError() async throws {
        let vcfURL = try fixtureVCF()
        let missing = tempDir.appendingPathComponent("Missing.lungfishref", isDirectory: true)
        let command = try ImportCommand.VCFSubcommand.parse([vcfURL.path, "--output-dir", missing.path, "--quiet"])
        do {
            try await command.run()
            XCTFail("Expected a missing bundle to fail")
        } catch let exitCode as ExitCode {
            XCTAssertEqual(exitCode, CLIExitCode.inputError.exitCode)
        }
    }

    func testBundleOnlyOptionsAreRejectedForPlainDirectory() async throws {
        let vcfURL = try fixtureVCF()
        let outputURL = tempDir.appendingPathComponent("plain", isDirectory: true)
        let command = try ImportCommand.VCFSubcommand.parse([
            vcfURL.path, "--output-dir", outputURL.path, "--import-profile", "fast", "--quiet",
        ])
        do {
            try await command.run()
            XCTFail("Expected --import-profile without a bundle to fail")
        } catch let exitCode as ExitCode {
            XCTAssertEqual(exitCode, CLIExitCode.inputError.exitCode)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.appendingPathComponent("test.vcf").path))
    }

    func testImportProfileAcceptsEveryRawValueAndRejectsOthers() throws {
        for profile in VCFImportProfile.allCases {
            let command = try ImportCommand.VCFSubcommand.parse(["x.vcf", "--import-profile", profile.rawValue])
            XCTAssertEqual(command.importProfile, profile)
        }
        XCTAssertThrowsError(try ImportCommand.VCFSubcommand.parse(["x.vcf", "--import-profile", "turbo"]))
    }

    // MARK: - Fixtures

    private func fixtureVCF() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2/test.vcf")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("sarscov2 fixture VCF missing at \(source.path)")
        }
        let copy = tempDir.appendingPathComponent("test.vcf")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    /// A manifest-only reference bundle whose single chromosome matches the
    /// sarscov2 fixture. Attaching variants reads only the manifest.
    private func makeReferenceBundle() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("Ref Bundle.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifest = BundleManifest(
            name: "SARS-CoV-2",
            identifier: "org.lungfish.tests.vcf-attach",
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
        return bundleURL
    }
}
