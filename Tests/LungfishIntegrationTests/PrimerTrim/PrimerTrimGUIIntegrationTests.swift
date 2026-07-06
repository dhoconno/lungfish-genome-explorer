// PrimerTrimGUIIntegrationTests.swift - End-to-end GUI runner against fixture bundle
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp
@testable import LungfishWorkflow

/// Runs `CLIPrimerTrimRunner` against a real `lungfish-cli bam primer-trim`
/// invocation, using the sarscov2 fixture BAM and the mt192765-integration
/// scheme. Asserts the runner emits the expected event sequence and that the
/// bundle ends up with the new alignment track + sidecar after the operation
/// completes. Skips when ivar/samtools are missing or the CLI binary is not
/// findable through SwiftPM's active binary path.
final class PrimerTrimGUIIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var originalCLIPath: String?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimerTrimGUIIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        originalCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        if let originalCLIPath {
            setenv("LUNGFISH_CLI_PATH", originalCLIPath, 1)
        } else {
            unsetenv("LUNGFISH_CLI_PATH")
        }
    }

    func testRunnerSpawnsCLIAndAdoptsTrack() async throws {
        // Locate the locally-built lungfish-cli binary by walking up from
        // #filePath to the repo root, then asking SwiftPM for its bin path.
        let cliBinary = try locateCLIBinary()
        setenv("LUNGFISH_CLI_PATH", cliBinary.path, 1)

        guard CLIPrimerTrimRunner.cliBinaryPath() != nil else {
            throw XCTSkip("lungfish-cli binary not findable even after setting LUNGFISH_CLI_PATH")
        }

        let fixture = try makeFixture()

        let arguments = CLIPrimerTrimRunner.buildCLIArguments(
            bundleURL: fixture.bundleURL,
            alignmentTrackID: fixture.sourceTrackID,
            schemeURL: fixture.schemeURL,
            outputTrackName: "Primer-trimmed Integration"
        )

        final class Capturer: @unchecked Sendable {
            var events: [CLIPrimerTrimEvent] = []
        }
        let capturer = Capturer()

        let runner = CLIPrimerTrimRunner()
        do {
            try await runner.run(arguments: arguments) { event in
                capturer.events.append(event)
            }
        } catch CLIPrimerTrimRunnerError.processExited(_, let stderr) {
            if stderr.contains("ivar") || stderr.contains("samtools") {
                throw XCTSkip("ivar/samtools not available: \(stderr)")
            }
            throw CLIPrimerTrimRunnerError.processExited(status: 1, stderr: stderr)
        }

        // Expected event sequence: at least runStart and runComplete.
        XCTAssertTrue(
            capturer.events.contains { if case .runStart = $0 { return true } else { return false } },
            "Expected runStart event in: \(capturer.events)"
        )
        XCTAssertTrue(
            capturer.events.contains { if case .runComplete = $0 { return true } else { return false } },
            "Expected runComplete event in: \(capturer.events)"
        )

        // Manifest reload reflects the new track.
        let reloadedManifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertTrue(
            reloadedManifest.alignments.contains { $0.name == "Primer-trimmed Integration" },
            "Expected manifest to contain the new alignment track. Got names: \(reloadedManifest.alignments.map(\.name))"
        )

        // Sidecar lives at the adopted-BAM's sibling path.
        guard let newTrack = reloadedManifest.alignments.first(where: { $0.name == "Primer-trimmed Integration" }) else {
            XCTFail("New alignment track not found in manifest")
            return
        }
        let newBAMURL = fixture.bundleURL.appendingPathComponent(newTrack.sourcePath)
        let sidecarURL = PrimerTrimProvenanceLoader.sidecarURL(forBAMAt: newBAMURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecarURL.path),
            "Expected provenance sidecar at \(sidecarURL.path)"
        )

        // Sidecar parses cleanly (loader returns optional, not throws).
        let provenance = try XCTUnwrap(PrimerTrimProvenanceLoader.load(forBAMAt: newBAMURL))
        XCTAssertEqual(provenance.primerScheme.bundleName, "mt192765-integration")
    }

    // MARK: - Fixture / binary discovery

    private struct Fixture {
        let bundleURL: URL
        let sourceTrackID: String
        let schemeURL: URL
    }

    /// Walks up from `#filePath` to find `Tests/`, then locates the locally-built
    /// `lungfish-cli` in SwiftPM's active binary directory.
    private func locateCLIBinary() throws -> URL {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PrimerTrim/
            .deletingLastPathComponent()  // LungfishIntegrationTests/
            .deletingLastPathComponent()  // Tests/
        let repoRoot = testsDir.deletingLastPathComponent()
        let binPath = try swiftPMBinPath(packageRoot: repoRoot)
        let cliBinary = binPath.appendingPathComponent("lungfish-cli")
        guard FileManager.default.isExecutableFile(atPath: cliBinary.path) else {
            throw XCTSkip("lungfish-cli binary not found at \(cliBinary.path) — run `swift build --product lungfish-cli` first")
        }
        return cliBinary
    }

    private func swiftPMBinPath(packageRoot: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            "build",
            "--package-path", packageRoot.path,
            "--show-bin-path",
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw XCTSkip("Could not resolve SwiftPM binary path: \(stderrText)")
        }
        guard let path = stdoutText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            throw XCTSkip("SwiftPM did not print a binary path: \(stderrText)")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func makeFixture() throws -> Fixture {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PrimerTrim/
            .deletingLastPathComponent()  // LungfishIntegrationTests/
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

        let bundleURL = tempDir.appendingPathComponent("Integration.lungfishref", isDirectory: true)
        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)
        let bundleBAMURL = alignmentsDir.appendingPathComponent("source.sorted.bam")
        try FileManager.default.copyItem(at: sourceBAM, to: bundleBAMURL)
        try FileManager.default.copyItem(at: sourceBAI, to: bundleBAMURL.appendingPathExtension("bai"))

        let manifest = BundleManifest(
            name: "Integration",
            identifier: "bundle.integration.\(UUID().uuidString)",
            source: SourceInfo(organism: "Virus", assembly: "MT192765.1", database: "test"),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-source",
                    name: "Source Alignment",
                    format: .bam,
                    sourcePath: "alignments/source.sorted.bam",
                    indexPath: "alignments/source.sorted.bam.bai"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return Fixture(bundleURL: bundleURL, sourceTrackID: "aln-source", schemeURL: scheme)
    }
}
