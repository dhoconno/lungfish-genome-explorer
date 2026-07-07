import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO

final class CLIBAMFilteringIntegrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBAMFilteringIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testBundleFilteringCreatesFilteredSiblingTrackWithProvenance() async throws {
        let managedHome = try ManagedSamtoolsHome.makeReal(rootURL: tempDir)
        let fixture = try BundleAlignmentFixture.make(
            rootURL: tempDir,
            samtoolsPath: managedHome.samtoolsPath,
            includeMappingResult: false
        )

        let result = try runCLI(
            [
                "bam", "filter",
                "--bundle", fixture.bundleURL.path,
                "--alignment-track", fixture.sourceTrackID,
                "--output-track-name", "Mapped Reads",
                "--mapped-only",
                "-q",
            ],
            homeDirectory: managedHome.homeURL
        )
        XCTAssertEqual(result.exitCode, 0, "CLI BAM filter failed: \(result.stderr)")

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertEqual(manifest.alignments.count, 2)
        XCTAssertTrue(manifest.alignments.contains(where: { $0.id == fixture.sourceTrackID }))
        let derivedTrack = try XCTUnwrap(manifest.alignments.first(where: { $0.id != fixture.sourceTrackID }))
        XCTAssertEqual(derivedTrack.name, "Mapped Reads")
        XCTAssertTrue(derivedTrack.sourcePath.hasPrefix("alignments/filtered/"))

