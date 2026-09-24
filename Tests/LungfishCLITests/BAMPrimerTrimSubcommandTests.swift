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

    // MARK: - WFL-08: scheme/BAM contig reconciliation

    /// The sarscov2 fixture BAM's `@SQ SN` is `MT192765.1`. A scheme whose
    /// *canonical* accession is a different name, but which declares
    /// `MT192765.1` as a known equivalent, must still trim successfully: the
    /// subcommand must read the BAM's actual `@SQ` name and resolve it
    /// against the scheme's canonical+equivalent accessions, instead of
    /// blindly defaulting `--target-reference` to the canonical accession
    /// (which would hand `ivar trim` a BED keyed on a name absent from the
    /// BAM, silently trimming zero primers).
    func testRunResolvesBAMContigAgainstEquivalentAccession() async throws {
        let fixture = try makeIntegrationFixture(
            schemeCanonicalAccession: "MN908947.3",
            schemeEquivalentAccessions: ["MT192765.1"]
        )

        let subcommand = try BAMCommand.PrimerTrimSubcommand.parse([
            "--bundle", fixture.bundleURL.path,
            "--alignment-track", fixture.sourceTrackID,
            "--scheme", fixture.schemeURL.path,
            "--name", "Primer-trimmed Equivalent Test"
        ])

        let result: BAMCommand.PrimerTrimAdoptionResult
        do {
            result = try await subcommand.executeForTesting { _ in }
        } catch let err as NativeToolError {
            switch err {
            case .toolNotFound, .toolsDirectoryNotFound:
                try ToolAvailability.skipOrFail("ivar/samtools not installed in ~/.lungfish; \(err)")
            default:
                throw err
            }
        }

        XCTAssertEqual(result.trackInfo.name, "Primer-trimmed Equivalent Test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bamURL.path))

        // The provenance sidecar records the resolved target reference the
        // rewritten BED actually used -- it must be the BAM's own name
        // (MT192765.1), not the scheme's canonical accession (MN908947.3),
        // proving the equivalent-accession BED rewrite fired.
        let provenanceData = try Data(contentsOf: result.provenanceSidecarURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BAMPrimerTrimProvenance.self, from: provenanceData)
        XCTAssertEqual(decoded.resolvedOptions["target_reference"], "MT192765.1")
    }

    /// When the BAM's `@SQ` name matches neither the scheme's canonical
    /// accession nor any declared equivalent, the command must fail loudly
    /// instead of silently defaulting to the canonical accession and
    /// producing an untrimmed BAM.
    func testRunFailsLoudlyWhenBAMContigMatchesNoKnownAccession() async throws {
        let fixture = try makeIntegrationFixture(
            schemeCanonicalAccession: "NC_045512.2",
            schemeEquivalentAccessions: []
        )

        let subcommand = try BAMCommand.PrimerTrimSubcommand.parse([
            "--bundle", fixture.bundleURL.path,
            "--alignment-track", fixture.sourceTrackID,
            "--scheme", fixture.schemeURL.path,
            "--name", "Should Not Be Created"
        ])

        do {
            _ = try await subcommand.executeForTesting { _ in }
            XCTFail("Expected a loud failure for an unrelated BAM/scheme contig pairing")
        } catch let err as NativeToolError {
            switch err {
            case .toolNotFound, .toolsDirectoryNotFound:
                try ToolAvailability.skipOrFail("ivar/samtools not installed in ~/.lungfish; \(err)")
            default:
                throw err
            }
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("NC_045512.2")
                    && error.localizedDescription.contains("MT192765.1"),
                "Expected the error to name both the scheme's accession and the BAM's actual @SQ name; got: \(error.localizedDescription)"
            )
        }

        // No new alignment track should have been adopted.
        let reloaded = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertFalse(reloaded.alignments.contains { $0.name == "Should Not Be Created" })
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

    /// Builds the same sarscov2-backed `.lungfishref` bundle as
    /// `makeIntegrationFixture()`, but with a freshly-written primer scheme
    /// whose canonical/equivalent accessions are set by the caller instead
    /// of reusing the fixed `mt192765-integration` scheme -- used by the
    /// WFL-08 contig-reconciliation tests, which need to exercise a
    /// canonical accession that does NOT literally match the BAM's own
    /// `@SQ SN:MT192765.1`.
    private func makeIntegrationFixture(
        schemeCanonicalAccession: String,
        schemeEquivalentAccessions: [String]
    ) throws -> IntegrationFixture {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LungfishCLITests/
            .deletingLastPathComponent()  // Tests/
        let sourceBAM = testsDir
            .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")
        let sourceBAI = sourceBAM.appendingPathExtension("bai")
        guard FileManager.default.fileExists(atPath: sourceBAM.path) else {
            throw XCTSkip("sarscov2 fixture BAM missing at \(sourceBAM.path)")
        }

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

        // Write a scheme keyed on the caller-chosen canonical accession, with
        // the caller-chosen equivalents. The BED's chromosome column is the
        // CANONICAL name -- exactly like a real scheme authored against its
        // canonical reference -- so `PrimerSchemeResolver`'s equivalent-accession
        // rewrite path is genuinely exercised when an equivalent is requested.
        let schemeURL = tempDir.appendingPathComponent(
            "scheme-\(UUID().uuidString).lungfishprimers", isDirectory: true
        )
        try FileManager.default.createDirectory(at: schemeURL, withIntermediateDirectories: true)

        var referenceAccessionsJSON = "{ \"accession\": \"\(schemeCanonicalAccession)\", \"canonical\": true }"
        for equivalent in schemeEquivalentAccessions {
            referenceAccessionsJSON += ", { \"accession\": \"\(equivalent)\", \"equivalent\": true }"
        }
        let manifestJSON = """
        {
          "schema_version": 1,
          "name": "wfl08-test-scheme",
          "display_name": "WFL-08 Test Scheme",
          "description": "Synthetic scheme for BAM/scheme contig-reconciliation tests.",
          "reference_accessions": [ \(referenceAccessionsJSON) ],
          "primer_count": 2,
          "amplicon_count": 1,
          "source": "test-fixture",
          "version": "0.1.0",
          "created": "2026-04-24T00:00:00Z"
        }
        """
        try Data(manifestJSON.utf8).write(to: schemeURL.appendingPathComponent("manifest.json"))

        let bed = """
        \(schemeCanonicalAccession)\t100\t124\tint_test_1_LEFT\t60\t+
        \(schemeCanonicalAccession)\t500\t524\tint_test_1_RIGHT\t60\t-
        """
        try Data(bed.utf8).write(to: schemeURL.appendingPathComponent("primers.bed"))
        try Data("Synthetic test fixture; no attribution required.\n".utf8)
            .write(to: schemeURL.appendingPathComponent("PROVENANCE.md"))

        return IntegrationFixture(
            bundleURL: bundleURL,
            sourceTrackID: trackID,
            schemeURL: schemeURL
        )
    }
}
