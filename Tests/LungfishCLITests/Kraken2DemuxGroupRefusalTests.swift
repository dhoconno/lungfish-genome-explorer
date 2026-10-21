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
    private static let kraken2Sentence = GroupRefusalCLI.kraken2Sentence
    private static let esVirituSentence = GroupRefusalCLI.esVirituSentence

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
        try await registry.seedRowThroughManifest(at: database, name: "FixtureDB")
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

    // MARK: - kraken2 classify

    func testKraken2RefusesTheGroupWithExit3BeforeAnyFolderInAProject() throws {
        let before = try snapshot(of: fixtures.projectURL)
        let result = try runCLI([
            "kraken2", "classify", fixtures.demuxGroup.path, "--db", "FixtureDB",
            "--project", fixtures.projectURL.path,
        ])
        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue, result.output)
        XCTAssertTrue(result.output.contains(Self.kraken2Sentence), result.output)
        XCTAssertEqual(try snapshot(of: fixtures.projectURL), before, "no folder exists after the refusal")
    }

    func testKraken2RefusesTheGroupAndLeavesAnEarlierResultAlone() throws {
        let earlier = try makeEarlierResult(named: "kraken2-earlier")
        let before = try snapshot(of: fixtures.projectURL)
        let result = try runCLI([
            "kraken2", "classify", fixtures.demuxGroup.path, "--db", "FixtureDB",
            "--output-dir", earlier.path,
        ])
        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue, result.output)
        XCTAssertTrue(result.output.contains(Self.kraken2Sentence), result.output)
        XCTAssertEqual(try snapshot(of: fixtures.projectURL), before, "the earlier result keeps every byte")
    }

    func testKraken2RefusesTheGroupBeforeItChecksTheDatabase() throws {
        let before = try snapshot(of: fixtures.projectURL)
        let result = try runCLI([
            "kraken2", "classify", fixtures.demuxGroup.path, "--db", "NoSuchDatabase",
            "--project", fixtures.projectURL.path,
        ])
        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue, result.output)
        XCTAssertTrue(result.output.contains(Self.kraken2Sentence), result.output)
        XCTAssertFalse(result.output.contains("not found in registry"), "the database is not asked about first")
        XCTAssertEqual(try snapshot(of: fixtures.projectURL), before)
    }

    func testKraken2RefusesTheGroupInABatchAndThroughCondaClassify() throws {
        let before = try snapshot(of: fixtures.projectURL)
        let batch = try runCLI([
            "kraken2", "classify", fixtures.demuxGroup.path, "--db", "FixtureDB", "--batch",
            "--project", fixtures.projectURL.path,
        ])
        XCTAssertEqual(batch.exitCode, CLIExitCode.inputError.rawValue, batch.output)
        XCTAssertTrue(batch.output.contains(Self.kraken2Sentence), batch.output)
        let conda = try runCLI([
            "conda", "classify", fixtures.demuxGroup.path, "--db", "FixtureDB",
            "--project", fixtures.projectURL.path,
        ])
        XCTAssertEqual(conda.exitCode, CLIExitCode.inputError.rawValue, conda.output)
        XCTAssertTrue(conda.output.contains(Self.kraken2Sentence), conda.output)
        XCTAssertEqual(try snapshot(of: fixtures.projectURL), before)
    }

    func testKraken2StillRefusesAGroupAmongOtherInputsWithTheSameSentence() throws {
        let before = try snapshot(of: fixtures.projectURL)
        let result = try runCLI([
            "kraken2", "classify", fixtures.singleRoot.path, fixtures.demuxGroup.path, "--db", "FixtureDB",
            "--project", fixtures.projectURL.path,
        ])
        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue, result.output)
        XCTAssertTrue(result.output.contains(Self.kraken2Sentence), result.output)
        XCTAssertEqual(try snapshot(of: fixtures.projectURL), before, "no folder exists after the refusal")
    }

    // MARK: - Helpers

    /// Runs the built `lungfish-cli` with the storage root of this test.
    private func runCLI(_ arguments: [String]) throws -> GroupRefusalCLI.Outcome {
        try GroupRefusalCLI.run(arguments, storage: storage, testClass: Self.self)
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

    private func snapshot(of folder: URL) throws -> [String: String] {
        try GroupRefusalCLI.snapshot(of: folder)
    }
}