        let metadataURL = fixture.bundleURL.appendingPathComponent(try XCTUnwrap(derivedTrack.metadataDBPath))
        let metadataDB = try AlignmentMetadataDatabase.openForUpdate(at: metadataURL)
        XCTAssertEqual(metadataDB.getFileInfo("derivation_kind"), "filtered_alignment")
        XCTAssertEqual(metadataDB.getFileInfo("derivation_source_track_id"), fixture.sourceTrackID)
        XCTAssertEqual(metadataDB.getFileInfo("derivation_target_kind"), "bundle")
        XCTAssertEqual(metadataDB.provenanceHistory().map(\.subcommand), ["view", "sort", "index"])
        XCTAssertTrue(metadataDB.getFileInfo("derivation_command_chain")?.contains("samtools view") == true)
        XCTAssertEqual(
            try bamReadNames(
                at: fixture.bundleURL.appendingPathComponent(derivedTrack.sourcePath),
                samtoolsPath: managedHome.samtoolsPath
            ),
            ["mapped-primary-highmapq", "mapped-primary-lowmapq", "mapped-secondary"]
        )
    }

    func testMappingResultFilteringWritesIntoViewerBundleOnly() async throws {
        let managedHome = try ManagedSamtoolsHome.makeReal(rootURL: tempDir)
        let fixture = try BundleAlignmentFixture.make(
            rootURL: tempDir,
            samtoolsPath: managedHome.samtoolsPath,
            includeMappingResult: true
        )
        let mappingResultURL = try XCTUnwrap(fixture.mappingResultURL)

        let result = try runCLI(
            [
                "bam", "filter",
                "--mapping-result", mappingResultURL.path,
                "--alignment-track", fixture.sourceTrackID,
                "--output-track-name", "Primary Reads",
                "--primary-only",
                "-q",
            ],
            homeDirectory: managedHome.homeURL
        )
        XCTAssertEqual(result.exitCode, 0, "CLI BAM filter failed: \(result.stderr)")

        let mappingResultContents = try FileManager.default.contentsOfDirectory(
            atPath: mappingResultURL.path
        ).sorted()
        XCTAssertEqual(mappingResultContents, ["mapping-result.json"])

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertEqual(manifest.alignments.count, 2)
        let derivedTrack = try XCTUnwrap(manifest.alignments.first(where: { $0.id != fixture.sourceTrackID }))
        XCTAssertEqual(derivedTrack.name, "Primary Reads")

        let metadataURL = fixture.bundleURL.appendingPathComponent(try XCTUnwrap(derivedTrack.metadataDBPath))
        let metadataDB = try AlignmentMetadataDatabase.openForUpdate(at: metadataURL)
        XCTAssertEqual(metadataDB.getFileInfo("derivation_target_kind"), "mapping_result")
        XCTAssertEqual(metadataDB.getFileInfo("derivation_mapping_result_path"), mappingResultURL.path)
        XCTAssertEqual(metadataDB.provenanceHistory().map(\.subcommand), ["view", "sort", "index"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.bundleURL.appendingPathComponent(derivedTrack.sourcePath).path
            )
        )
        XCTAssertEqual(
            try bamReadNames(
                at: fixture.bundleURL.appendingPathComponent(derivedTrack.sourcePath),
                samtoolsPath: managedHome.samtoolsPath
            ),
            ["mapped-primary-highmapq", "mapped-primary-lowmapq", "unmapped-read"]
        )
    }

    func testRootLevelJSONFormatAppliesToBamFilterExecutable() async throws {
        let managedHome = try ManagedSamtoolsHome.makeReal(rootURL: tempDir)
        let fixture = try BundleAlignmentFixture.make(
            rootURL: tempDir,
            samtoolsPath: managedHome.samtoolsPath,
            includeMappingResult: false
        )

        let result = try runCLI(
            [
                "--format", "json",
                "bam", "filter",
                "--bundle", fixture.bundleURL.path,
                "--alignment-track", fixture.sourceTrackID,
                "--output-track-name", "JSON Root Format",
                "--mapped-only",
            ],
            homeDirectory: managedHome.homeURL
        )

        XCTAssertEqual(result.exitCode, 0, "CLI BAM filter failed: \(result.stderr)")
        XCTAssertTrue(result.stderr.isEmpty)

        let outputLines = result.stdout
            .split(separator: "\n")
            .map(String.init)
        XCTAssertGreaterThanOrEqual(outputLines.count, 2)

        let events = try outputLines.map {
            try XCTUnwrap(
                try? JSONDecoder().decode(BAMCommand.FilterEvent.self, from: Data($0.utf8))
            )
        }
        XCTAssertEqual(events.first?.event, "runStart")
        XCTAssertEqual(events.last?.event, "runComplete")
    }

    func testRootLevelTSVFormatIsRejectedForBamFilterExecutable() async throws {
        let managedHome = try ManagedSamtoolsHome.makeReal(rootURL: tempDir)
        let fixture = try BundleAlignmentFixture.make(
            rootURL: tempDir,
            samtoolsPath: managedHome.samtoolsPath,
            includeMappingResult: false
        )

        let result = try runCLI(
            [
                "--format", "tsv",
                "bam", "filter",
                "--bundle", fixture.bundleURL.path,
                "--alignment-track", fixture.sourceTrackID,
                "--output-track-name", "Should Not Exist",
                "--mapped-only",
            ],
            homeDirectory: managedHome.homeURL
        )

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("The value 'tsv' is invalid"))

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        XCTAssertEqual(manifest.alignments.count, 1)
    }
}

private struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private func runCLI(_ arguments: [String], homeDirectory: URL) throws -> CLIResult {
    let process = Process()
    process.executableURL = try cliBinaryURL()
    process.arguments = arguments

    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = homeDirectory.path
    process.environment = environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    return CLIResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

private func cliBinaryURL() throws -> URL {
    guard let binary = CLITestBinaryResolver.cliBinaryURL(
        repoRoot: CLITestBinaryResolver.repositoryRoot(containing: #filePath)
    ) else {
        throw XCTSkip("CLI binary not built at expected path — run `swift build --product lungfish-cli` first")
    }
    return binary
}

private func bamReadNames(at bamURL: URL, samtoolsPath: URL) throws -> [String] {
    let process = Process()
    process.executableURL = samtoolsPath
    process.arguments = ["view", bamURL.path]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let stderrText = String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, "samtools view failed: \(stderrText)")

    let output = String(
        data: stdout.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    return output
        .split(separator: "\n")
        .compactMap { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).first.map(String.init)
        }
}
