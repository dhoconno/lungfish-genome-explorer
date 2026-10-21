// Kraken2UnreadableInputExitTests.swift - kraken2 classify and esviritu detect on an input with no readable reads, through the built CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// Phase 2.11 lane U64 M1, row SW23 and decision U4. A bundle whose manifest stands and whose reads are gone
/// holds no readable FASTQ or FASTA payload. `esviritu detect` refuses it in its plan with exit 3. The refusal
/// of `kraken2 classify` is the same kind, a request the input makes impossible that ends before any folder
/// exists, so it follows `docs/contracts/ADDING-AN-OPERATION.md` (3 for a refusal, 64 for a failure, 125 for a
/// cancel).
///
/// Every test runs the built `lungfish-cli` on the L5a fixture of ``ReadSetFixtures`` with its `reads.fastq`
/// removed, and with the managed storage root pointed at a folder of the test, where `FixtureDB` is a
/// registered ready database, so no test reads or writes the real storage.
final class Kraken2UnreadableInputExitTests: XCTestCase {
    private static let stem = "Sequence input does not contain a readable FASTQ or FASTA payload: "

    private var root: URL!
    private var fixtures: ReadSetFixtures!
    private var storage: URL!
    private var unreadable: URL!

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "kraken2-unreadable-input")
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
        // The manifest of the full derivative stands, and its payload is gone.
        unreadable = fixtures.fullDerivative
        try FileManager.default.removeItem(at: unreadable.appendingPathComponent("reads.fastq"))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - kraken2 classify

    /// Both spellings are one command, and the refusal keeps its words.
    func testKraken2ClassifyRefusesAnUnreadableInputWithExit3BeforeAnyFolder() throws {
        let before = try listing(of: fixtures.projectURL)
        for path in [["kraken2", "classify"], ["conda", "classify"]] {
            let result = try runCLI(path + [unreadable.path, "--db", "FixtureDB", "--project", fixtures.projectURL.path])
            XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue, "\(path.joined(separator: " ")): \(result.output)")
            XCTAssertTrue(result.output.contains(Self.stem), result.output)
            XCTAssertTrue(result.output.contains(unreadable.lastPathComponent), result.output)
            XCTAssertEqual(try listing(of: fixtures.projectURL), before, "no folder exists after the refusal")
        }
    }

    // MARK: - esviritu detect, the reference

    func testEsVirituDetectRefusesTheSameInputWithExit3() throws {
        let before = try listing(of: fixtures.projectURL)
        let result = try runCLI([
            "esviritu", "detect", "--input", unreadable.path, "--sample", "unreadable", "--project", fixtures.projectURL.path,
        ])
        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue, result.output)
        XCTAssertTrue(result.output.contains(Self.stem), result.output)
        XCTAssertEqual(try listing(of: fixtures.projectURL), before, "no folder exists after the refusal")
    }

    // MARK: - Helpers

    /// Runs the built `lungfish-cli` with the storage root of this test and waits up to a minute.
    private func runCLI(_ arguments: [String]) throws -> (exitCode: Int32, output: String) {
        let binary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(
                buildProductsDirectory: Bundle(for: Kraken2UnreadableInputExitTests.self).bundleURL.deletingLastPathComponent()
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
        return (process.terminationStatus, out + err)
    }

    /// Every path below `folder`, relative to it, so equal listings mean no entry was made or removed.
    private func listing(of folder: URL) throws -> [String] {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        return walker.compactMap { ($0 as? URL).map { String($0.path.dropFirst(folder.path.count)) } }.sorted()
    }
}