/// The live form of the refusal (the 2.9 O5 ruling), the built `lungfish-cli` on the L6e group with
/// this Mac's own managed storage and its installed Kraken2 Viral database. The refusal comes from
/// the plan, so no tool runs and nothing is written, and the test skips without the database. Its
/// name holds `Conformance`, so it never runs in the unit tier. Set `LUNGFISH_REQUIRE_TOOLS=1` to run it.
final class Kraken2DemuxGroupRefusalLiveConformanceTests: XCTestCase {
    func testTheRealCommandRefusesAGroupWithTheInstalledViralDatabase() async throws {
        guard ToolAvailability.requireTools else {
            throw XCTSkip("Set LUNGFISH_REQUIRE_TOOLS=1 to run kraken2 classify on a group with the installed Viral database")
        }
        guard Self.hasReadyViralDatabase() else {
            try ToolAvailability.skipOrFail("The Kraken2 Viral database is not installed on this Mac")
        }
        let root = try TestTempDirectory.make(prefix: "kraken2-demux-group-live")
        defer { TestTempDirectory.cleanup(root) }
        let fixtures = try ReadSetFixtures(in: root)
        let before = try GroupRefusalCLI.snapshot(of: fixtures.projectURL)
        let result = try GroupRefusalCLI.run(
            ["kraken2", "classify", fixtures.demuxGroup.path, "--db", "Viral", "--project", fixtures.projectURL.path],
            storage: nil,
            testClass: Self.self
        )
        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue, result.output)
        XCTAssertTrue(result.output.contains(GroupRefusalCLI.kraken2Sentence), result.output)
        XCTAssertEqual(try GroupRefusalCLI.snapshot(of: fixtures.projectURL), before, "no folder exists after the refusal")
    }

    /// Whether this Mac's registry lists a ready database named Viral, read from the manifest
    /// alone, so the test process writes nothing to the managed storage.
    private static func hasReadyViralDatabase() -> Bool {
        let manifest = ManagedStorageConfigStore().currentLocation().databaseRootURL
            .appendingPathComponent("metagenomics-db-registry.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let databases = object["databases"] as? [[String: Any]] else { return false }
        return databases.contains { $0["name"] as? String == "Viral" && $0["status"] as? String == "ready" }
    }
}

/// The built `lungfish-cli` on a group bundle, for the stand-in class and the live class.
private enum GroupRefusalCLI {
    static let sentenceStem = "Demultiplexed group bundles are container-only; "
        + "select an individual demultiplexed FASTQ bundle for "
    static let kraken2Sentence = sentenceStem + "classification."
    static let esVirituSentence = sentenceStem + "EsViritu detection."

    struct Outcome {
        let exitCode: Int32
        /// Standard output, then standard error.
        let output: String
    }

    /// Runs the built `lungfish-cli` and waits up to a minute. With `storage` the managed storage
    /// root and the conda root are folders of the test, and without it the run uses this Mac's own.
    static func run(_ arguments: [String], storage: URL?, testClass: AnyClass) throws -> Outcome {
        let binary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(
                buildProductsDirectory: Bundle(for: testClass).bundleURL.deletingLastPathComponent()
            ),
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = CLISIGTERMHarness.childEnvironment(overriding: storage.map { storage in
            [
                "LUNGFISH_STORAGE_ROOT": storage.path,
                "LUNGFISH_CONDA_ROOT": storage.appendingPathComponent("conda", isDirectory: true).path,
            ]
        } ?? [:])
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

    /// Every file and folder below `folder` by its path inside it, a file with the SHA-256 of its
    /// bytes and a folder with a marker, so equal snapshots mean no entry was made, removed or changed.
    static func snapshot(of folder: URL) throws -> [String: String] {
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
