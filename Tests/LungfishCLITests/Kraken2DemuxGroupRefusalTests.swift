// Kraken2DemuxGroupRefusalTests.swift - kraken2 classify and esviritu detect on a demultiplexed group bundle, through the built CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// A demultiplexed group bundle is a container with no reads of its own, so a classifier launch on
/// it is refused. `esviritu detect` refuses it in its plan with exit 3 before any folder exists
/// (2.8 A9), and Phase 2.10 lane U41 moves `kraken2 classify` to the same ending (2.7 row 421).
///
/// Every test runs the built `lungfish-cli` on the L6e fixture of ``ReadSetFixtures`` with the
/// managed storage root pointed at a folder of the test, where `FixtureDB` is a registered ready
/// database, so no test reads or writes the real storage and the refusal comes from the command's
/// own order of checks.
final class Kraken2DemuxGroupRefusalTests: XCTestCase {
    private static let sentenceStem = "Demultiplexed group bundles are container-only; "
        + "select an individual demultiplexed FASTQ bundle for "
    private static let kraken2Sentence = sentenceStem + "classification."
    private static let esVirituSentence = sentenceStem + "EsViritu detection."

    private var root: URL!
    private var fixtures: ReadSetFixtures!
    private var storage: URL!

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "kraken2-demux-group-refusal")
        fixtures = try ReadSetFixtures(in: root)
        storage = root.appendingPathComponent("storage", isDirectory: true)
        let location = ManagedStorageLocation(rootURL: storage)
        try FileManager.default.createDirectory(at: location.databaseRootURL, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("FixtureDB", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        for name in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try Data("fixture".utf8).write(to: database.appendingPathComponent(name))
        }
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: location.databaseRootURL)
        try await registry.registerExisting(at: database, name: "FixtureDB")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The reference, esviritu detect

    func testEsVirituRefusesTheGroupWithExit3BeforeAnyFolderInAProject() throws {
        let before = try snapshot(of: fixtures.projectURL)
        let result = try runCLI([
            "esviritu", "detect", "--input", fixtures.demuxGroup.path, "--sample", "group",
            "--project", fixtures.projectURL.path,
        ])
        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue, result.output)
        XCTAssertTrue(result.output.contains(Self.esVirituSentence), result.output)
        XCTAssertEqual(try snapshot(of: fixtures.projectURL), before, "the refusal leaves the project as it was")
    }

    func testEsVirituRefusesTheGroupAndLeavesAnEarlierResultAlone() throws {
        let earlier = try makeEarlierResult(named: "esviritu-earlier")
        let before = try snapshot(of: fixtures.projectURL)
        let result = try runCLI([
            "esviritu", "detect", "--input", fixtures.demuxGroup.path, "--sample", "group",
            "--output", earlier.path,
        ])
        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue, result.output)
        XCTAssertTrue(result.output.contains(Self.esVirituSentence), result.output)
        XCTAssertEqual(try snapshot(of: fixtures.projectURL), before, "the earlier result keeps every byte")
    }

    // MARK: - kraken2 classify at the base

    func testKraken2TodayRefusesTheGroupWithExit64WithNoFolderInAProject() throws {
        let before = try snapshot(of: fixtures.projectURL)
        let result = try runCLI([
            "kraken2", "classify", fixtures.demuxGroup.path, "--db", "FixtureDB",
            "--project", fixtures.projectURL.path,
        ])
        XCTAssertEqual(result.exitCode, CLIExitCode.workflowError.rawValue, result.output)
        XCTAssertTrue(result.output.contains(Self.kraken2Sentence), result.output)
        XCTAssertEqual(try snapshot(of: fixtures.projectURL), before, "no folder exists after the refusal")
    }

    func testKraken2TodayRefusesTheGroupWithExit64AndLeavesAnEarlierResultAlone() throws {
        let earlier = try makeEarlierResult(named: "kraken2-earlier")
        let before = try snapshot(of: fixtures.projectURL)
        let result = try runCLI([
            "kraken2", "classify", fixtures.demuxGroup.path, "--db", "FixtureDB",
            "--output-dir", earlier.path,
        ])
        XCTAssertEqual(result.exitCode, CLIExitCode.workflowError.rawValue, result.output)
        XCTAssertTrue(result.output.contains(Self.kraken2Sentence), result.output)
        XCTAssertEqual(try snapshot(of: fixtures.projectURL), before, "the earlier result keeps every byte")
    }

    func testKraken2TodayChecksTheDatabaseBeforeTheGroup() throws {
        let result = try runCLI([
            "kraken2", "classify", fixtures.demuxGroup.path, "--db", "NoSuchDatabase",
            "--project", fixtures.projectURL.path,
        ])
        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue, result.output)
        XCTAssertTrue(result.output.contains("Database 'NoSuchDatabase' not found in registry."), result.output)
        XCTAssertFalse(result.output.contains(Self.kraken2Sentence), result.output)
    }

    // MARK: - Helpers

    private struct Outcome {
        let exitCode: Int32
        /// Standard output, then standard error.
        let output: String
    }

    /// Runs the built `lungfish-cli` with the storage root of this test and waits up to a minute.
    private func runCLI(_ arguments: [String]) throws -> Outcome {
        let binary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(
                buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            ),
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = CLISIGTERMHarness.childEnvironment(overriding: [
            "LUNGFISH_STORAGE_ROOT": storage.path,
            "LUNGFISH_CONDA_ROOT": storage.appendingPathComponent("conda", isDirectory: true).path,
        ])
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Outcome(exitCode: process.terminationStatus, output: out + err)
    }

    /// A finished run's folder in the project's `Analyses`, with the files a result holds, so a
    /// run that claims or rewrites the folder changes its file set or its bytes.
    private func makeEarlierResult(named name: String) throws -> URL {
        let folder = fixtures.projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"status":"completed","note":"the earlier run"}"#.utf8)
            .write(to: folder.appendingPathComponent(".lungfish-provenance.json"))
        try Data(#"{"tool":"kraken2","isBatch":false}"#.utf8)
            .write(to: folder.appendingPathComponent("analysis-metadata.json"))
        try Data("100.00\t10\t0\tR\t1\troot\n".utf8)
            .write(to: folder.appendingPathComponent("classification.kreport"))
        return folder
    }

    /// Every file and folder below `folder` by its path inside it, a file with the SHA-256 of its
    /// bytes and a folder with a marker, so equal snapshots mean no entry was made, removed or changed.
    private func snapshot(of folder: URL) throws -> [String: String] {
        var entries: [String: String] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let url as URL in walker {
            let relative = String(url.path.dropFirst(folder.path.count))
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                entries[relative] = "directory"
            } else {
                entries[relative] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return entries
    }
}
