import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishCLI

final class BAMPrimerTrimSubcommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMPrimerTrimSubcommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Runs the subcommand against a fixture bundle wrapping the sarscov2 BAM
    /// (`MT192765.1`) using the `mt192765-integration` primer scheme. Skips
    /// when ivar/samtools are not findable by NativeToolRunner.
    func testRunAdoptsTrimmedBAMAsNewAlignmentTrack() async throws {
        let fixture = try makeIntegrationFixture()

        let subcommand = try BAMCommand.PrimerTrimSubcommand.parse([
            "--bundle", fixture.bundleURL.path,
            "--alignment-track", fixture.sourceTrackID,
            "--scheme", fixture.schemeURL.path,
            "--name", "Primer-trimmed Test"
        ])

        var emittedLines: [String] = []
        let result: BAMCommand.PrimerTrimAdoptionResult
        do {
            result = try await subcommand.executeForTesting { line in
                emittedLines.append(line)
            }
        } catch let err as NativeToolError {
            switch err {
            case .toolNotFound, .toolsDirectoryNotFound:
                try ToolAvailability.skipOrFail("ivar/samtools not installed in ~/.lungfish; \(err)")
            default:
                throw err
            }
        }

        XCTAssertEqual(result.trackInfo.name, "Primer-trimmed Test")
        XCTAssertTrue(result.trackInfo.sourcePath.hasPrefix("alignments/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bamURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.indexURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceSidecarURL.path))

        // Manifest reload reflects the new track.
        let reloaded = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertTrue(reloaded.alignments.contains { $0.id == result.trackInfo.id })
    }

    func testRunRejectsNonexistentBundle() async throws {
        let subcommand = try BAMCommand.PrimerTrimSubcommand.parse([
            "--bundle", tempDir.appendingPathComponent("does-not-exist").path,
            "--alignment-track", "aln-x",
            "--scheme", tempDir.appendingPathComponent("scheme").path,
            "--name", "Whatever"
        ])
        do {
            _ = try await subcommand.executeForTesting { _ in }
            XCTFail("Expected failure")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains("manifest")
                    || error.localizedDescription.localizedCaseInsensitiveContains("bundle")
                    || error.localizedDescription.localizedCaseInsensitiveContains("does-not-exist"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    func testRunRejectsUnknownAlignmentTrack() async throws {
        let fixture = try makeIntegrationFixture()
        let subcommand = try BAMCommand.PrimerTrimSubcommand.parse([
            "--bundle", fixture.bundleURL.path,
            "--alignment-track", "aln-not-in-manifest",
            "--scheme", fixture.schemeURL.path,
            "--name", "Whatever"
        ])
        do {
            _ = try await subcommand.executeForTesting { _ in }
            XCTFail("Expected failure")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("aln-not-in-manifest"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    func testRunRejectsNameCollisionWithExistingTrack() async throws {
        let fixture = try makeIntegrationFixture()
        // Reuse the source track's name to force a collision before any work happens.
        let subcommand = try BAMCommand.PrimerTrimSubcommand.parse([
            "--bundle", fixture.bundleURL.path,
            "--alignment-track", fixture.sourceTrackID,
            "--scheme", fixture.schemeURL.path,
            "--name", "Source Alignment"  // Same as the fixture's source track name.
        ])
        do {
            _ = try await subcommand.executeForTesting { _ in }
            XCTFail("Expected failure")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains("already exists"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Fixture builder

    private struct IntegrationFixture {
        let bundleURL: URL
        let sourceTrackID: String
        let schemeURL: URL
    }

    private func makeIntegrationFixture() throws -> IntegrationFixture {
        // Walk up from #filePath to find Tests/Fixtures/sarscov2/test.paired_end.sorted.bam
        // and Tests/LungfishWorkflowTests/Resources/primerschemes/mt192765-integration.lungfishprimers
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LungfishCLITests/
            .deletingLastPathComponent()  // Tests/
        let sourceBAM = testsDir
            .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")
        let sourceBAI = sourceBAM.appendingPathExtension("bai")
        let scheme = testsDir
            .appendingPathComponent("LungfishWorkflowTests/Resources/primerschemes/mt192765-integration.lungfishprimers")
        guard FileManager.default.fileExists(atPath: sourceBAM.path) else {
            throw XCTSkip("sarscov2 fixture BAM missing at \(sourceBAM.path)")
        }
        guard FileManager.default.fileExists(atPath: scheme.path) else {
            throw XCTSkip("mt192765-integration scheme missing at \(scheme.path)")
        }

        // Construct a minimal .lungfishref bundle that points at the BAM.
        let bundleURL = tempDir.appendingPathComponent("Integration.lungfishref", isDirectory: true)
        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)
        let bundleBAMURL = alignmentsDir.appendingPathComponent("source.sorted.bam")
        let bundleBAIURL = bundleBAMURL.appendingPathExtension("bai")
        try FileManager.default.copyItem(at: sourceBAM, to: bundleBAMURL)
        try FileManager.default.copyItem(at: sourceBAI, to: bundleBAIURL)

        let trackID = "aln-source"
        let manifest = BundleManifest(
            name: "Integration",
            identifier: "bundle.integration.\(UUID().uuidString)",
            source: SourceInfo(organism: "Virus", assembly: "MT192765.1", database: "test"),
            alignments: [
                AlignmentTrackInfo(
                    id: trackID,
                    name: "Source Alignment",
                    format: .bam,
                    sourcePath: "alignments/source.sorted.bam",
                    indexPath: "alignments/source.sorted.bam.bai"
                )
            ]
        )
        try manifest.save(to: bundleURL)

        return IntegrationFixture(
            bundleURL: bundleURL,
            sourceTrackID: trackID,
            schemeURL: scheme
        )
    }
}
